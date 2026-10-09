// Every indexer under test gets its own Postgres schema, so test files can run
// in parallel against one database. The name carries the creation time so a
// worker killed mid-test can still have its schema collected later by `sweep`.

@val external pid: int = "process.pid"

let prefix = "envio_test_"

let counter = ref(0)

// `<prefix><createdAtMs>_<pid>_<counter>` — well under Postgres' 63-byte
// identifier limit. The pid keeps names unique across the parallel workers,
// the counter across indexers within one worker.
let make = () => {
  counter := counter.contents + 1
  `${prefix}${Date.now()->Float.toString}_${pid->Int.toString}_${counter.contents->Int.toString}`
}

let parseCreatedAt = name =>
  if name->String.startsWith(prefix) {
    name
    ->String.slice(~start=prefix->String.length)
    ->String.split("_")
    ->Array.get(0)
    ->Option.flatMap(Float.fromString)
  } else {
    None
  }

let drop = async (sql, ~pgSchema) => {
  let _ = await sql->Sql.queryForTests(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
}

let staleAfterMs = 60. *. 60. *. 1000.

// Collects schemas left behind by workers that died before their cleanup ran.
// Only touches schemas older than an hour, so it can't race a live test.
let sweep = async sql => {
  let rows: array<{
    "schema_name": string,
  }> = await sql->Sql.queryForTests(
    `SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '${prefix}%';`,
  )
  let now = Date.now()
  let stale = rows->Array.filterMap(row => {
    let name = row["schema_name"]
    switch name->parseCreatedAt {
    | Some(createdAt) if now -. createdAt > staleAfterMs => Some(name)
    | _ => None
    }
  })
  // Best effort: this runs before the suite, and a schema that refuses to drop
  // (someone still connected to it, say) must not stop the tests from running.
  let dropped = []
  for i in 0 to stale->Array.length - 1 {
    let pgSchema = stale->Array.getUnsafe(i)
    switch await sql->drop(~pgSchema) {
    | () => dropped->Array.push(pgSchema)->ignore
    | exception _ => ()
    }
  }
  dropped
}

let emptyBatch: PgClient.batch = {
  progress: [],
  entities: [],
  chainMeta: [],
  addresses: {chainIds: [], addresses: [], contractIds: []},
  frontier: {chainIds: [], checkpointIds: []},
  checkpoints: {
    ids: [],
    chainIds: [],
    blockNumbers: [],
    blockHashes: [],
    eventsProcessed: [],
  },
  effectCaches: [],
}

// Rows written straight into a table, the way an effect cache's write goes:
// outside any batch, with the table created first when `create` says so. For
// setting up what a read is tested against.
let write = async (
  ~pgSchema,
  ~table: Table.table,
  ~itemSchema: S.t<unknown>,
  ~items: array<unknown>,
  ~create=false,
) => {
  let sql = PgStorage.makeClient(~pgSchema, ~maxConnections=1)
  let registered = sql->PgStorage.register(~table, ~itemSchema)
  try {
    await sql->PgClient.writeBatch(
      {
        ...emptyBatch,
        effectCaches: [
          {
            table: registered.handle,
            create,
            rows: sql->PgStorage.rowsOrThrow(registered, ~itemSchema, items, ~staged=[]),
          },
        ],
      },
      Null.null,
    )
  } catch {
  | exn =>
    await sql->Sql.close
    throw(exn)
  }
  await sql->Sql.close
  registered
}
