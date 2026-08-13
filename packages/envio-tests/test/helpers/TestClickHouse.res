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

// `<prefix><createdAtMs>_<pid>_<counter>`, mirroring TestPgSchema so the same
// sweeper logic recognises a leftover database.
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

// The database the current run is pointed at, set by `use`.
let currentDatabase = () =>
  switch %raw(`process.env.ENVIO_CLICKHOUSE_DATABASE`)->Nullable.toOption {
  | Some("") | None =>
    JsError.throwWithMessage("No ClickHouse database is configured for this run.")
  | Some(database) => database
  }
