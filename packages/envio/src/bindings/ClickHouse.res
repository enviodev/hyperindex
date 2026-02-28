// ClickHouse client bindings for @clickhouse/client

type client

type clientConfig = {
  url?: string,
  database?: string,
  username?: string,
  password?: string,
}

type execParams = {query: string}

@module("@clickhouse/client")
external createClient: clientConfig => client = "createClient"

@send
external exec: (client, execParams) => promise<unit> = "exec"

@send
external close: client => promise<unit> = "close"

type insertParams<'a> = {
  table: string,
  values: array<'a>,
  format: string,
}

@send
external insert: (client, insertParams<'a>) => promise<unit> = "insert"

type queryParams = {query: string}
type queryResult<'a>

@send
external query: (client, queryParams) => promise<queryResult<'a>> = "query"

@send
external json: queryResult<'a> => promise<'a> = "json"

let getClickHouseFieldType = (
  ~fieldType: Table.fieldType,
  ~isNullable: bool,
  ~isArray: bool,
): string => {
  let baseType = switch fieldType {
  | Int32 => "Int32"
  | Uint32 => "UInt32"
  | Serial => "Int32"
  | BigInt({?precision}) =>
    switch precision {
    | None => "String" // Fallback for unbounded BigInt
    | Some(precision) =>
      if precision > 38 {
        "String"
      } else {
        `Decimal(${precision->Js.Int.toString},0)`
      }
    }
  | BigDecimal({?config}) =>
    switch config {
    | None => "String" // Fallback for unbounded BigDecimal
    | Some((precision, scale)) =>
      if precision > 38 || scale > precision {
        "String"
      } else {
        `Decimal(${precision->Js.Int.toString},${scale->Js.Int.toString})`
      }
    }
  | Boolean => "Bool"
  | Number => "Float64"
  | String => "String"
  | Json => "String"
  | Date => "DateTime64(3, 'UTC')"
  | Enum({config}) => {
      let variantsLength = config.variants->Belt.Array.length
      // Theoretically we can store 256 variants in Enum8,
      // but it'd require to explicitly start with a negative index (probably)
      let enumType = variantsLength <= 127 ? "Enum8" : "Enum16"
      let enumValues =
        config.variants
        ->Belt.Array.map(variant => {
          let variantStr = variant->(Utils.magic: 'a => string)
          `'${variantStr}'`
        })
        ->Js.Array2.joinWith(", ")
      `${enumType}(${enumValues})`
    }
  | Entity(_) => "String"
  }

  let baseType = if isArray {
    `Array(${baseType})`
  } else {
    baseType
  }

  isNullable ? `Nullable(${baseType})` : baseType
}

// Creates an entity schema from table definition, using clickHouseDate for Date fields
let makeClickHouseEntitySchema = (table: Table.table): S.t<Internal.entity> => {
  S.schema(s => {
    let dict = Js.Dict.empty()
    table.fields->Belt.Array.forEach(field => {
      switch field {
      | Field(f) => {
          let fieldName = f->Table.getDbFieldName
          let fieldSchema = switch f.fieldType {
          | Date => {
              let dateSchema = Utils.Schema.clickHouseDate->S.toUnknown
              if f.isNullable {
                S.null(dateSchema)->S.toUnknown
              } else if f.isArray {
                S.array(dateSchema)->S.toUnknown
              } else {
                dateSchema
              }
            }
          | _ => f.fieldSchema
          }
          dict->Js.Dict.set(fieldName, s.matches(fieldSchema))
        }
      | DerivedFrom(_) => () // Skip derived fields
      }
    })
    dict->(Utils.magic: Js.Dict.t<unknown> => Internal.entity)
  })
}

let setCheckpointsOrThrow = async (client, ~batch: Batch.t, ~database: string) => {
  let checkpointsCount = batch.checkpointIds->Array.length
  if checkpointsCount === 0 {
    ()
  } else {
    // Convert columnar data to row format for JSONCompactEachRow
    let checkpointRows = []
    for idx in 0 to checkpointsCount - 1 {
      checkpointRows
      ->Js.Array2.push((
        batch.checkpointIds->Belt.Array.getUnsafe(idx),
        batch.checkpointChainIds->Belt.Array.getUnsafe(idx),
        batch.checkpointBlockNumbers->Belt.Array.getUnsafe(idx),
        batch.checkpointBlockHashes->Belt.Array.getUnsafe(idx),
        batch.checkpointEventsProcessed->Belt.Array.getUnsafe(idx),
      ))
      ->ignore
    }

    try {
      await client->insert({
        table: `${database}.\`${InternalTable.Checkpoints.table.tableName}\``,
        values: checkpointRows,
        format: "JSONCompactEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert checkpoints into ClickHouse table "${InternalTable.Checkpoints.table.tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

let setUpdatesOrThrow = async (
  client,
  ~updates: array<Internal.inMemoryStoreEntityUpdate<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
  ~database: string,
) => {
  if updates->Array.length === 0 {
    ()
  } else {
    let {convertOrThrow, tableName} = switch entityConfig.clickHouseSetUpdatesCache {
    | Some(cache) => cache
    | None =>
      let cache: Internal.clickHouseSetUpdatesCache = {
        tableName: `${database}.\`${EntityHistory.historyTableName(
            ~entityName=entityConfig.name,
            ~entityIndex=entityConfig.index,
          )}\``,
        convertOrThrow: S.compile(
          S.union([
            EntityHistory.makeSetUpdateSchema(makeClickHouseEntitySchema(entityConfig.table)),
            S.object(s => {
              s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
              Change.Delete({
                entityId: s.field(Table.idFieldName, S.string),
                checkpointId: s.field(
                  EntityHistory.checkpointIdFieldName,
                  EntityHistory.unsafeCheckpointIdSchema,
                ),
              })
            }),
          ]),
          ~input=Value,
          ~output=Json,
          ~typeValidation=false,
          ~mode=Sync,
        ),
      }

      entityConfig.clickHouseSetUpdatesCache = Some(cache)
      cache
    }

    try {
      // Convert entity updates to ClickHouse row format
      let values = updates->Js.Array2.map(update => {
        update.latestChange->convertOrThrow
      })

      await client->insert({
        table: tableName,
        values,
        format: "JSONEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert items into ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Generate CREATE TABLE query for entity history table
let makeCreateHistoryTableQuery = (~entityConfig: Internal.entityConfig, ~database: string) => {
  let fieldDefinitions = entityConfig.table.fields->Belt.Array.keepMap(field => {
    switch field {
    | Field(field) =>
      Some({
        let fieldName = field->Table.getDbFieldName
        let clickHouseType = getClickHouseFieldType(
          ~fieldType=field.fieldType,
          ~isNullable=field.isNullable,
          ~isArray=field.isArray,
        )
        `\`${fieldName}\` ${clickHouseType}`
      })
    | DerivedFrom(_) => None
    }
  })

  `CREATE TABLE IF NOT EXISTS ${database}.\`${EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )}\` (
  ${fieldDefinitions->Js.Array2.joinWith(",\n  ")},
  \`${EntityHistory.checkpointIdFieldName}\` ${getClickHouseFieldType(
      ~fieldType=Uint32,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${EntityHistory.changeFieldName}\` ${getClickHouseFieldType(
      ~fieldType=Enum({config: EntityHistory.RowAction.config->Table.fromGenericEnumConfig}),
      ~isNullable=false,
      ~isArray=false,
    )}
)
ENGINE = MergeTree()
ORDER BY (${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName})`
}

// Generate CREATE TABLE query for checkpoints
let makeCreateCheckpointsTableQuery = (~database: string) => {
  let idField = (#id: InternalTable.Checkpoints.field :> string)
  let chainIdField = (#chain_id: InternalTable.Checkpoints.field :> string)
  let blockNumberField = (#block_number: InternalTable.Checkpoints.field :> string)
  let blockHashField = (#block_hash: InternalTable.Checkpoints.field :> string)
  let eventsProcessedField = (#events_processed: InternalTable.Checkpoints.field :> string)

  `CREATE TABLE IF NOT EXISTS ${database}.\`${InternalTable.Checkpoints.table.tableName}\` (
  \`${idField}\` ${getClickHouseFieldType(~fieldType=Int32, ~isNullable=false, ~isArray=false)},
  \`${chainIdField}\` ${getClickHouseFieldType(
      ~fieldType=Int32,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${blockNumberField}\` ${getClickHouseFieldType(
      ~fieldType=Int32,
      ~isNullable=false,
      ~isArray=false,
    )},
  \`${blockHashField}\` ${getClickHouseFieldType(
      ~fieldType=String,
      ~isNullable=true,
      ~isArray=false,
    )},
  \`${eventsProcessedField}\` ${getClickHouseFieldType(
      ~fieldType=Int32,
      ~isNullable=false,
      ~isArray=false,
    )}
)
ENGINE = MergeTree()
ORDER BY (${idField})`
}

// Generate CREATE VIEW query for entity current state
let makeCreateViewQuery = (~entityConfig: Internal.entityConfig, ~database: string) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )

  let checkpointsTableName = InternalTable.Checkpoints.table.tableName
  let checkpointIdField = (#id: InternalTable.Checkpoints.field :> string)

  let entityFields =
    entityConfig.table.fields
    ->Belt.Array.keepMap(field => {
      switch field {
      | Field(field) => {
          let fieldName = field->Table.getDbFieldName
          Some(`\`${fieldName}\``)
        }
      | DerivedFrom(_) => None
      }
    })
    ->Js.Array2.joinWith(", ")

  `CREATE VIEW IF NOT EXISTS ${database}.\`${entityConfig.name}\` AS
SELECT ${entityFields}
FROM (
  SELECT ${entityFields}, \`${EntityHistory.changeFieldName}\`
  FROM ${database}.\`${historyTableName}\`
  WHERE \`${EntityHistory.checkpointIdFieldName}\` <= (SELECT max(${checkpointIdField}) FROM ${database}.\`${checkpointsTableName}\`)
  ORDER BY \`${EntityHistory.checkpointIdFieldName}\` DESC
  LIMIT 1 BY \`${Table.idFieldName}\`
)
WHERE \`${EntityHistory.changeFieldName}\` = '${(EntityHistory.RowAction.SET :> string)}'`
}

// Generate CREATE TABLE query for chains (using ReplacingMergeTree for upserts)
let makeCreateChainsTableQuery = (~database: string) => {
  `CREATE TABLE IF NOT EXISTS ${database}.\`${InternalTable.Chains.table.tableName}\` (
  \`id\` Int32,
  \`start_block\` Int32,
  \`end_block\` Nullable(Int32),
  \`max_reorg_depth\` Int32,
  \`source_block\` Int32,
  \`first_event_block\` Nullable(Int32),
  \`buffer_block\` Int32,
  \`progress_block\` Int32,
  \`ready_at\` Nullable(DateTime64(3, 'UTC')),
  \`events_processed\` Int32,
  \`_is_hyper_sync\` Bool,
  \`_num_batches_fetched\` Int32
)
ENGINE = ReplacingMergeTree()
ORDER BY (id)`
}

// Generate CREATE TABLE query for raw events
let makeCreateRawEventsTableQuery = (~database: string) => {
  `CREATE TABLE IF NOT EXISTS ${database}.\`${InternalTable.RawEvents.table.tableName}\` (
  \`chain_id\` Int32,
  \`event_id\` Int64,
  \`event_name\` String,
  \`contract_name\` String,
  \`block_number\` Int32,
  \`log_index\` Int32,
  \`src_address\` String,
  \`block_hash\` String,
  \`block_timestamp\` Int32,
  \`block_fields\` String,
  \`transaction_fields\` String,
  \`params\` String,
  \`serial\` Nullable(Int32)
)
ENGINE = MergeTree()
ORDER BY (chain_id, block_number, log_index)`
}

// Generate CREATE TABLE query for effect cache
let makeCreateEffectCacheTableQuery = (~tableName: string, ~database: string) => {
  `CREATE TABLE IF NOT EXISTS ${database}.\`${tableName}\` (
  \`id\` String,
  \`output\` String
)
ENGINE = ReplacingMergeTree()
ORDER BY (id)`
}

// Initialize ClickHouse tables for entities
let initialize = async (
  client,
  ~database: string,
  ~entities: array<Internal.entityConfig>,
  ~enums as _: array<Table.enumConfig<Table.enum>>,
) => {
  try {
    await client->exec({query: `TRUNCATE DATABASE IF EXISTS ${database}`})
    await client->exec({query: `CREATE DATABASE IF NOT EXISTS ${database}`})
    await client->exec({query: `USE ${database}`})

    await Promise.all(
      entities->Belt.Array.map(entityConfig =>
        client->exec({query: makeCreateHistoryTableQuery(~entityConfig, ~database)})
      ),
    )->Promise.ignoreValue
    await client->exec({query: makeCreateCheckpointsTableQuery(~database)})
    await client->exec({query: makeCreateChainsTableQuery(~database)})
    await client->exec({query: makeCreateRawEventsTableQuery(~database)})

    await Promise.all(
      entities->Belt.Array.map(entityConfig =>
        client->exec({query: makeCreateViewQuery(~entityConfig, ~database)})
      ),
    )->Promise.ignoreValue

    Logging.trace("ClickHouse initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse")
      Js.Exn.raiseError("ClickHouse initialization failed")
    }
  }
}

// Helper to run a query and get JSON results
let queryJson = async (client, ~query as q) => {
  let result = await client->query({query: q})
  await result->json
}

// Insert chains initial state
let insertChainsOrThrow = async (
  client,
  ~database: string,
  ~chainConfigs: array<Config.chain>,
) => {
  if chainConfigs->Array.length === 0 {
    ()
  } else {
    let values = chainConfigs->Js.Array2.map((chainConfig: Config.chain) => {
      let initial = InternalTable.Chains.initialFromConfig(chainConfig)
      initial->(Utils.magic: InternalTable.Chains.t => Js.Json.t)
    })

    try {
      await client->insert({
        table: `${database}.\`${InternalTable.Chains.table.tableName}\``,
        values,
        format: "JSONEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert chains into ClickHouse`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Update chain progress fields
let setProgressedChainsOrThrow = async (
  client,
  ~database: string,
  ~progressedChains: array<InternalTable.Chains.progressedChain>,
) => {
  // ClickHouse doesn't support UPDATE, so we insert new rows
  // and ReplacingMergeTree will keep the latest version
  if progressedChains->Array.length === 0 {
    ()
  } else {
    // We need to read current chain data and merge with progress updates
    let chainIds =
      progressedChains->Js.Array2.map(c => c.chainId->Js.Int.toString)->Js.Array2.joinWith(",")

    let existingResult: array<InternalTable.Chains.t> = await queryJson(
      client,
      ~query=`SELECT * FROM ${database}.\`${InternalTable.Chains.table.tableName}\` FINAL WHERE id IN (${chainIds})`,
    )

    let existingMap = Js.Dict.empty()
    existingResult->Js.Array2.forEach(chain => {
      existingMap->Js.Dict.set(chain.id->Js.Int.toString, chain)
    })

    let values = progressedChains->Belt.Array.keepMap(data => {
      switch existingMap->Js.Dict.get(data.chainId->Js.Int.toString) {
      | Some(existing) =>
        Some(
          {
            ...existing,
            progressBlockNumber: data.progressBlockNumber,
            numEventsProcessed: data.totalEventsProcessed,
            blockHeight: data.sourceBlockNumber,
          }->(Utils.magic: InternalTable.Chains.t => Js.Json.t),
        )
      | None => None
      }
    })

    if values->Array.length > 0 {
      try {
        await client->insert({
          table: `${database}.\`${InternalTable.Chains.table.tableName}\``,
          values,
          format: "JSONEachRow",
        })
      } catch {
      | exn =>
        raise(
          Persistence.StorageError({
            message: `Failed to update chain progress in ClickHouse`,
            reason: exn->Utils.prettifyExn,
          }),
        )
      }
    }
  }
}

// Update chain metadata fields
let setChainMetaOrThrow = async (
  client,
  ~database: string,
  ~chainsData: dict<InternalTable.Chains.metaFields>,
) => {
  let chainIds =
    chainsData->Js.Dict.keys->Js.Array2.joinWith(",")

  if chainIds === "" {
    ()
  } else {
    let existingResult: array<InternalTable.Chains.t> = await queryJson(
      client,
      ~query=`SELECT * FROM ${database}.\`${InternalTable.Chains.table.tableName}\` FINAL WHERE id IN (${chainIds})`,
    )

    let values = existingResult->Belt.Array.keepMap(existing => {
      switch chainsData->Js.Dict.get(existing.id->Js.Int.toString) {
      | Some(meta) =>
        Some(
          {
            ...existing,
            firstEventBlockNumber: meta.firstEventBlockNumber,
            latestFetchedBlockNumber: meta.latestFetchedBlockNumber,
            timestampCaughtUpToHeadOrEndblock: meta.timestampCaughtUpToHeadOrEndblock,
            isHyperSync: meta.isHyperSync,
            numBatchesFetched: meta.numBatchesFetched,
          }->(Utils.magic: InternalTable.Chains.t => Js.Json.t),
        )
      | None => None
      }
    })

    if values->Array.length > 0 {
      try {
        await client->insert({
          table: `${database}.\`${InternalTable.Chains.table.tableName}\``,
          values,
          format: "JSONEachRow",
        })
      } catch {
      | exn =>
        raise(
          Persistence.StorageError({
            message: `Failed to update chain metadata in ClickHouse`,
            reason: exn->Utils.prettifyExn,
          }),
        )
      }
    }
  }
}

// Insert raw events
let setRawEventsOrThrow = async (
  client,
  ~database: string,
  ~rawEvents: array<InternalTable.RawEvents.t>,
) => {
  if rawEvents->Array.length === 0 {
    ()
  } else {
    try {
      await client->insert({
        table: `${database}.\`${InternalTable.RawEvents.table.tableName}\``,
        values: rawEvents->(Utils.magic: array<InternalTable.RawEvents.t> => array<Js.Json.t>),
        format: "JSONEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert raw events into ClickHouse`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Load entities by IDs from the view (current state)
let loadByIdsOrThrow = async (
  client,
  ~database: string,
  ~ids: array<string>,
  ~table: Table.table,
  ~rowsSchema: S.t<array<'item>>,
) => {
  if ids->Array.length === 0 {
    []->S.parseOrThrow(rowsSchema)
  } else {
    let idsStr =
      ids->Js.Array2.map(id => `'${id}'`)->Js.Array2.joinWith(",")

    try {
      let rows: array<unknown> = await queryJson(
        client,
        ~query=`SELECT * FROM ${database}.\`${table.tableName}\` WHERE id IN (${idsStr})`,
      )
      rows->(Utils.magic: array<unknown> => array<'item>)->S.parseOrThrow(rowsSchema)
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from ClickHouse by ids`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Load entities by field value
let loadByFieldOrThrow = async (
  client,
  ~database: string,
  ~fieldName: string,
  ~fieldSchema: S.t<'value>,
  ~fieldValue: 'value,
  ~operator: Persistence.operator,
  ~table: Table.table,
  ~rowsSchema: S.t<array<'item>>,
) => {
  let serializedValue = try fieldValue->S.reverseConvertToJsonOrThrow(fieldSchema) catch {
  | exn =>
    raise(
      Persistence.StorageError({
        message: `Failed loading "${table.tableName}" from ClickHouse by field "${fieldName}". Couldn't serialize provided value.`,
        reason: exn,
      }),
    )
  }
  let operatorStr = (operator :> string)

  // Format the value for ClickHouse query
  let valueStr = switch Js.typeof(serializedValue->(Utils.magic: Js.Json.t => unknown)) {
  | "string" => `'${serializedValue->(Utils.magic: Js.Json.t => string)}'`
  | "number" => serializedValue->(Utils.magic: Js.Json.t => float)->Belt.Float.toString
  | _ => Js.Json.stringify(serializedValue)
  }

  try {
    let rows: array<unknown> = await queryJson(
      client,
      ~query=`SELECT * FROM ${database}.\`${table.tableName}\` WHERE \`${fieldName}\` ${operatorStr} ${valueStr}`,
    )
    rows->(Utils.magic: array<unknown> => array<'item>)->S.parseOrThrow(rowsSchema)
  } catch {
  | Persistence.StorageError(_) as exn => raise(exn)
  | exn =>
    raise(
      Persistence.StorageError({
        message: `Failed loading "${table.tableName}" from ClickHouse by field "${fieldName}"`,
        reason: exn->Utils.prettifyExn,
      }),
    )
  }
}

// Insert items into a table (generic set)
let setItemsOrThrow = async (
  client,
  ~database: string,
  ~items: array<'item>,
  ~table: Table.table,
  ~itemSchema: S.t<'item>,
) => {
  if items->Array.length === 0 {
    ()
  } else {
    try {
      let values = items->Js.Array2.map(item => {
        item->S.reverseConvertToJsonOrThrow(itemSchema)
      })
      await client->insert({
        table: `${database}.\`${table.tableName}\``,
        values,
        format: "JSONEachRow",
      })
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert items into ClickHouse table "${table.tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Resume ClickHouse sink after reorg by deleting rows with checkpoint IDs higher than target
let resume = async (client, ~database: string, ~checkpointId: float) => {
  try {
    // Try to use the database - will throw if it doesn't exist
    try {
      await client->exec({query: `USE ${database}`})
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn,
        `ClickHouse sink database "${database}" not found. Please run 'envio start -r' to reinitialize the indexer (it'll also drop Postgres database).`,
      )
      Js.Exn.raiseError("ClickHouse resume failed")
    }

    // Get all history tables
    let tablesResult = await client->query({
      query: `SHOW TABLES FROM ${database} LIKE '${EntityHistory.historyTablePrefix}%'`,
    })
    let tables: array<{"name": string}> = await tablesResult->json

    // Delete rows with checkpoint IDs higher than the target for each history table
    await Promise.all(
      tables->Belt.Array.map(table => {
        let tableName = table["name"]
        client->exec({
          query: `ALTER TABLE ${database}.\`${tableName}\` DELETE WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${checkpointId->Belt.Float.toString}`,
        })
      }),
    )->Promise.ignoreValue

    // Delete stale checkpoints
    await client->exec({
      query: `DELETE FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\` WHERE \`${Table.idFieldName}\` > ${checkpointId->Belt.Float.toString}`,
    })
  } catch {
  | Persistence.StorageError(_) as exn => raise(exn)
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume ClickHouse sink")
      Js.Exn.raiseError("ClickHouse resume failed")
    }
  }
}
