open Vitest

// A `postgres.js` stand-in: every statement is recorded, and `begin` brackets
// the ones it wraps so a test can tell what landed in one transaction.
let makeFakeSql: (string => promise<unknown>) => Postgres.sql = %raw(`(run) => {
  const sql = {};
  sql.unsafe = (query) => run(query);
  sql.begin = async (fn) => {
    await run("BEGIN");
    try {
      const result = await fn(sql);
      await run("COMMIT");
      return result;
    } catch (exn) {
      await run("ROLLBACK");
      throw exn;
    }
  };
  sql.end = async () => {};
  return sql;
}`)

let pgSchema = "test_schema"

// Catalog rows the storage reads on resume, so a test can start from a schema
// that already holds indexes — including ones Postgres reports as invalid.
let makeStorage = (~failOn=_ => false, ~catalogRows: array<IndexRegistry.catalogRow>=[]) => {
  let queries = []
  let sql = makeFakeSql(query => {
    queries->Array.push(query)->ignore
    if failOn(query) {
      Promise.reject(Utils.Error.make("permission denied for schema"))
    } else if query->String.includes("FROM pg_index") {
      Promise.resolve(catalogRows->(Utils.magic: array<IndexRegistry.catalogRow> => unknown))
    } else if query->String.includes("AS id FROM") {
      // The committed-checkpoint read, which resumeInitialState indexes into.
      Promise.resolve(%raw(`[{id: "0"}]`))
    } else {
      Promise.resolve(%raw(`[]`))
    }
  })
  let storage = PgStorage.make(
    ~sql,
    ~pgHost="localhost",
    ~pgSchema,
    ~pgPort=5432,
    ~pgUser="postgres",
    ~pgDatabase="envio-dev",
    ~pgPassword="testing",
    ~isHasuraEnabled=false,
  )
  (storage, queries)
}

let eq = (~fieldName): EntityFilter.t =>
  Eq({fieldName, fieldValue: "1"->(Utils.magic: string => unknown)})

let entityA = MockIndexer.entityConfig(A)
let entityB = MockIndexer.entityConfig(B)

let createABId = `CREATE INDEX IF NOT EXISTS "A_b_id" ON "test_schema"."A"("b_id");`
let createAOptional = `CREATE INDEX IF NOT EXISTS "A_optionalStringToTestLinkedEntities" ON "test_schema"."A"("optionalStringToTestLinkedEntities");`

describe("Automatic getWhere indexes", () => {
  Async.it("Creates a descriptively named index for a non-indexed field, once", async t => {
    let (storage, queries) = makeStorage()

    await storage.ensureQueryIndexes(
      ~table=entityA.table,
      ~filters=[eq(~fieldName="optionalStringToTestLinkedEntities")],
    )
    await storage.ensureQueryIndexes(
      ~table=entityA.table,
      ~filters=[eq(~fieldName="optionalStringToTestLinkedEntities")],
    )

    t.expect(
      queries,
      ~message="The second request is served from the registry — no rebuild, and no catalog refresh after the DDL",
    ).toEqual([createAOptional])
  })

  Async.it("Indexes every column a filter reads, deduped", async t => {
    let (storage, queries) = makeStorage()

    await storage.ensureQueryIndexes(
      ~table=entityA.table,
      ~filters=[
        And({
          filters: [eq(~fieldName="b_id"), eq(~fieldName="optionalStringToTestLinkedEntities")],
        }),
        eq(~fieldName="b_id"),
      ],
    )

    t.expect(queries).toEqual([createABId, createAOptional])
  })

  Async.it("Shares one build between concurrent identical requests", async t => {
    let (storage, queries) = makeStorage()

    let first = storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    let second = storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    await first
    await second

    t.expect(queries).toEqual([createABId])
  })

  Async.it("Names a long column the same way a schema-defined index would", async t => {
    let (storage, queries) = makeStorage()
    let longEntity = "Entity" ++ "x"->String.repeat(50)
    let column = "some_long_column_name"
    let table = Table.mkTable(
      longEntity,
      ~fields=[
        Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
        Table.mkField(column, String, ~fieldSchema=S.string),
      ],
    )
    let name = `${longEntity}_${column}`->String.slice(~start=0, ~end=63)

    await storage.ensureQueryIndexes(~table, ~filters=[eq(~fieldName=column)])
    await storage.ensureQueryIndexes(~table, ~filters=[eq(~fieldName=column)])

    t.expect(
      queries,
      ~message="Truncated to the identifier limit and built once, not skipped",
    ).toEqual([
      `CREATE INDEX IF NOT EXISTS "${name}" ON "test_schema"."${longEntity}"("${column}");`,
    ])
  })

  Async.it("Leaves the registry untouched when the DDL fails, and retries next time", async t => {
    let shouldFail = ref(true)
    let (storage, queries) = makeStorage(
      ~failOn=query => shouldFail.contents && query->String.includes("CREATE INDEX"),
    )

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    shouldFail := false
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])

    t.expect(
      queries,
      ~message="A failed build is retried; only the successful one is registered",
    ).toEqual([createABId, createABId])
  })
})

