// Every indexer under test gets its own ClickHouse database, the same way it
// gets its own Postgres schema, so files can run in parallel against one server.
//
// The runtime reads `ENVIO_CLICKHOUSE_*` at call time (see `Env.ClickHouse`),
// so pointing a run at its own database is a matter of setting them before the
// storage is built.

@val external pid: int = "process.pid"

let prefix = "envio_test_"

let counter = ref(0)

let host = () =>
  switch %raw(`process.env.ENVIO_CLICKHOUSE_HOST`)->Nullable.toOption {
  | Some("") | None => "http://localhost:8123"
  | Some(host) => host
  }

let username = () =>
  switch %raw(`process.env.ENVIO_CLICKHOUSE_USERNAME`)->Nullable.toOption {
  | Some("") | None => "default"
  | Some(username) => username
  }

let password = () =>
  switch %raw(`process.env.ENVIO_CLICKHOUSE_PASSWORD`)->Nullable.toOption {
  | None => "testing"
  | Some(password) => password
  }

let setEnv: (string, string) => unit = %raw(`(key, value) => {
  process.env[key] = value;
}`)

// Runs a statement over the HTTP interface, which needs no client dependency.
let exec: (~host: string, ~username: string, ~password: string, string) => promise<string> = %raw(`
async (host, username, password, query) => {
  const response = await fetch(host + "/", {
    method: "POST",
    headers: {
      Authorization: "Basic " + Buffer.from(username + ":" + password).toString("base64"),
    },
    body: query,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error("ClickHouse query failed (" + response.status + "): " + text);
  }
  return text;
}
`)

let query = statement => exec(~host=host(), ~username=username(), ~password=password(), statement)

let make = () => {
  counter := counter.contents + 1
  `${prefix}${Date.now()->Float.toString}_${pid->Int.toString}_${counter.contents->Int.toString}`
}

// Points the runtime at `database`. The env is process-global, so this must run
// with no await between it and the storage that reads it — otherwise a second
// run starting in between would redirect this one's writes.
let use = (~database) => {
  setEnv("ENVIO_CLICKHOUSE_HOST", host())
  setEnv("ENVIO_CLICKHOUSE_USERNAME", username())
  setEnv("ENVIO_CLICKHOUSE_PASSWORD", password())
  setEnv("ENVIO_CLICKHOUSE_DATABASE", database)
}

let drop = async (~database) => {
  let _ = await query(`DROP DATABASE IF EXISTS \`${database}\``)
}

let envNames = [
  "ENVIO_CLICKHOUSE_HOST",
  "ENVIO_CLICKHOUSE_USERNAME",
  "ENVIO_CLICKHOUSE_PASSWORD",
  "ENVIO_CLICKHOUSE_DATABASE",
]

// The env `use` sets, as it was before, for a run to put back once it is done:
// a later run in the same worker that provides no database of its own must not
// find this one's.
let savedEnv = () => {
  let env = NodeJs.Process.process.env
  let saved = envNames->Array.map(name => (name, env->Dict.get(name)))
  () =>
    saved->Array.forEach(((name, value)) =>
      switch value {
      | Some(value) => env->Dict.set(name, value)
      | None => env->Dict.delete(name)
      }
    )
}

// A storage that never reaches a server: registering a table only parses its
// column types, which is all a staging test needs, and neither store connects
// before its first statement.
let offlineClient = (~chainIdMode=ChainId.Int32) =>
  Storage.makeClient(
    ~chainIdMode,
    ~postgres=Storage.postgresOptions(~maxConnections=1),
    ~clickhouse={
      url: "http://127.0.0.1:1",
      username: "default",
      password: "",
      database: "unused",
      replicated: false,
    },
  )

let registered = (client, input: StorageClient.tableInput) => {
  let registered = client->StorageClient.registerTable(input)
  ClickHouse.makeTable(
    ~handle=registered.handle,
    ~name=input.name,
    registered.clickhouse->Option.getOrThrow,
  )
}

let entityTable = (client, entityConfig: Internal.entityConfig) =>
  client->registered({
    name: entityConfig.table.tableName,
    clickhouse: ClickHouse.entityTable(entityConfig),
  })

// The database the current run is pointed at, set by `use`.
let currentDatabase = () =>
  switch %raw(`process.env.ENVIO_CLICKHOUSE_DATABASE`)->Nullable.toOption {
  | Some("") | None =>
    JsError.throwWithMessage("No ClickHouse database is configured for this run.")
  | Some(database) => database
  }
