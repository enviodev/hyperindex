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

// The env `use` sets, as it was before, for a run to put back once it is done:
// a later run in the same worker that provides no database of its own must not
// find this one's.
let savedEnv = () => {
  let env = NodeJs.Process.process.env
  let names = [
    "ENVIO_CLICKHOUSE_HOST",
    "ENVIO_CLICKHOUSE_USERNAME",
    "ENVIO_CLICKHOUSE_PASSWORD",
    "ENVIO_CLICKHOUSE_DATABASE",
  ]
  let saved = names->Array.map(name => (name, env->Dict.get(name)))
  () =>
    saved->Array.forEach(((name, value)) =>
      switch value {
      | Some(value) => env->Dict.set(name, value)
      | None => env->Dict.delete(name)
      }
    )
}

let jsonRows = async statement =>
  (await query(statement))
  ->String.split("\n")
  ->Array.filter(line => line->String.trim !== "")
  ->Array.map(line => line->JSON.parseOrThrow)

// What ClickHouse alone keeps of the indexer's own state, read as a Postgres
// store of record holds it: only what committed — a row at or below its
// chain's frontier — and none of a rollback's leftovers. A rollback appends
// rather than deletes: the checkpoints it orphaned stay, and so do the rows
// they stamped, and its diff is stamped with a marker checkpoint of its own.
let frontier = (~database) =>
  `(SELECT chain_id AS frontier_chain, checkpoint_id AS frontier FROM \`${database}\`.envio_chains FINAL)`

let notStanding = (~database) =>
  `(SELECT chain_id, id FROM \`${database}\`.envio_checkpoints WHERE rollback_target IS NOT NULL OR arrayExists(marker -> marker.1 = chain_id AND id > marker.2 AND id < marker.3, (SELECT groupArray((chain_id, assumeNotNull(rollback_target), id)) FROM \`${database}\`.envio_checkpoints WHERE rollback_target IS NOT NULL)))`

// Filtered in an inner query: an alias the outer one gives a column under its
// own name would otherwise stand in for the column in the filter.
let committedCheckpoints = (~database) =>
  jsonRows(
    `SELECT toString(id) AS id, toString(chain_id) AS chain_id, block_number, block_hash, toInt64(events_processed) AS events_processed FROM (SELECT * FROM \`${database}\`.envio_checkpoints INNER JOIN ${frontier(
        ~database,
      )} AS f ON chain_id = frontier_chain WHERE id <= frontier AND (chain_id, id) NOT IN ${notStanding(
        ~database,
      )} ORDER BY id, chain_id LIMIT 1 BY chain_id, id) FORMAT JSONEachRow SETTINGS output_format_json_quote_64bit_integers = 0`,
  )

// The latest change of each registration, where it is a set.
let committedAddresses = (~database) =>
  jsonRows(
    `SELECT toString(chain_id) AS chainId, hex(address) AS address, contract_id AS contractId, registration_block AS registrationBlock, envio_change FROM (SELECT * FROM \`${database}\`.envio_addresses INNER JOIN ${frontier(
        ~database,
      )} AS f ON chain_id = frontier_chain WHERE envio_checkpoint_id <= frontier ORDER BY chain_id, address, contract_id, envio_checkpoint_id DESC LIMIT 1 BY chain_id, address, contract_id) FORMAT JSONEachRow`,
  )->Promise.thenResolve(rows =>
    rows->Array.filterMap(row => {
      let row =
        row->(
          Utils.magic: JSON.t => {
            "chainId": string,
            "address": string,
            "contractId": int,
            "registrationBlock": int,
            "envio_change": string,
          }
        )
      row["envio_change"] === "SET"
        ? Some(
            (
              {
                chainId: row["chainId"]->ChainId.normalizeOrThrow,
                address: NodeJs.Buffer.fromHex(row["address"]),
                contractId: row["contractId"],
                registrationBlock: row["registrationBlock"],
              }: AddressRows.row
            ),
          )
        : None
    })
  )

