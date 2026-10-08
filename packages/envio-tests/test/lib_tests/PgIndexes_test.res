open Vitest

// These run against a real database and assert on pg_catalog, not on the SQL
// the storage emitted: the whole point of the index rules is what PostgreSQL
// ends up holding.
let sql = PgStorage.makeClient()

// A(b_id) is the indexed foreign key the rules act on; B(c_id) is the unrelated
// column a test parks a same-named index on.
let config = TestConfig.make(
  ~schema=`
type A {
  id: ID!
  b: B! @index
  optionalStringToTestLinkedEntities: String
}
type B {
  id: ID!
  a: [A!]! @derivedFrom(field: "b")
  c: C
}
type C {
  id: ID!
  a: A!
  stringThatIsMirroredToA: String!
}
`,
)
let enums = config.allEnums

let entityA = config->IndexerRunner.entityConfigByName("A")
let entityB = config->IndexerRunner.entityConfigByName("B")
let entities = [entityA, entityB]
let allEntities = entities

let makeStorage = pgSchema => PgStorage.make(~pgSchema, ~ecosystem=Evm)

// A schema of its own per test, so the fixtures below can leave whatever
// indexes they like behind without disturbing the other suites. `fixtures` run
// after the tables exist, then the storage resumes — the same order a restart
// onto an existing schema sees.
// Each test owns a schema; they'd otherwise pile up in the developer's database
// run after run, since nothing else ever looks at them again. The name is
// unique per run so two suites can share a database without colliding.
let testSchema = suffix => `${TestPgSchema.make()}_${suffix}`

let createdSchemas = []

