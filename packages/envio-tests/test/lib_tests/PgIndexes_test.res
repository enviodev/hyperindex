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
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])

let entityA = config->IndexerRunner.entityConfigByName("A")
let entityB = config->IndexerRunner.entityConfigByName("B")
let entities = [entityA, entityB]
let allEntities = entities

// Delegates to the real client, records every statement, and can be told to
// fail one kind of query — enough to reproduce a read-back that fails after its
// DDL has already committed. A Proxy rather than a hand-written stand-in, so
// the storage reaching for a method this test never thought about still works.
// Wraps the transaction handle as well as the pool: index DDL runs inside a
// transaction, so a proxy that only covered the pool would never see it.
let makeFlakySql: (
  Postgres.sql,
  array<string>,
  string => bool,
) => Postgres.sql = %raw(`(sql, log, shouldFail) => {
  const wrap = (target) => new Proxy(target, {
    get(t, prop, receiver) {
      if (prop === "unsafe") {
        return (query, params, options) => {
          log.push(query);
          return shouldFail(query)
            ? Promise.reject(new Error("connection terminated unexpectedly"))
            : t.unsafe(query, params, options);
        };
      }
      if (prop === "begin") {
        return (fn) => t.begin((tx) => fn(wrap(tx)));
      }
      const value = Reflect.get(t, prop, receiver);
      return typeof value === "function" ? value.bind(t) : value;
    },
  });
  return wrap(sql);
}`)