describe("Pre-existing invalid indexes", () => {
  // An index left INVALID by an older build. `CREATE INDEX IF NOT EXISTS`
  // matches on name, so it would quietly skip and we'd register a key for an
  // index the planner refuses to use.
  let invalidABId: IndexRegistry.catalogRow = {
    tableName: "A",
    indexName: "A_b_id",
    method: "btree",
    isValid: 0,
    columns: ["b_id"],
    directions: ["ASC"],
  }
  let dropABId = `DROP INDEX IF EXISTS "test_schema"."A_b_id";`

  Async.it("Are dropped and rebuilt by a getWhere build", async t => {
    let (storage, queries) = makeStorage(~catalogRows=[invalidABId])
    // Loads the registry from the catalog, exactly as a restart does.
    let _ = await storage.resumeInitialState()

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])

    t.expect(
      queries->Array.filter(query => query->String.includes("INDEX")),
      ~message="The dead index is cleared once, then the real one is built",
    ).toEqual([dropABId, createABId])
  })

  Async.it("Are dropped inside the finalize transaction, before ready_at", async t => {
    let (storage, queries) = makeStorage(~catalogRows=[invalidABId])
    let _ = await storage.resumeInitialState()
    let queriesBefore = queries->Array.length

    await storage.finalizeBackfill(
      ~entities=[entityA, entityB],
      ~chainIds=[1],
      ~readyAt=Date.fromString("2024-01-01T00:00:00Z"),
    )

    t.expect(
      queries->Array.slice(~start=queriesBefore, ~end=queries->Array.length),
      ~message="ready_at is only committed alongside an index that actually works",
    ).toEqual([
      "BEGIN",
      dropABId,
      createABId,
      `UPDATE "test_schema"."envio_chains"
SET "ready_at" = $1
WHERE "id" = ANY($2::int[]);`,
      "COMMIT",
    ])
  })
})

describe("finalizeBackfill", () => {
  let readyAt = Date.fromString("2024-01-01T00:00:00Z")
  let setReadyAt = `UPDATE "test_schema"."envio_chains"
SET "ready_at" = $1
WHERE "id" = ANY($2::int[]);`

  Async.it("Commits every missing schema index together with ready_at", async t => {
    let (storage, queries) = makeStorage()

    await storage.finalizeBackfill(~entities=[entityA, entityB], ~chainIds=[1, 137], ~readyAt)

    t.expect(queries).toEqual([
      "BEGIN",
      createABId,
      setReadyAt,
      "COMMIT",
    ])
  })

  Async.it("Rolls back and leaves the registry untouched when an index fails", async t => {
    let shouldFail = ref(true)
    let (storage, queries) = makeStorage(
      ~failOn=query => shouldFail.contents && query->String.includes("CREATE INDEX"),
    )

    let failed = await storage.finalizeBackfill(
      ~entities=[entityA, entityB],
      ~chainIds=[1],
      ~readyAt,
    )
    ->Promise.thenResolve(() => false)
    ->Utils.Promise.catchResolve(_ => true)

    t.expect(
      (failed, queries),
      ~message="ready_at must not be reached, and the transaction rolls back",
    ).toEqual((
      true,
      ["BEGIN", createABId, "ROLLBACK"],
    ))

    shouldFail := false
    await storage.finalizeBackfill(~entities=[entityA, entityB], ~chainIds=[1], ~readyAt)

    t.expect(
      queries->Array.slice(~start=3, ~end=queries->Array.length),
      ~message="The rolled-back index is still missing, so the retry creates it again",
    ).toEqual([
      "BEGIN",
      createABId,
      setReadyAt,
      "COMMIT",
    ])
  })

  Async.it("Skips indexes an automatic getWhere build already created", async t => {
    let (storage, queries) = makeStorage()

    await storage.ensureQueryIndexes(~table=entityA.table, ~filters=[eq(~fieldName="b_id")])
    await storage.finalizeBackfill(~entities=[entityA, entityB], ~chainIds=[1], ~readyAt)

    t.expect(queries).toEqual([createABId, "BEGIN", setReadyAt, "COMMIT"])
  })
})
