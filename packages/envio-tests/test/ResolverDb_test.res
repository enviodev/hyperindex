open Vitest

// The `db` handle the resolver process hands to user resolver code.
//
// Postgres-only by nature: statement_timeout, connection bounding and row
// decoding have no memory-backed equivalent, so this file talks straight to the
// database the suite's global setup already requires, rather than going through
// `Scenario`, which would skip it on the default memory backend.

let configYaml = `
name: resolver-db
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`

let schema = `
type Position {
  id: ID!
  account: String! @index
  sizeInUsd: BigInt!
  isLong: Boolean!
}
`

let config = InternalTestIndexer.fromUserApi(~configYaml, ~schema).config

// Per-chain entities are a config-level choice, so proving `db.get` refuses one
// needs a second config. Parsed only — nothing of it reaches Postgres.
let perChainConfig = InternalTestIndexer.fromUserApi(
  ~configYaml=configYaml ++ "disable_default_cross_chain: true\n",
  ~schema,
).config

let pgSchema = TestPgSchema.make()
let sql = PgStorage.makeClient()

type jsError = {message: string, code?: string, cause?: ResolverDb.causedError}

let asError = (exn: exn): option<jsError> =>
  switch exn {
  | JsExn(e) => Some(e->(Utils.magic: JsExn.t => jsError))
  | _ => None
  }

let makePool = (~poolSize=?, ~poolWaitTimeoutMs=?, ~onWarn=?, ()) =>
  ResolverDb.createPool({
    connection: {
      host: Env.Db.host,
      port: Env.Db.port,
      username: Env.Db.user,
      password: Env.Db.password,
      database: Env.Db.database,
      ssl: Env.Db.ssl,
    },
    entities: config.userEntitiesByName,
    pgSchema,
    ?poolSize,
    ?poolWaitTimeoutMs,
    ?onWarn,
  })

type position = {
  id: string,
  account: string,
  sizeInUsd: bigint,
  isLong: bool,
}

Async.beforeAll(async () => {
  let storage = PgStorage.makeStorageFromEnv(~config, ~sql, ~pgSchema, ~isHasuraEnabled=false)
  let persistence = PgStorage.makePersistenceFromConfig(~config, ~storage)
  await persistence->Persistence.init(
    ~chainConfigs=config.chainMap->ChainMap.values,
    ~envioInfo=JSON.Encode.object(Dict.make()),
    ~resetCommand="envio dev -r",
    ~runCommand=Some("envio dev"),
    ~reset=true,
  )
  let _ = await sql->Postgres.unsafe(
    `INSERT INTO "${pgSchema}"."Position" ("id", "account", "sizeInUsd", "isLong") VALUES
      ('p1', '0xaaa', 100, true),
      ('p2', '0xaaa', 250, false),
      ('p3', '0xbbb', 300, true);`,
  )
})

Async.afterAll(async () => {
  await sql->TestPgSchema.drop(~pgSchema)
  await sql->Postgres.endSql
})

