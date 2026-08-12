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
  let _ = await sql->Postgres.unsafe(`DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`)
}

let staleAfterMs = 60. *. 60. *. 1000.

// Collects schemas left behind by workers that died before their cleanup ran.
// Only touches schemas older than an hour, so it can't race a live test.
let sweep = async sql => {
  let rows: array<{"schema_name": string}> =
    await sql->Postgres.unsafe(
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