let makeStorage = (~sql=sql, pgSchema) =>
  PgStorage.make(
    ~sql,
    ~pgHost=Env.Db.host,
    ~pgSchema,
    ~pgPort=Env.Db.port,
    ~pgUser=Env.Db.user,
    ~pgDatabase=Env.Db.database,
    ~pgPassword=Env.Db.password,
    ~isHasuraEnabled=false,
    ~ecosystem=Evm,
  )

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
  ->Array.map(pgSchema => sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`))
  ->Promise.all
})

let setup = async (~pgSchema, ~fixtures=[], ~sql as client=sql, ~entities=allEntities) => {
  createdSchemas->Array.push(pgSchema)->ignore
  let storage = makeStorage(~sql=client, pgSchema)
  let _ = await storage.initialize(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~contractMapping=config.contractMapping,
    ~entities,
    ~enums,
    ~envioInfo=JSON.Encode.object(Dict.make()),
  )
  for idx in 0 to fixtures->Array.length - 1 {
    let _ = await sql->Postgres.unsafe(fixtures->Array.getUnsafe(idx))
  }
  if fixtures->Utils.Array.notEmpty {
    let _ = await storage.resumeInitialState(~entities, ~throwIfIncompatible=(
      ~storedEnvioInfo as _,
      ~storedContractMapping as _,
    ) => ())
  }
  storage
}

let loadCatalog = async pgSchema => {
  let rows =
    (await sql->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema)))->S.parseOrThrow(
      IndexCatalog.rowsSchema,
    )
  IndexCatalog.fromRows(~rows)
}

let findIndexes = async (~pgSchema, ~tableName, ~columns) => {
  let catalog = await loadCatalog(pgSchema)
  catalog
  ->IndexCatalog.entries
  ->Array.filter((entry: IndexCatalog.entry) =>
    entry.tableName === tableName &&
      columns->Array.everyWithIndex((column, idx) =>
        switch entry.columns->Array.get(idx) {
        | Some(actual) => actual.name === column
        | None => false
        }
      )
  )
  ->Array.toSorted((a, b) => String.compare(a.name, b.name))
}

let describeIndex = (entry: IndexCatalog.entry) => (
  entry.name,
  entry.isValid,
  entry.isPartial,
  entry.method,
)

let eq = (~fieldName): EntityFilter.t => Eq({
  fieldName,
  fieldValue: "1"->(Utils.magic: string => unknown),
})

let aBId = IndexDefinition.single(~tableName="A", ~column="b_id")
let aBIdName = aBId->IndexDefinition.name

let readyAt = Date.fromString("2024-01-01T00:00:00Z")

let readyAtByChainId = async pgSchema => {
  let rows: array<{
    "id": ChainId.t,
    "ready_at": Null.t<Date.t>,
  }> = await sql->Postgres.unsafe(
    `SELECT "id", "ready_at" FROM "${pgSchema}"."${InternalTable.Chains.table.tableName}" ORDER BY "id";`,
  )
  rows->Array.map(row => (row["id"], row["ready_at"]->Null.toOption->Option.isSome))
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

    await storage.finalizeBackfill(~entities, ~readyAt)

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

    await storage.finalizeBackfill(~entities, ~readyAt)

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

    let _ = await sql->Postgres.unsafe(
      `INSERT INTO "${pgSchema}"."A" ("id", "b_id") VALUES ('1', 'dup'), ('2', 'dup');`,
    )
    let failure = await sql
    ->Postgres.unsafe(`CREATE UNIQUE INDEX CONCURRENTLY "A_b_id" ON "${pgSchema}"."A"("b_id");`)
    ->catchMessage
    let _ = await storage.resumeInitialState(
      ~entities,
      ~throwIfIncompatible=(~storedEnvioInfo as _, ~storedContractMapping as _) => (),
    )

    let leftBehind = await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"])

    t.expect(
      (failure->Option.isSome, leftBehind->Array.map(entry => (entry.name, entry.isValid))),
      ~message="The failed build leaves an invalid index holding the name",
    ).toEqual((true, [("A_b_id", false)]))

    await storage.finalizeBackfill(~entities, ~readyAt)

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

    await storage.finalizeBackfill(~entities, ~readyAt)

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

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName=column)])
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName=column)])

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=[column]))->Array.map(describeIndex),
      ~message="The second request is served from the catalog, with no second index",
    ).toEqual([
      (IndexDefinition.single(~tableName="A", ~column)->IndexDefinition.name, true, false, "btree"),
    ])
  })

  // Entity names are capped at 63 characters by codegen, so nothing the
  // indexer creates should ever be truncated by Postgres — but if that ever
  // stopped holding, the catalog would report a name we never look for and
  // verification would fail every finalize. This pins the boundary.
  Async.it("Round-trips a table name at Postgres' identifier limit", async t => {
    let pgSchema = testSchema("long_name")
    let tableName = "Entity" ++ "x"->String.repeat(57)
    let entity: Internal.entityConfig = {
      ...entityA,
      name: tableName,
      table: Table.mkTable(
        tableName,
        ~fields=[
          Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
          Table.mkField("b_id", String, ~isIndex=true, ~fieldSchema=S.string),
        ],
      ),
    }
    let storage = await setup(~pgSchema, ~entities=[entity])
    let definition = IndexDefinition.single(~tableName, ~column="b_id")

    await storage.finalizeBackfill(~entities=[entity], ~readyAt)
    // A second pass has to recognise what the first one built. If the stored
    // name and the one we match on had drifted, this would rebuild and fail.
    await storage.finalizeBackfill(~entities=[entity], ~readyAt)

    t.expect((
      tableName->String.length,
      (await findIndexes(~pgSchema, ~tableName, ~columns=["b_id"]))->Array.map(describeIndex),
    )).toEqual((63, [(definition->IndexDefinition.name, true, false, "btree")]))
  })

  // The read-back shares a transaction with the DDL, so a failure takes the
  // create with it. The catalog and the database can't end up disagreeing about
  // whether the index exists, which is what a later request would trip over.
  Async.it("Rolls the index back when the read-back fails", async t => {
    let pgSchema = testSchema("flaky")
    let queries = []
    // One-shot: the storage reads the catalog during initialize too, so the
    // failure is armed only once the schema is up.
    let failNextRead = ref(false)
    let flakySql = makeFlakySql(
      sql,
      queries,
      query =>
        // Only the read that verifies a build: the same query also runs before
        // one, to see whether another process got there first.
        if (
          failNextRead.contents &&
          query->String.includes("FROM pg_index") &&
          queries->Array.some(logged => logged->String.includes("CREATE INDEX"))
        ) {
          failNextRead := false
          true
        } else {
          false
        },
    )
    let storage = await setup(~pgSchema, ~sql=flakySql)
    let filters = [eq(~fieldName="b_id")]

    failNextRead := true
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
        entry => entry.name,
      ),
      ~message="The failed verification took the create with it",
    ).toEqual([])

    queries->Utils.Array.clearInPlace
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters)
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters)

    t.expect(
      (
        queries->Array.filter(query => query->String.includes("CREATE INDEX"))->Array.length,
        (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
          entry => entry.name,
        ),
      ),
      ~message="The retry builds it once, and the request after that is served from the catalog",
    ).toEqual((1, [aBIdName]))
  })

  // A finalize that dies part way through must not undo the indexes it already
  // built: each one commits on its own, so the retry owes only the rest.
  Async.it("Keeps the indexes it built when a later one fails, and retries the rest", async t => {
    let pgSchema = testSchema("partial_failure")
    let tableName = "Triple"
    let entity: Internal.entityConfig = {
      ...entityA,
      name: tableName,
      table: Table.mkTable(
        tableName,
        ~fields=[
          Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
          Table.mkField("first_id", String, ~isIndex=true, ~fieldSchema=S.string),
          Table.mkField("second_id", String, ~isIndex=true, ~fieldSchema=S.string),
          Table.mkField("third_id", String, ~isIndex=true, ~fieldSchema=S.string),
        ],
      ),
    }
    let indexNames =
      ["first_id", "second_id", "third_id"]->Array.map(
        column => IndexDefinition.single(~tableName, ~column)->IndexDefinition.name,
      )
    let secondName = indexNames->Array.getUnsafe(1)

    let queries = []
    let failSecondBuild = ref(true)
    let flakySql = makeFlakySql(
      sql,
      queries,
      query =>
        failSecondBuild.contents &&
        query->String.includes("CREATE INDEX") &&
        query->String.includes(secondName),
    )
    let storage = await setup(~pgSchema, ~sql=flakySql, ~entities=[entity])
    let createdIndexNames = async () =>
      (await loadCatalog(pgSchema))
      ->IndexCatalog.entries
      ->Array.filterMap(
        (entry: IndexCatalog.entry) =>
          indexNames->Array.includes(entry.name) ? Some(entry.name) : None,
      )
      ->Array.toSorted(String.compare)
    let attemptedBuilds = () =>
      indexNames->Array.filter(
        name =>
          queries->Array.some(
            query => query->String.includes("CREATE INDEX") && query->String.includes(name),
          ),
      )

    let failure = await storage.finalizeBackfill(~entities=[entity], ~readyAt)->catchMessage

    t.expect(
      (failure->Option.isSome, await createdIndexNames(), attemptedBuilds()),
      ~message="The first index survives the failure and the third is never attempted",
    ).toEqual((
      true,
      [indexNames->Array.getUnsafe(0)],
      indexNames->Array.slice(~start=0, ~end=2),
    ))

    failSecondBuild := false
    queries->Utils.Array.clearInPlace
    await storage.finalizeBackfill(~entities=[entity], ~readyAt)

    t.expect(
      (await createdIndexNames(), attemptedBuilds()),
      ~message="The retry owes only what's left",
    ).toEqual((indexNames->Array.toSorted(String.compare), indexNames->Array.slice(~start=1, ~end=3)))
  })

  // What `envio start --chain` reads to decide whether it is the last process
  // still backfilling, and so the one that owes the schema its indexes. Judged
  // from committed progress rather than a stamp, so nothing has to be kept in
  // step with it - including a chain-metadata write, which can't reach these
  // columns at all.
  Async.it("Reports each chain's committed position against its head", async t => {
    let pgSchema = testSchema("chain_progress")
    let storage = await setup(~pgSchema)
    let chainIds = config.chainMap->ChainMap.values->Array.map(chain => chain.id)
    let first = chainIds->Array.getUnsafe(0)

    let fresh = await storage.readChainProgress()

    // Stands in for the batch write that carries a chain to its head: progress
    // and source are written as one group, so they move together.
    let _ = await sql->Postgres.unsafe(
      `UPDATE "${pgSchema}"."${InternalTable.Chains.table.tableName}"
       SET "progress_block" = 500, "source_block" = 500 WHERE "id" = ${first->ChainId.toString};`,
    )
    let meta = Dict.make()
    meta->Dict.set(
      first->ChainId.toString,
      (
        {
          firstEventBlockNumber: Null.null,
          latestFetchedBlockNumber: 10,
          isHyperSync: false,
        }: InternalTable.Chains.metaFields
      ),
    )
    let _ = await storage.setChainMeta(meta)

    let caughtUp = (await storage.readChainProgress())->Array.filter(progress =>
      progress.id === first
    )

    t.expect(
      (
        fresh->Array.length,
        fresh->Array.every((progress: Persistence.chainProgress) =>
          progress.progressBlockNumber === -1 && progress.sourceBlockNumber === 0
        ),
        caughtUp->Array.map((progress: Persistence.chainProgress) => (
          progress.progressBlockNumber,
          progress.sourceBlockNumber,
        )),
      ),
      ~message="A fresh chain has no head to be measured against; a caught-up one reads level, and a metadata write doesn't disturb it",
    ).toEqual((chainIds->Array.length, true, [(500, 500)]))
  })

  Async.it("Skips the schema index an automatic build already created", async t => {
    let pgSchema = testSchema("shared")
    let storage = await setup(~pgSchema)

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    await storage.finalizeBackfill(~entities, ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
        entry => entry.name,
      ),
    ).toEqual([aBIdName])
  })
})