Async.afterAll(async () => {
  let _ = await createdSchemas
  ->Array.map(pgSchema => sql->Sql.query(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`))
  ->Promise.all
  await sql->Sql.close
})

let setup = async (~pgSchema, ~fixtures=[], ~entities=allEntities) => {
  createdSchemas->Array.push(pgSchema)->ignore
  let storage = makeStorage(pgSchema)
  let _ = await storage.initialize(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~entities,
    ~enums,
    ~envioInfo=JSON.Encode.object(Dict.make()),
  )
  for idx in 0 to fixtures->Array.length - 1 {
    let _ = await sql->Sql.query(fixtures->Array.getUnsafe(idx))
  }
  if fixtures->Utils.Array.notEmpty {
    let _ = await storage.resumeInitialState(
      ~entities,
      ~chainIds=config.chainMap->ChainMap.keys,
      ~contractMapping=config.contractMapping,
    )
  }
  storage
}

let findIndexes = (~pgSchema, ~tableName, ~columns) =>
  sql->PgCatalog.leadingWith(~pgSchema, ~tableName, ~columns)

let describeIndex = (index: PgCatalog.index) => (
  index.name,
  index.isValid,
  index.isPartial,
  index.method,
)

let eq = (~fieldName): EntityFilter.t =>
  Dict.fromArray([
    (fieldName, dict{"_eq": "1"->(Utils.magic: string => unknown)}),
  ])->EntityFilter.parseOrThrow(~entityName=entityA.name, ~table=entityA.table)

let aBIdName = "A_b_id_556h9mdu8a"

let readyAt = Date.fromString("2024-01-01T00:00:00Z")

let readyAtByChainId = async pgSchema => {
  let rows: array<{
    "id": ChainId.t,
    "ready_at": Null.t<Date.t>,
  }> = await sql->Sql.query(
    `SELECT "id", "ready_at" FROM "${pgSchema}"."${InternalTable.Chains.tableName}" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"], row["ready_at"]->Null.toOption->Option.isSome))
}

// An entity of text columns only, its schema built from the same names as its
// table: storage writes go by the schema's fields, so the two have to agree.
let textEntity = (~tableName, ~columns): Internal.entityConfig => {
  ...entityA,
  name: tableName,
  schema: S.object(s => {
    let dict = Dict.make()
    ["id"]
    ->Array.concat(columns)
    ->Array.forEach(column => dict->Dict.set(column, s.field(column, S.string->S.toUnknown)))
    dict
  })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.entity>),
  table: Table.mkTable(
    tableName,
    ~fields=[Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string)]->Array.concat(
      columns->Array.map(column =>
        Table.mkField(column, String, ~isIndex=true, ~fieldSchema=S.string)
      ),
    ),
  ),
}

let catchMessage = promise =>
  promise
  ->Promise.thenResolve(_ => None)
  ->Utils.Promise.catchResolve(exn => Some(
    exn->(Utils.magic: exn => {"message": string})->(error => error["message"]),
  ))

describe("Indexes built against a real schema", () => {
  Async.it("Builds a separate full index when only a partial one exists", async t => {
    let pgSchema = testSchema("partial")
    // Covers only the rows its predicate selects, so it can't answer the
    // unrestricted lookups a getWhere filter makes — but it does hold a name.
    let storage = await setup(
      ~pgSchema,
      ~fixtures=[`CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id") WHERE "b_id" IS NOT NULL;`],
    )

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
        entry => (entry.name, entry.isPartial, entry.isValid),
      ),
      ~message="The partial index stays, and a full index is built beside it",
    ).toEqual([("A_b_id", true, true), (aBIdName, false, true)])
  })

  Async.it("Leaves a same-named index on another table untouched", async t => {
    let pgSchema = testSchema("conflict")
    let storage = await setup(
      ~pgSchema,
      ~fixtures=[`CREATE INDEX "A_b_id" ON "${pgSchema}"."B"("c_id");`],
    )

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (
        (await findIndexes(~pgSchema, ~tableName="B", ~columns=["c_id"]))->Array.map(
          entry => entry.name,
        ),
        (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(describeIndex),
      ),
      ~message="The unrelated index keeps its name, and A(b_id) is still indexed",
    ).toEqual((["A_b_id"], [(aBIdName, true, false, "btree")]))
  })

  // A `CREATE UNIQUE INDEX CONCURRENTLY` that fails on duplicate data leaves an
  // INVALID index behind that still owns its name. The planner refuses to use
  // it, so it must never be counted as coverage.
  Async.it("Refuses to count an invalid index left by a failed build", async t => {
    let pgSchema = testSchema("invalid")
    let storage = await setup(~pgSchema)

    let _ = await sql->Sql.query(
      `INSERT INTO "${pgSchema}"."A" ("id", "b_id") VALUES ('1', 'dup'), ('2', 'dup');`,
    )
    let failure = await sql
    ->Sql.query(`CREATE UNIQUE INDEX CONCURRENTLY "A_b_id" ON "${pgSchema}"."A"("b_id");`)
    ->catchMessage
    let _ = await storage.resumeInitialState(
      ~entities,
      ~chainIds=config.chainMap->ChainMap.keys,
      ~contractMapping=config.contractMapping,
    )

    let leftBehind = await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"])

    t.expect(
      (failure->Option.isSome, leftBehind->Array.map(entry => (entry.name, entry.isValid))),
      ~message="The failed build leaves an invalid index holding the name",
    ).toEqual((true, [("A_b_id", false)]))

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
        entry => (entry.name, entry.isValid),
      ),
      ~message="A usable index is built rather than the invalid one being blessed",
    ).toEqual([("A_b_id", false), (aBIdName, true)])
  })

  // Same identity, an older name. Matching the catalog on what an index covers
  // keeps it instead of building a duplicate under the generated name.
  Async.it("Keeps a valid legacy index instead of rebuilding it", async t => {
    let pgSchema = testSchema("legacy")
    let storage = await setup(
      ~pgSchema,
      ~fixtures=[`CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id");`],
    )

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
        entry => entry.name,
      ),
      ~message="No second index appears under the generated name",
    ).toEqual(["A_b_id"])
  })

  Async.it("Builds an automatic index for a getWhere column, once", async t => {
    let pgSchema = testSchema("automatic")
    let storage = await setup(~pgSchema)
    let column = "optionalStringToTestLinkedEntities"

    await storage.ensureQueryIndexes(
      ~entityConfig=entityA,
      ~scope=CrossChain,
      ~filters=[eq(~fieldName=column)],
    )
    await storage.ensureQueryIndexes(
      ~entityConfig=entityA,
      ~scope=CrossChain,
      ~filters=[eq(~fieldName=column)],
    )

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=[column]))->Array.map(describeIndex),
      ~message="The second request is served from the catalog, with no second index",
    ).toEqual([("A_optionalStringToTestLinkedEntities_cedvgf89cu", true, false, "btree")])
  })

  // Entity names are capped at 63 characters by codegen, so nothing the
  // indexer creates should ever be truncated by Postgres — but if that ever
  // stopped holding, the catalog would report a name we never look for and
  // verification would fail every finalize. This pins the boundary.
  Async.it("Round-trips a table name at Postgres' identifier limit", async t => {
    let pgSchema = testSchema("long_name")
    let tableName = "Entity" ++ "x"->String.repeat(57)
    let entity = textEntity(~tableName, ~columns=["b_id"])
    let storage = await setup(~pgSchema, ~entities=[entity])

    await storage.finalizeBackfill(~entities=[entity], ~chainIds=[], ~readyAt)
    // A second pass has to recognise what the first one built. If the stored
    // name and the one we match on had drifted, this would rebuild and fail.
    await storage.finalizeBackfill(~entities=[entity], ~chainIds=[], ~readyAt)

    t.expect((
      tableName->String.length,
      (await findIndexes(~pgSchema, ~tableName, ~columns=["b_id"]))->Array.map(describeIndex),
    )).toEqual((63, [(`Entity${"x"->String.repeat(46)}_cc8kvf5n3y`, true, false, "btree")]))
  })

  // A finalize that dies part way through must not undo the indexes it already
  // built, and must not claim readiness the schema doesn't back yet. A btree
  // refuses a key past a third of a page, so one oversized value fails the
  // second build for real.
  Async.it("Keeps the indexes it built when a later one fails, and retries the rest", async t => {
    let pgSchema = testSchema("partial_failure")
    let tableName = "Triple"
    let entity = textEntity(~tableName, ~columns=["first_id", "second_id", "third_id"])
    let indexNames = [
      "Triple_first_id_25x6ow0iho",
      "Triple_second_id_8gn2rflahq",
      "Triple_third_id_fu01se72wu",
    ]
    let storage = await setup(~pgSchema, ~entities=[entity])
    let chainIds = config.chainMap->ChainMap.values->Array.map(chain => chain.id)
    let _ = await sql->Sql.query(
      `INSERT INTO "${pgSchema}"."Triple" ("id", "first_id", "second_id", "third_id")
       SELECT '1', 'a', string_agg(md5(i::text), ''), 'c' FROM generate_series(1, 1000) i;`,
    )
    let builtIndexNames = async () =>
      (await sql->PgCatalog.indexes(~pgSchema))->Array.filterMap(
        index => indexNames->Array.includes(index.name) ? Some(index.name) : None,
      )

    let failure = await storage.finalizeBackfill(
      ~entities=[entity],
      ~chainIds,
      ~readyAt,
    )->catchMessage
    let afterFailure = (
      failure->Option.isSome,
      await builtIndexNames(),
      await readyAtByChainId(pgSchema),
    )

    let _ = await sql->Sql.query(`UPDATE "${pgSchema}"."Triple" SET "second_id" = 'b';`)
    await storage.finalizeBackfill(~entities=[entity], ~chainIds, ~readyAt)

    t.expect((afterFailure, (await builtIndexNames(), await readyAtByChainId(pgSchema)))).toEqual((
      (true, [indexNames->Array.getUnsafe(0)], chainIds->Array.map(id => (id, false))),
      (indexNames, chainIds->Array.map(id => (id, true))),
    ))
  })

  Async.it("Skips the schema index an automatic build already created", async t => {
    let pgSchema = testSchema("shared")
    let storage = await setup(~pgSchema)

    await storage.ensureQueryIndexes(
      ~entityConfig=entityA,
      ~scope=CrossChain,
      ~filters=[eq(~fieldName="b_id")],
    )
    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
        entry => entry.name,
      ),
    ).toEqual([aBIdName])
  })
})
