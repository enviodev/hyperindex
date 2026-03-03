// ClickHouse storage implementation for Persistence.storage interface.
// Uses ClickHouse as the primary storage backend instead of PostgreSQL.
// Load methods are not supported — ClickHouse is an append-only analytics store.

let make = (
  ~host: string,
  ~database: string,
  ~username: string,
  ~password: string,
): Persistence.storage => {
  let client = ClickHouse.createClient({
    url: host,
    username,
    password,
  })

  let cache = Utils.WeakMap.make()

  let isInitialized = async () => {
    try {
      let result = await client->ClickHouse.query({
        query: `SELECT 1 FROM system.databases WHERE name = '${database}'`,
        format: "JSONEachRow",
      })
      let rows: array<{"1": int}> = await result->ClickHouse.json
      rows->Array.length > 0
    } catch {
    | _ => false
    }
  }

  let initialize = async (~chainConfigs=[], ~entities=[], ~enums=[]): Persistence.initialState => {
    await ClickHouse.initialize(client, ~database, ~entities, ~enums)

    // Create chains metadata table
    await client->ClickHouse.exec({
      query: `CREATE TABLE IF NOT EXISTS ${database}.\`envio_chains\` (
  \`id\` Int32,
  \`start_block\` Int32,
  \`end_block\` Nullable(Int32),
  \`max_reorg_depth\` Int32,
  \`source_block\` Int32,
  \`progress_block\` Int32,
  \`events_processed\` Int32,
  \`first_event_block\` Nullable(Int32),
  \`buffer_block\` Int32,
  \`ready_at\` Nullable(DateTime64(3, 'UTC')),
  \`_is_hyper_sync\` Bool,
  \`_num_batches_fetched\` Int32,
  \`dynamic_contracts\` String
)
ENGINE = ReplacingMergeTree()
ORDER BY (id)`,
    })

    // Insert initial chain state
    if chainConfigs->Array.length > 0 {
      let values = chainConfigs->Belt.Array.map((chainConfig: Config.chain) => {
        {
          "id": chainConfig.id,
          "start_block": chainConfig.startBlock,
          "end_block": chainConfig.endBlock->Js.Null.fromOption,
          "max_reorg_depth": chainConfig.maxReorgDepth,
          "source_block": 0,
          "progress_block": -1,
          "events_processed": 0,
          "first_event_block": Js.Null.empty,
          "buffer_block": 0,
          "ready_at": Js.Null.empty,
          "_is_hyper_sync": false,
          "_num_batches_fetched": 0,
          "dynamic_contracts": "[]",
        }
      })
      await client->ClickHouse.insert({
        table: `${database}.\`envio_chains\``,
        values,
        format: "JSONEachRow",
      })
    }

    {
      Persistence.cleanRun: true,
      cache: Js.Dict.empty(),
      reorgCheckpoints: [],
      chains: chainConfigs->Js.Array2.map((chainConfig: Config.chain): Persistence.initialChainState => {
        id: chainConfig.id,
        startBlock: chainConfig.startBlock,
        endBlock: chainConfig.endBlock,  // optional field auto-converts to option
        maxReorgDepth: chainConfig.maxReorgDepth,
        progressBlockNumber: -1,
        numEventsProcessed: 0,
        firstEventBlockNumber: None,
        timestampCaughtUpToHeadOrEndblock: None,
        dynamicContracts: [],
        sourceBlockNumber: 0,
      }),
      checkpointId: InternalTable.Checkpoints.initialCheckpointId,
    }
  }

  let resumeInitialState = async (): Persistence.initialState => {
    // Resume ClickHouse sink state
    try {
      await client->ClickHouse.exec({query: `USE ${database}`})
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn,
        `ClickHouse storage database "${database}" not found. Please reinitialize the indexer.`,
      )
      Js.Exn.raiseError("ClickHouse resume failed")
    }

    // Get latest checkpoint
    let checkpointResult = await client->ClickHouse.query({
      query: `SELECT max(\`${(#id: InternalTable.Checkpoints.field :> string)}\`) as id FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\``,
      format: "JSONEachRow",
    })
    let checkpoints: array<{"id": float}> = await checkpointResult->ClickHouse.json
    let checkpointId = switch checkpoints->Belt.Array.get(0) {
    | Some(cp) => cp["id"]
    | None => InternalTable.Checkpoints.initialCheckpointId
    }

    // Get chain states
    let chainsResult = await client->ClickHouse.query({
      query: `SELECT * FROM ${database}.\`envio_chains\` FINAL`,
      format: "JSONEachRow",
    })
    let chains: array<{
      "id": int,
      "start_block": int,
      "end_block": Js.Null.t<int>,
      "max_reorg_depth": int,
      "progress_block": int,
      "events_processed": int,
      "first_event_block": Js.Null.t<int>,
      "ready_at": Js.Null.t<string>,
      "source_block": int,
      "dynamic_contracts": string,
    }> = await chainsResult->ClickHouse.json

    {
      cleanRun: false,
      cache: Js.Dict.empty(),
      reorgCheckpoints: [],
      chains: chains->Belt.Array.map(chain => {
        Persistence.id: chain["id"],
        startBlock: chain["start_block"],
        endBlock: chain["end_block"]->Js.Null.toOption,
        maxReorgDepth: chain["max_reorg_depth"],
        progressBlockNumber: chain["progress_block"],
        numEventsProcessed: chain["events_processed"],
        firstEventBlockNumber: chain["first_event_block"]->Js.Null.toOption,
        timestampCaughtUpToHeadOrEndblock: chain["ready_at"]
          ->Js.Null.toOption
          ->Belt.Option.map(str => Js.Date.fromString(str)),
        dynamicContracts: switch Js.Json.parseExn(chain["dynamic_contracts"]) {
        | exception _ => []
        | json => json->(Utils.magic: Js.Json.t => array<Internal.indexingContract>)
        },
        sourceBlockNumber: chain["source_block"],
      }),
      checkpointId,
    }
  }

  let unsupportedLoadError = (methodName: string) =>
    Js.Exn.raiseError(
      `${methodName} is not supported with ClickHouse storage. ClickHouse is an append-only analytics store and does not support efficient point lookups.`,
    )

  let loadByIdsOrThrow = async (~ids as _, ~table as _, ~rowsSchema as _) => {
    unsupportedLoadError("loadByIdsOrThrow")
  }

  let loadByFieldOrThrow = async (
    ~fieldName as _,
    ~fieldSchema as _,
    ~fieldValue as _,
    ~operator as _,
    ~table as _,
    ~rowsSchema as _,
  ) => {
    unsupportedLoadError("loadByFieldOrThrow")
  }

  let dumpEffectCache = async () => {
    // Effect cache dump is not supported for ClickHouse storage
    ()
  }

  let reset = async () => {
    try {
      await client->ClickHouse.exec({query: `DROP DATABASE IF EXISTS ${database}`})
    } catch {
    | exn => Logging.errorWithExn(exn, "Failed to reset ClickHouse storage")
    }
  }

  let setChainMeta = async (chainsData: dict<InternalTable.Chains.metaFields>) => {
    let entries = chainsData->Js.Dict.entries
    if entries->Array.length > 0 {
      let _ =
        await entries
        ->Belt.Array.map(async ((chainIdStr, meta)) => {
          let chainId = chainIdStr->Belt.Int.fromString->Belt.Option.getWithDefault(0)
          await client->ClickHouse.insert({
            table: `${database}.\`envio_chains\``,
            values: [
              {
                "id": chainId,
                "first_event_block": meta.firstEventBlockNumber,
                "buffer_block": meta.latestFetchedBlockNumber,
                "ready_at": meta.timestampCaughtUpToHeadOrEndblock,
                "_is_hyper_sync": meta.isHyperSync,
                "_num_batches_fetched": meta.numBatchesFetched,
              },
            ],
            format: "JSONEachRow",
          })
        })
        ->Promise.all
    }
    %raw(`undefined`)
  }

  let pruneStaleCheckpoints = async (~safeCheckpointId as _) => {
    // ClickHouse doesn't need pruning - MergeTree handles it
    ()
  }

  let pruneStaleEntityHistory = async (~entityName as _, ~entityIndex as _, ~safeCheckpointId as _) => {
    // ClickHouse doesn't need pruning - MergeTree handles it
    ()
  }

  let getRollbackTargetCheckpoint = async (~reorgChainId, ~lastKnownValidBlockNumber) => {
    let idField = (#id: InternalTable.Checkpoints.field :> string)
    let chainIdField = (#chain_id: InternalTable.Checkpoints.field :> string)
    let blockNumberField = (#block_number: InternalTable.Checkpoints.field :> string)
    let result = await client->ClickHouse.query({
      query: `SELECT \`${idField}\` as id FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\`
WHERE \`${chainIdField}\` = ${reorgChainId->Belt.Int.toString}
  AND \`${blockNumberField}\` <= ${lastKnownValidBlockNumber->Belt.Int.toString}
ORDER BY \`${idField}\` DESC
LIMIT 1`,
      format: "JSONEachRow",
    })
    let rows: array<{"id": Internal.checkpointId}> = await result->ClickHouse.json
    rows
  }

  let getRollbackProgressDiff = async (~rollbackTargetCheckpointId) => {
    let idField = (#id: InternalTable.Checkpoints.field :> string)
    let chainIdField = (#chain_id: InternalTable.Checkpoints.field :> string)
    let eventsProcessedField = (#events_processed: InternalTable.Checkpoints.field :> string)
    let blockNumberField = (#block_number: InternalTable.Checkpoints.field :> string)
    let result = await client->ClickHouse.query({
      query: `SELECT
  \`${chainIdField}\` as chain_id,
  toString(sum(\`${eventsProcessedField}\`)) as events_processed_diff,
  min(\`${blockNumberField}\`) - 1 as new_progress_block_number
FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\`
WHERE \`${idField}\` > ${rollbackTargetCheckpointId->Belt.Float.toString}
GROUP BY \`${chainIdField}\``,
      format: "JSONEachRow",
    })
    let rows: array<{
      "chain_id": int,
      "events_processed_diff": string,
      "new_progress_block_number": int,
    }> = await result->ClickHouse.json
    rows
  }

  let getRollbackData = async (
    ~entityConfig: Internal.entityConfig,
    ~rollbackTargetCheckpointId,
  ) => {
    let historyTableName = EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )
    let checkpointIdField = EntityHistory.checkpointIdFieldName
    let changeField = EntityHistory.changeFieldName
    let idField = Table.idFieldName

    // Get IDs of entities created after rollback target with no prior history
    let removedResult = await client->ClickHouse.query({
      query: `SELECT DISTINCT \`${idField}\` as id
FROM ${database}.\`${historyTableName}\`
WHERE \`${checkpointIdField}\` > ${rollbackTargetCheckpointId->Belt.Float.toString}
AND \`${idField}\` NOT IN (
  SELECT \`${idField}\`
  FROM ${database}.\`${historyTableName}\`
  WHERE \`${checkpointIdField}\` <= ${rollbackTargetCheckpointId->Belt.Float.toString}
)`,
      format: "JSONEachRow",
    })
    let removedIds: array<{"id": string}> = await removedResult->ClickHouse.json

    // Get entity fields for restored entities
    let dataFieldNames = entityConfig.table.fields->Belt.Array.keepMap(fieldOrDerived =>
      switch fieldOrDerived {
      | Field(field) => field->Table.getDbFieldName->Some
      | DerivedFrom(_) => None
      }
    )
    let dataFieldsCommaSeparated =
      dataFieldNames->Belt.Array.map(name => `\`${name}\``)->Js.Array2.joinWith(", ")

    // Get latest state at or before rollback target for entities modified after target
    let restoredResult = await client->ClickHouse.query({
      query: `SELECT ${dataFieldsCommaSeparated}
FROM (
  SELECT ${dataFieldsCommaSeparated}, \`${changeField}\`,
    ROW_NUMBER() OVER (PARTITION BY \`${idField}\` ORDER BY \`${checkpointIdField}\` DESC) as rn
  FROM ${database}.\`${historyTableName}\`
  WHERE \`${checkpointIdField}\` <= ${rollbackTargetCheckpointId->Belt.Float.toString}
    AND \`${idField}\` IN (
      SELECT DISTINCT \`${idField}\`
      FROM ${database}.\`${historyTableName}\`
      WHERE \`${checkpointIdField}\` > ${rollbackTargetCheckpointId->Belt.Float.toString}
    )
)
WHERE rn = 1 AND \`${changeField}\` = '${(EntityHistory.RowAction.SET :> string)}'`,
      format: "JSONEachRow",
    })
    let restoredEntities: array<unknown> = await restoredResult->ClickHouse.json

    (removedIds, restoredEntities)
  }

  let writeBatch = async (
    ~batch: Batch.t,
    ~rawEvents as _,
    ~rollbackTargetCheckpointId,
    ~isInReorgThreshold as _,
    ~config as _,
    ~allEntities,
    ~updatedEffectsCache as _,
    ~updatedEntities,
  ) => {
    // Handle rollback first
    switch rollbackTargetCheckpointId {
    | Some(rollbackTargetCheckpointId) =>
      await ClickHouse.resume(client, ~database, ~checkpointId=rollbackTargetCheckpointId)
    | None => ()
    }

    // Write entity updates to history tables
    await Promise.all(
      updatedEntities->Belt.Array.map(({entityConfig, updates}: Persistence.updatedEntity) => {
        ClickHouse.setUpdatesOrThrow(client, ~cache, ~updates, ~entityConfig, ~database)
      }),
    )->Promise.ignoreValue

    // Write checkpoints
    await ClickHouse.setCheckpointsOrThrow(client, ~batch, ~database)

    // Update chain progress
    let progressedChains = batch.progressedChainsById->Js.Dict.values
    if progressedChains->Array.length > 0 {
      // Write entity current state tables
      // For ClickHouse, entities are stored via history + views, so no separate entity table writes needed.
      // Chain progress is tracked in the chains table
      let chainValues = progressedChains->Belt.Array.map(chainAfterBatch => {
        {
          "id": chainAfterBatch.fetchState.chainId,
          "progress_block": chainAfterBatch.progressBlockNumber,
          "source_block": chainAfterBatch.sourceBlockNumber,
          "events_processed": chainAfterBatch.totalEventsProcessed,
        }
      })
      try {
        await client->ClickHouse.insert({
          table: `${database}.\`envio_chains\``,
          values: chainValues,
          format: "JSONEachRow",
        })
      } catch {
      | exn =>
        Logging.errorWithExn(exn, "Failed to update chain progress in ClickHouse")
      }
    }

    // Write entity data to current state tables (for ClickHouse views to serve)
    // Entity data is written via history tables, so the views handle current state
    ignore(allEntities)
  }

  {
    Persistence.isInitialized: isInitialized,
    initialize,
    resumeInitialState,
    loadByIdsOrThrow,
    loadByFieldOrThrow,
    dumpEffectCache,
    reset,
    setChainMeta,
    pruneStaleCheckpoints,
    pruneStaleEntityHistory,
    getRollbackTargetCheckpoint,
    getRollbackProgressDiff,
    getRollbackData,
    writeBatch,
  }
}
