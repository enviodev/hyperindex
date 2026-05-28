// DuckDB sink bindings for @duckdb/node-api (the "Neo" client).
//
// DuckDB mirrors Postgres as an append-only history store, identical in shape
// to the ClickHouse sink: one `envio_history_<entity>` table per entity, a
// shared `envio_checkpoints` table, and a current-state VIEW per entity. The
// reorg path deletes history/checkpoint rows above the rollback target.
//
// Two deliberate simplifications versus ClickHouse:
//   - Entity data columns are typed VARCHAR. DuckDB is embedded and we can't
//     verify richer per-type appends here, so values are serialized to text
//     for a robust first pass. Only the control columns the reorg/view logic
//     depends on are typed: `envio_checkpoint_id` and checkpoints `id` are
//     BIGINT. Analytics queries can CAST as needed.
//   - The whole `main` schema is wiped on initialize, matching ClickHouse's
//     TRUNCATE DATABASE. The DuckDB file is meant to be Envio-dedicated.
//
// Appender uses @duckdb/node-api: appendVarchar/appendBigInt/appendNull/endRow
// plus synchronous flushSync/closeSync.

type instance
type connection
type appender
type reader

@module("@duckdb/node-api") @scope("DuckDBInstance")
external createInstance: string => promise<instance> = "create"

@send external connect: instance => promise<connection> = "connect"
@send external run: (connection, string) => promise<unit> = "run"
@send external runAndReadAll: (connection, string) => promise<reader> = "runAndReadAll"
@send external getRowObjects: reader => array<'a> = "getRowObjects"

@send external createAppender: (connection, string) => promise<appender> = "createAppender"
@send external appendVarchar: (appender, string) => unit = "appendVarchar"
@send external appendBigInt: (appender, bigint) => unit = "appendBigInt"
@send external appendNull: appender => unit = "appendNull"
@send external endRow: appender => unit = "endRow"
@send external flushSync: appender => unit = "flushSync"
@send external closeSync: appender => unit = "closeSync"

