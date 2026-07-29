open Vitest

// These run against a real database and assert on pg_catalog, not on the SQL
// the storage emitted: the whole point of the index rules is what PostgreSQL
// ends up holding.
let sql = PgStorage.makeClient()

let config = Config.load()
let enums =
  config.allEnums->Array.concat([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])

let entityA = MockIndexer.entityConfig(A)
let entityB = MockIndexer.entityConfig(B)
let entities = [entityA, entityB]
// The storage creates exactly the tables it is handed, so the internal ones a
// resume reads back have to be in the list too.
let allEntities = entities->Array.concat([InternalTable.EnvioAddresses.entityConfig])

// Delegates to the real client, records every statement, and can be told to
// fail one kind of query — enough to reproduce a read-back that fails after its
// DDL has already committed.
let makeFlakySql: (Postgres.sql, array<string>, string => bool) => Postgres.sql = %raw(`(sql, log, shouldFail) => ({
  unsafe: (query, params, options) => {
    log.push(query);
    return shouldFail(query)
      ? Promise.reject(new Error("connection terminated unexpectedly"))
      : sql.unsafe(query, params, options);
  },
  begin: (fn) => sql.begin(fn),
  end: () => sql.end(),
})`)

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
  )

// A schema of its own per test, so the fixtures below can leave whatever
// indexes they like behind without disturbing the other suites. `fixtures` run
// after the tables exist, then the storage resumes — the same order a restart
// onto an existing schema sees.
let setup = async (~pgSchema, ~fixtures=[], ~sql as client=sql, ~entities=allEntities) => {
  let storage = makeStorage(~sql=client, pgSchema)
  let _ = await storage.initialize(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~entities,
    ~enums,
    ~envioInfo=JSON.Encode.object(Dict.make()),
  )
  for idx in 0 to fixtures->Array.length - 1 {
    let _ = await sql->Postgres.unsafe(fixtures->Array.getUnsafe(idx))
  }
  if fixtures->Utils.Array.notEmpty {
    let _ = await storage.resumeInitialState()
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

let eq = (~fieldName): EntityFilter.t =>
  Eq({fieldName, fieldValue: "1"->(Utils.magic: string => unknown)})

let aBId = IndexDefinition.single(~tableName="A", ~column="b_id")
let aBIdName = aBId->IndexDefinition.name

let readyAt = Date.fromString("2024-01-01T00:00:00Z")

let catchMessage = promise =>
  promise
  ->Promise.thenResolve(_ => None)
  ->Utils.Promise.catchResolve(exn =>
    Some(exn->(Utils.magic: exn => {"message": string})->(error => error["message"]))
  )

describe("Indexes built against a real schema", () => {
  Async.it("Builds a separate full index when only a partial one exists", async t => {
    let pgSchema = "test_pg_indexes_partial"
    // Covers only the rows its predicate selects, so it can't answer the
    // unrestricted lookups a getWhere filter makes — but it does hold a name.
    let storage = await setup(
      ~pgSchema,
      ~fixtures=[`CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id") WHERE "b_id" IS NOT NULL;`],
    )

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(entry => (
        entry.name,
        entry.isPartial,
        entry.isValid,
      )),
      ~message="The partial index stays, and a full index is built beside it",
    ).toEqual([("A_b_id", true, true), (aBIdName, false, true)])
  })

  Async.it("Leaves a same-named index on another table untouched", async t => {
    let pgSchema = "test_pg_indexes_conflict"
    let storage = await setup(
      ~pgSchema,
      ~fixtures=[`CREATE INDEX "A_b_id" ON "${pgSchema}"."B"("c_id");`],
    )

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (
        (await findIndexes(~pgSchema, ~tableName="B", ~columns=["c_id"]))->Array.map(entry =>
          entry.name
        ),
        (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(
          describeIndex,
        ),
      ),
      ~message="The unrelated index keeps its name, and A(b_id) is still indexed",
    ).toEqual((["A_b_id"], [(aBIdName, true, false, "btree")]))
  })

  // A `CREATE UNIQUE INDEX CONCURRENTLY` that fails on duplicate data leaves an
  // INVALID index behind that still owns its name. The planner refuses to use
  // it, so it must never be counted as coverage.
  Async.it("Refuses to count an invalid index left by a failed build", async t => {
    let pgSchema = "test_pg_indexes_invalid"
    let storage = await setup(~pgSchema)

    let _ = await sql->Postgres.unsafe(
      `INSERT INTO "${pgSchema}"."A" ("id", "b_id") VALUES ('1', 'dup'), ('2', 'dup');`,
    )
    let failure = await sql
    ->Postgres.unsafe(`CREATE UNIQUE INDEX CONCURRENTLY "A_b_id" ON "${pgSchema}"."A"("b_id");`)
    ->catchMessage
    let _ = await storage.resumeInitialState()

    let leftBehind = await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"])

    t.expect(
      (failure->Option.isSome, leftBehind->Array.map(entry => (entry.name, entry.isValid))),
      ~message="The failed build leaves an invalid index holding the name",
    ).toEqual((true, [("A_b_id", false)]))

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(entry => (
        entry.name,
        entry.isValid,
      )),
      ~message="A usable index is built rather than the invalid one being blessed",
    ).toEqual([("A_b_id", false), (aBIdName, true)])
  })

  // Same identity, an older name. Matching the catalog on what an index covers
  // keeps it instead of building a duplicate under the generated name.
  Async.it("Keeps a valid legacy index instead of rebuilding it", async t => {
    let pgSchema = "test_pg_indexes_legacy"
    let storage = await setup(
      ~pgSchema,
      ~fixtures=[`CREATE INDEX "A_b_id" ON "${pgSchema}"."A"("b_id");`],
    )

    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(entry =>
        entry.name
      ),
      ~message="No second index appears under the generated name",
    ).toEqual(["A_b_id"])
  })

  Async.it("Builds an automatic index for a getWhere column, once", async t => {
    let pgSchema = "test_pg_indexes_automatic"
    let storage = await setup(~pgSchema)
    let column = "optionalStringToTestLinkedEntities"

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName=column)])
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName=column)])

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=[column]))->Array.map(describeIndex),
      ~message="The second request is served from the catalog, with no second index",
    ).toEqual([
      (
        IndexDefinition.single(~tableName="A", ~column)->IndexDefinition.name,
        true,
        false,
        "btree",
      ),
    ])
  })

  // Entity names are capped at 63 characters by codegen, so nothing the
  // indexer creates should ever be truncated by Postgres — but if that ever
  // stopped holding, the catalog would report a name we never look for and
  // verification would fail every finalize. This pins the boundary.
  Async.it("Round-trips a table name at Postgres' identifier limit", async t => {
    let pgSchema = "test_pg_indexes_long_name"
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
    let storage = await setup(
      ~pgSchema,
      ~entities=[entity, InternalTable.EnvioAddresses.entityConfig],
    )
    let definition = IndexDefinition.single(~tableName, ~column="b_id")

    await storage.finalizeBackfill(~entities=[entity], ~chainIds=[], ~readyAt)
    // A second pass has to recognise what the first one built. If the stored
    // name and the one we match on had drifted, this would rebuild and fail.
    await storage.finalizeBackfill(~entities=[entity], ~chainIds=[], ~readyAt)

    t.expect(
      (
        tableName->String.length,
        (await findIndexes(~pgSchema, ~tableName, ~columns=["b_id"]))->Array.map(describeIndex),
      ),
    ).toEqual((63, [(definition->IndexDefinition.name, true, false, "btree")]))
  })

  // The DDL commits, then the read-back fails on its own round trip. Without
  // resyncing that index, the catalog keeps claiming the name is free and every
  // later request replans a create that can only raise "already exists".
  Async.it("Recovers when the read-back fails after the index was built", async t => {
    let pgSchema = "test_pg_indexes_flaky"
    let queries = []
    // One-shot: the storage reads the catalog during initialize too, so the
    // failure is armed only once the schema is up.
    let failNextRead = ref(false)
    let flakySql = makeFlakySql(sql, queries, query =>
      if failNextRead.contents && query->String.includes("FROM pg_index") {
        failNextRead := false
        true
      } else {
        false
      }
    )
    let storage = await setup(~pgSchema, ~sql=flakySql)
    let filters = [eq(~fieldName="b_id")]

    failNextRead := true
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters)

    let built = await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"])
    t.expect(
      built->Array.map(entry => entry.name),
      ~message="The index committed even though the verification read never came back",
    ).toEqual([aBIdName])

    // The resync happens on the failure path, so by now the storage should
    // already know the index exists.
    queries->Utils.Array.clearInPlace
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters)
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters)

    t.expect(
      (
        queries->Array.filter(query => query->String.includes("CREATE INDEX")),
        (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(entry =>
          entry.name
        ),
      ),
      ~message="Later requests are served from the catalog instead of retrying a doomed create",
    ).toEqual(([], [aBIdName]))
  })

  Async.it("Skips the schema index an automatic build already created", async t => {
    let pgSchema = "test_pg_indexes_shared"
    let storage = await setup(~pgSchema)

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    await storage.finalizeBackfill(~entities, ~chainIds=[], ~readyAt)

    t.expect(
      (await findIndexes(~pgSchema, ~tableName="A", ~columns=["b_id"]))->Array.map(entry =>
        entry.name
      ),
    ).toEqual([aBIdName])
  })
})
