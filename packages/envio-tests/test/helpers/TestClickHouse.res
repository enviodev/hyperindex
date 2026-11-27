// Every indexer under test gets its own ClickHouse database, the same way it
// gets its own Postgres schema, so files can run in parallel against one server.
//
// A run reaches its database through its config's `env.clickHouse`.

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

let make = TestPgSchema.make

// The database of the run that last took one, for a test to read back.
%%private(let current = ref(None))

// The settings that point a run's config at `database`.
let use = (~database): IndexerEnv.clickHouse => {
  current := Some(database)
  {host: host(), username: username(), password: password(), database, replicated: false}
}

let drop = async (~database) => {
  let _ = await query(`DROP DATABASE IF EXISTS \`${database}\``)
}

let currentDatabase = () =>
  switch current.contents {
  | Some(database) => database
  | None => JsError.throwWithMessage("No ClickHouse database is configured for this run.")
  }