describe("Resolver db handle", () => {
  Async.it("loads entities through the typed loader, decoded as the handlers see them", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "positions", timeoutMs: 5000})
    let positions: array<position> = await db->ResolverDb.find(
      "Position",
      {
        where: dict{
          "account": {"_eq": "0xaaa"}->(Utils.magic: {"_eq": string} => unknown),
          "sizeInUsd": {"_gte": 100n}->(Utils.magic: {"_gte": bigint} => unknown),
        },
        orderBy: [{field: "sizeInUsd", direction: "desc"}],
      },
    )
    await pool->ResolverDb.endPool
    t.expect(positions).toEqual([
      {id: "p2", account: "0xaaa", sizeInUsd: 250n, isLong: false},
      {id: "p1", account: "0xaaa", sizeInUsd: 100n, isLong: true},
    ])
  })

  Async.it("reads one entity by id, and null for an id that isn't there", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "position", timeoutMs: 5000})
    let found: Nullable.t<position> = await db->ResolverDb.get("Position", "p3")
    let missing: Nullable.t<position> = await db->ResolverDb.get("Position", "nope")
    await pool->ResolverDb.endPool
    t.expect((found, missing)).toEqual((
      Nullable.make({id: "p3", account: "0xbbb", sizeInUsd: 300n, isLong: true}),
      Nullable.null,
    ))
  })

  Async.it("runs raw SQL through the escape hatch", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "totals", timeoutMs: 5000})
    let rows: array<{
      "account": string,
      "total": string,
    }> = await db
    ->ResolverDb.sqlOf
    ->ResolverDb.unsafe(
      `SELECT "account", SUM("sizeInUsd")::text AS "total" FROM "${pgSchema}"."Position"
         WHERE "isLong" = $1 GROUP BY "account" ORDER BY "account";`,
      [JSON.Encode.bool(true)],
    )
    await pool->ResolverDb.endPool
    t.expect(rows).toEqual([
      {"account": "0xaaa", "total": "100"},
      {"account": "0xbbb", "total": "300"},
    ])
  })

  Async.it("bounds every query with the resolver's own statement_timeout", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "runaway", timeoutMs: 200})
    let startedAt = Date.now()
    let caught = try {
      let _: array<unknown> = await db
      ->ResolverDb.sqlOf
      ->ResolverDb.unsafe("SELECT pg_sleep(10);", [])
      None
    } catch {
    | exn => asError(exn)
    }
    let elapsed = Date.now() -. startedAt
    await pool->ResolverDb.endPool
    // 57014 is Postgres' query_canceled: the backend was cancelled, not merely
    // a client that gave up — the distinction the 2026-08-18 incident turned on.
    t.expect((
      caught->Option.flatMap(e => e.code),
      caught->Option.flatMap(e => e.cause)->Option.flatMap(cause => cause.code),
      elapsed < 5000.,
    )).toEqual((Some("STATEMENT_TIMEOUT"), Some("57014"), true))
  })

  Async.it("refuses to hand out a handle with no timeout", async t => {
    let pool = makePool()
    let caught = try {
      let _ = pool->ResolverDb.forResolverUnchecked({"name": "unbounded"})
      None
    } catch {
    | exn => asError(exn)
    }
    await pool->ResolverDb.endPool
    t.expect(caught->Option.map(e => e.message)).toEqual(
      Some(
        "Resolver 'unbounded' requires a positive `timeoutMs`. The resolver process connects around PgBouncer, so statement_timeout is the only bound on a runaway query.",
      ),
    )
  })

  Async.it("bounds concurrency and fails fast once the pool is saturated", async t => {
    let pool = makePool(~poolSize=1, ~poolWaitTimeoutMs=50, ())
    let db = pool->ResolverDb.forResolver({name: "fanout", timeoutMs: 5000})
    let sleep = (): promise<array<unknown>> =>
      db->ResolverDb.sqlOf->ResolverDb.unsafe("SELECT pg_sleep(0.5);", [])
    let held = sleep()
    let queued = try {
      let _ = await sleep()
      None
    } catch {
    | exn => asError(exn)
    }
    let _ = await held
    let stats = pool->ResolverDb.stats
    await pool->ResolverDb.endPool
    t.expect((queued->Option.flatMap(e => e.code), stats.peakInUse)).toEqual((
      Some("POOL_WAIT_TIMEOUT"),
      1,
    ))
  })

  Async.it("warns once when one resolver holds more than a quarter of the pool", async t => {
    let warnings = []
    let pool = makePool(~poolSize=8, ~onWarn=message => warnings->Array.push(message)->ignore, ())
    let db = pool->ResolverDb.forResolver({name: "wide", timeoutMs: 5000})
    let sleep = (): promise<array<unknown>> =>
      db->ResolverDb.sqlOf->ResolverDb.unsafe("SELECT pg_sleep(0.2);", [])
    let _ = await Promise.all([sleep(), sleep(), sleep()])
    await pool->ResolverDb.endPool
    t.expect(warnings).toEqual([
      "Resolver 'wide' held 3 of the pool's 8 connections at once. The pool is sized as concurrent heavy requests x per-request fan-out, so a fan-out this wide needs a larger pool or fewer concurrent queries.",
    ])
  })

  Async.it("holds one connection and one timeout across a transaction's queries", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "batched", timeoutMs: 1000})
    let result = await db->ResolverDb.transaction(async tx => {
      let first: array<{"pid": int}> = await tx->Postgres.unsafe("SELECT pg_backend_pid() AS pid;")
      let second: array<{"pid": int}> = await tx->Postgres.unsafe("SELECT pg_backend_pid() AS pid;")
      let shown: array<{"statement_timeout": string}> =
        await tx->Postgres.unsafe("SHOW statement_timeout;")
      (
        first->Array.getUnsafe(0)->(row => row["pid"]) ===
          second->Array.getUnsafe(0)->(row => row["pid"]),
        shown->Array.getUnsafe(0)->(row => row["statement_timeout"]),
      )
    })
    let tagged = await db->ResolverDb.taggedSelectOne
    await pool->ResolverDb.endPool
    t.expect((result, tagged->Array.getUnsafe(0)->(row => row["n"]))).toEqual(((true, "1s"), 1))
  })

  Async.it("filters by a set, and pages the result", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "page", timeoutMs: 5000})
    let positions: array<position> = await db->ResolverDb.find(
      "Position",
      {
        where: dict{
          "id": {"_in": ["p1", "p2", "p3"]}->(Utils.magic: {"_in": array<string>} => unknown),
        },
        orderBy: [{field: "id", direction: "asc"}],
        limit: 1,
        offset: 1,
      },
    )
    await pool->ResolverDb.endPool
    t.expect(positions).toEqual([{id: "p2", account: "0xaaa", sizeInUsd: 250n, isLong: false}])
  })

  Async.it("names the entity's own fields when a filter misspells one", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "typo", timeoutMs: 5000})
    let caught = try {
      let _: array<position> = await db->ResolverDb.find(
        "Position",
        {where: dict{"acount": {"_eq": "0xaaa"}->(Utils.magic: {"_eq": string} => unknown)}},
      )
      None
    } catch {
    | exn => asError(exn)
    }
    await pool->ResolverDb.endPool
    t.expect(caught->Option.map(e => e.message)).toEqual(
      Some(
        `Invalid field "acount" in db.find("Position", { where: ... }). The entity has no such field.`,
      ),
    )
  })

  Async.it("refuses a bare get on a per-chain entity, where the id isn't the key", async t => {
    let pool = ResolverDb.createPool({
      connection: {
        host: Env.Db.host,
        port: Env.Db.port,
        username: Env.Db.user,
        password: Env.Db.password,
        database: Env.Db.database,
        ssl: Env.Db.ssl,
      },
      entities: perChainConfig.userEntitiesByName,
      pgSchema,
    })
    let db = pool->ResolverDb.forResolver({name: "ambiguous", timeoutMs: 5000})
    let caught = try {
      let _: Nullable.t<position> = await db->ResolverDb.get("Position", "p1")
      None
    } catch {
    | exn => asError(exn)
    }
    await pool->ResolverDb.endPool
    t.expect(caught->Option.map(e => e.message)).toEqual(
      Some(
        `db.get("Position", id) is ambiguous: the entity is per-chain, so the same id can exist on every chain. Use db.find("Position", { where: { id: { _eq: id }, chainId: { _eq: chainId } } }).`,
      ),
    )
  })

  // The one behaviour that differs between the two connection paths. A pool of
  // one keeps every query on the same backend, so pg_prepared_statements is
  // reporting on the connection the loaders just ran on.
  Async.it("prepares loader queries on the direct path, and not behind the pooler", async t => {
    let countPrepared = async (~poolerBacked) => {
      let pool = ResolverDb.createPool({
        connection: {
          host: Env.Db.host,
          port: Env.Db.port,
          username: Env.Db.user,
          password: Env.Db.password,
          database: Env.Db.database,
          ssl: Env.Db.ssl,
        },
        entities: config.userEntitiesByName,
        pgSchema,
        poolSize: 1,
        poolerBacked,
      })
      let db = pool->ResolverDb.forResolver({name: "prepared", timeoutMs: 5000})
      let _: array<position> = await db->ResolverDb.find("Position", {})
      let _: array<position> = await db->ResolverDb.find("Position", {})
      let rows: array<{"n": int}> =
        await db
        ->ResolverDb.sqlOf
        ->ResolverDb.unsafe("SELECT count(*)::int AS n FROM pg_prepared_statements;", [])
      await pool->ResolverDb.endPool
      rows->Array.getUnsafe(0)->(row => row["n"])
    }
    let direct = await countPrepared(~poolerBacked=false)
    let pooled = await countPrepared(~poolerBacked=true)
    t.expect((direct > 0, pooled)).toEqual((true, 0))
  })

  Async.it("exposes the per-chain freshness watermark", async t => {
    let pool = makePool()
    let db = pool->ResolverDb.forResolver({name: "fresh", timeoutMs: 5000})
    let heights = await db->ResolverDb.chainHeights
    await pool->ResolverDb.endPool
    t.expect(heights->Dict.get("1337")).toEqual(
      Some({
        ResolverDb.chainId: ChainId.fromInt(1337),
        ecosystem: "evm",
        startBlock: 1,
        endBlock: Null.null,
        sourceBlock: 0,
        bufferBlock: -1,
        progressBlock: -1,
        readyAt: Null.null,
        isReady: false,
      }),
    )
  })
})