// A value as the Postgres driver hands it back, for the types JSON text can't
// carry as they are: raw bytes travel as hex, a timestamp as its milliseconds,
// and a document as its text.
let asPostgresAnswers = (value: JSON.t, ~fieldType) => {
  let one = (value: JSON.t) =>
    switch (fieldType, value) {
    | (_, Null) => value
    | ("Bytea", String(hex)) => NodeJs.Buffer.fromHex(hex)->(Utils.magic: NodeJs.Buffer.t => JSON.t)
    | ("Date", Number(millis)) => millis->Date.fromTime->(Utils.magic: Date.t => JSON.t)
    | ("Json", String(text)) => text->JSON.parseOrThrow
    | _ => value
    }
  switch value {
  | Array(values) => values->Array.map(one)->JSON.Encode.array
  | _ => value->one
  }
}

// An entity's history rows under the names Postgres gives its columns, with
// the 64-bit and decimal values as text, the way Postgres answers them.
let committedHistory = (~database, ~table: StorageClient.clickHouseTable) => {
  let columns =
    table.columns
    ->Array.map(column => {
      let value = switch column.fieldType {
      | "Bytea" => Some("hex(x)")
      | "Date" => Some("toUnixTimestamp64Milli(x)")
      | _ => None
      }
      let selected = switch (value, column.isArray) {
      | (None, _) => `\`${column.name}\``
      | (Some(value), Some(true)) => `arrayMap(x -> ${value}, \`${column.name}\`)`
      | (Some(value), _) => value->String.replace("(x)", `(\`${column.name}\`)`)
      }
      `${selected} AS \`${column.rowName->Option.getOr(column.name)}\``
    })
    ->Array.joinUnsafe(", ")
  let convert = (row: JSON.t) => {
    let row = row->(Utils.magic: JSON.t => dict<JSON.t>)
    table.columns->Array.forEach(column => {
      let name = column.rowName->Option.getOr(column.name)
      switch row->Dict.get(name) {
      | Some(value) => row->Dict.set(name, value->asPostgresAnswers(~fieldType=column.fieldType))
      | None => ()
      }
    })
    row->(Utils.magic: dict<JSON.t> => JSON.t)
  }
  let history = `\`${database}\`.\`${table.historyTable->Option.getOrThrow}\``
  // A cross-chain entity only exists under one shared sequence, where an id
  // names one checkpoint whichever chain it is.
  let (joined, stamped, notStanding) = switch table.chainIdColumn {
  | Some(chainColumn) => (
      `INNER JOIN ${frontier(~database)} AS f ON \`${chainColumn}\` = frontier_chain`,
      `(\`${chainColumn}\`, envio_checkpoint_id)`,
      notStanding(~database),
    )
  | None => (
      `CROSS JOIN (SELECT max(checkpoint_id) AS frontier FROM \`${database}\`.envio_chains FINAL) AS f`,
      `envio_checkpoint_id`,
      `(SELECT id FROM ${notStanding(~database)})`,
    )
  }
  jsonRows(
    `SELECT ${columns}, toString(envio_checkpoint_id) AS envio_checkpoint_id, envio_change FROM (SELECT * FROM ${history} ${joined} WHERE envio_checkpoint_id <= frontier AND ${stamped} NOT IN ${notStanding} LIMIT 1 BY ${stamped}, \`id\`) FORMAT JSONEachRow SETTINGS output_format_json_quote_decimals = 1`,
  )->Promise.thenResolve(rows => rows->Array.map(convert))
}

// A storage with ClickHouse alone that never reaches a server: registering a
// table only parses its column types, which is all a staging test needs.
let offlineClient = (~chainIdMode=ChainId.Int32) =>
  Storage.makeClient(
    ~chainIdMode,
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
    kind: Entity,
    clickhouse: ClickHouse.entityTable(entityConfig),
  })

// The database the current run is pointed at, set by `use`.
let currentDatabase = () =>
  switch %raw(`process.env.ENVIO_CLICKHOUSE_DATABASE`)->Nullable.toOption {
  | Some("") | None =>
    JsError.throwWithMessage("No ClickHouse database is configured for this run.")
  | Some(database) => database
  }