let checkpointsTableName = InternalTable.Checkpoints.table.tableName
let checkpointsIdField = (#id: InternalTable.Checkpoints.field :> string)

// JS values arrive already converted; bigint and nested bigints (e.g. arrays
// of uint256) break JSON.stringify, so handle them explicitly.
let stringifyValue: unknown => Nullable.t<string> = %raw(`(v) => {
  if (v === null || v === undefined) return null;
  const t = typeof v;
  if (t === "string") return v;
  if (t === "bigint") return v.toString();
  if (t === "boolean") return v ? "true" : "false";
  if (t === "number") return v.toString();
  if (v instanceof Date) return v.toISOString();
  return JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x));
}`)

let appendCell = (appender, value: option<unknown>) =>
  switch value {
  | None => appender->appendNull
  | Some(v) =>
    switch stringifyValue(v)->Nullable.toOption {
    | Some(s) => appender->appendVarchar(s)
    | None => appender->appendNull
    }
  }

let entityFieldNames = (entityConfig: Internal.entityConfig) =>
  entityConfig.table.fields->Belt.Array.keepMap(field =>
    switch field {
    | Field(f) => Some(f->Table.getDbFieldName)
    | DerivedFrom(_) => None
    }
  )

let makeCreateHistoryTableQuery = (~entityConfig: Internal.entityConfig) => {
  let cols = entityFieldNames(entityConfig)->Array.map(name => `"${name}" VARCHAR`)
  `CREATE TABLE IF NOT EXISTS "${EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )}" (
  ${cols->Array.joinUnsafe(",\n  ")},
  "${EntityHistory.checkpointIdFieldName}" BIGINT NOT NULL,
  "${EntityHistory.changeFieldName}" VARCHAR NOT NULL
)`
}

let makeCreateCheckpointsTableQuery = () => {
  let chainIdField = (#chain_id: InternalTable.Checkpoints.field :> string)
  let blockNumberField = (#block_number: InternalTable.Checkpoints.field :> string)
  let blockHashField = (#block_hash: InternalTable.Checkpoints.field :> string)
  let eventsProcessedField = (#events_processed: InternalTable.Checkpoints.field :> string)
  `CREATE TABLE IF NOT EXISTS "${checkpointsTableName}" (
  "${checkpointsIdField}" BIGINT NOT NULL,
  "${chainIdField}" VARCHAR,
  "${blockNumberField}" VARCHAR,
  "${blockHashField}" VARCHAR,
  "${eventsProcessedField}" VARCHAR
)`
}

// Current state = latest change per id up to the committed checkpoint,
// dropping ids whose latest change is a DELETE.
let makeCreateViewQuery = (~entityConfig: Internal.entityConfig) => {
  let fields =
    entityFieldNames(entityConfig)->Array.map(name => `"${name}"`)->Array.joinUnsafe(", ")
  `CREATE VIEW IF NOT EXISTS "${entityConfig.name}" AS
SELECT ${fields}
FROM "${EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )}"
WHERE "${EntityHistory.checkpointIdFieldName}" <= (SELECT max("${checkpointsIdField}") FROM "${checkpointsTableName}")
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY "${Table.idFieldName}"
    ORDER BY "${EntityHistory.checkpointIdFieldName}" DESC
  ) = 1
  AND "${EntityHistory.changeFieldName}" = '${(EntityHistory.RowAction.SET :> string)}'`
}

let initialize = async (conn, ~entities: array<Internal.entityConfig>) => {
  try {
    // Wipe the dedicated Envio file for a clean slate. Drop views before
    // tables so view→table dependencies don't block the drops.
    let existing = await conn->runAndReadAll(`SELECT table_name, table_type FROM information_schema.tables WHERE table_catalog = current_database() AND table_schema = 'main'`)
    let rows: array<{"table_name": string, "table_type": string}> = existing->getRowObjects
    let (views, tables) = rows->Belt.Array.partition(r => r["table_type"] === "VIEW")
    await views
    ->Belt.Array.map(r => conn->run(`DROP VIEW IF EXISTS "${r["table_name"]}"`))
    ->Promise.all
    ->Utils.Promise.ignoreValue
    await tables
    ->Belt.Array.map(r => conn->run(`DROP TABLE IF EXISTS "${r["table_name"]}"`))
    ->Promise.all
    ->Utils.Promise.ignoreValue

    await entities
    ->Belt.Array.map(entityConfig => conn->run(makeCreateHistoryTableQuery(~entityConfig)))
    ->Promise.all
    ->Utils.Promise.ignoreValue
    await conn->run(makeCreateCheckpointsTableQuery())
    await entities
    ->Belt.Array.map(entityConfig => conn->run(makeCreateViewQuery(~entityConfig)))
    ->Promise.all
    ->Utils.Promise.ignoreValue

    Logging.trace("DuckDB storage initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize DuckDB storage")
      JsError.throwWithMessage("DuckDB initialization failed")
    }
  }
}

let resume = async (conn, ~checkpointId: Internal.checkpointId) => {
  try {
    let id = checkpointId->BigInt.toString
    let tablesResult = await conn->runAndReadAll(
      `SELECT table_name FROM information_schema.tables WHERE table_catalog = current_database() AND table_schema = 'main' AND table_name LIKE '${EntityHistory.historyTablePrefix}%'`,
    )
    let tables: array<{"table_name": string}> = tablesResult->getRowObjects
    await tables
    ->Belt.Array.map(t =>
      conn->run(
        `DELETE FROM "${t["table_name"]}" WHERE "${EntityHistory.checkpointIdFieldName}" > ${id}`,
      )
    )
    ->Promise.all
    ->Utils.Promise.ignoreValue
    await conn->run(`DELETE FROM "${checkpointsTableName}" WHERE "${checkpointsIdField}" > ${id}`)
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume DuckDB storage")
      JsError.throwWithMessage("DuckDB resume failed")
    }
  }
}

let setUpdates = async (
  conn,
  ~updates: array<Internal.inMemoryStoreEntityUpdate<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
) => {
  if updates->Array.length === 0 {
    ()
  } else {
    let tableName = EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )
    let fieldNames = entityFieldNames(entityConfig)
    let appender = await conn->createAppender(tableName)
    updates->Array.forEach(update => {
      switch update.latestChange {
      | Set({entity, checkpointId, _}) =>
        let dict = entity->(Utils.magic: Internal.entity => dict<unknown>)
        fieldNames->Array.forEach(name => appender->appendCell(dict->Dict.get(name)))
        appender->appendBigInt(checkpointId)
        appender->appendVarchar((EntityHistory.RowAction.SET :> string))
      | Delete({entityId, checkpointId}) =>
        fieldNames->Array.forEach(name =>
          name === Table.idFieldName ? appender->appendVarchar(entityId) : appender->appendNull
        )
        appender->appendBigInt(checkpointId)
        appender->appendVarchar((EntityHistory.RowAction.DELETE :> string))
      }
      appender->endRow
    })
    appender->flushSync
    appender->closeSync
  }
}

let setCheckpoints = async (conn, ~batch: Batch.t) => {
  let count = batch.checkpointIds->Array.length
  if count === 0 {
    ()
  } else {
    let appender = await conn->createAppender(checkpointsTableName)
    for idx in 0 to count - 1 {
      appender->appendBigInt(batch.checkpointIds->Belt.Array.getUnsafe(idx))
      appender->appendVarchar(batch.checkpointChainIds->Belt.Array.getUnsafe(idx)->Int.toString)
      appender->appendVarchar(batch.checkpointBlockNumbers->Belt.Array.getUnsafe(idx)->Int.toString)
      switch batch.checkpointBlockHashes->Belt.Array.getUnsafe(idx)->Null.toOption {
      | Some(hash) => appender->appendVarchar(hash)
      | None => appender->appendNull
      }
      appender->appendVarchar(
        batch.checkpointEventsProcessed->Belt.Array.getUnsafe(idx)->Int.toString,
      )
      appender->endRow
    }
    appender->flushSync
    appender->closeSync
  }
}

let writeBatch = async (
  conn,
  ~batch: Batch.t,
  ~updatedEntities: array<Persistence.updatedEntity>,
) => {
  try {
    await conn->run("BEGIN TRANSACTION")
    // Sequential: a single DuckDB connection can't drive concurrent appenders.
    for i in 0 to updatedEntities->Array.length - 1 {
      let {entityConfig, updates}: Persistence.updatedEntity =
        updatedEntities->Belt.Array.getUnsafe(i)
      await setUpdates(conn, ~updates, ~entityConfig)
    }
    await setCheckpoints(conn, ~batch)
    await conn->run("COMMIT")
  } catch {
  | exn =>
    let _ = await conn->run("ROLLBACK")->Promise.catch(_ => Promise.resolve())
    throw(
      Persistence.StorageError({
        message: "Failed to write batch into DuckDB",
        reason: exn->Utils.prettifyExn,
      }),
    )
  }
}
