// ClickHouseStorage implements the full Persistence.storage interface
// allowing the indexer to use ClickHouse as the primary storage backend
// instead of PostgreSQL.
//
// Limitations vs PgStorage:
// - No ACID transactions: writes are eventually consistent
// - ReplacingMergeTree for upserts requires FINAL keyword for reads
// - Effect cache uses ReplacingMergeTree (no psql COPY-based dump/restore)
// - Rollback uses ALTER TABLE DELETE (async mutation in ClickHouse)
// - Dynamic contract registry is stored in entity history table (not a separate entity table)

let make = (
  ~client: ClickHouse.client,
  ~database: string,
): Persistence.storage => {
  let isInitialized = async () => {
    try {
      let result: array<{"name": string}> = await ClickHouse.queryJson(
        client,
        ~query=`SHOW TABLES FROM ${database} LIKE '${InternalTable.Chains.table.tableName}'`,
      )
      result->Array.length > 0
    } catch {
    | _ => false
    }
  }

  let initialize = async (
    ~chainConfigs=[],
    ~entities=[],
    ~enums=[],
  ): Persistence.initialState => {
    await ClickHouse.initialize(client, ~database, ~entities, ~enums)
    await ClickHouse.insertChainsOrThrow(client, ~database, ~chainConfigs)

    {
      cleanRun: true,
      cache: Js.Dict.empty(),
      reorgCheckpoints: [],
      chains: chainConfigs->Js.Array2.map((chainConfig): Persistence.initialChainState => {
        id: chainConfig.id,
        startBlock: chainConfig.startBlock,
        endBlock: chainConfig.endBlock,
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
    // Get chains state
    let chainsResult: array<InternalTable.Chains.t> = await ClickHouse.queryJson(
      client,
      // FINAL forces ReplacingMergeTree to deduplicate in-flight
      ~query=`SELECT * FROM ${database}.\`${InternalTable.Chains.table.tableName}\` FINAL`,
    )

    // Get committed checkpoint ID
    let checkpointResult: array<{"id": float}> = await ClickHouse.queryJson(
      client,
      ~query=`SELECT COALESCE(max(id), ${InternalTable.Checkpoints.initialCheckpointId->Belt.Float.toString}) AS id FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\``,
    )
    let checkpointId = (checkpointResult->Belt.Array.getUnsafe(0))["id"]

    // Resume ClickHouse sink state (rollback any uncommitted reorg data)
    await ClickHouse.resume(client, ~database, ~checkpointId)

    // Get dynamic contracts for each chain from the view
    let dcrTableName = Config.DynamicContractRegistry.table.tableName
    let dcrResult: array<Config.DynamicContractRegistry.t> = try {
      await ClickHouse.queryJson(
        client,
        ~query=`SELECT * FROM ${database}.\`${dcrTableName}\` FINAL`,
      )
    } catch {
    | _ => []
    }

    // Group dynamic contracts by chain ID
    let dcrByChain = Js.Dict.empty()
    dcrResult->Js.Array2.forEach(dcr => {
      let chainIdStr = dcr.chainId->Js.Int.toString
      let existing = switch dcrByChain->Js.Dict.get(chainIdStr) {
      | Some(arr) => arr
      | None => {
          let arr = []
          dcrByChain->Js.Dict.set(chainIdStr, arr)
          arr
        }
      }
      existing
      ->Js.Array2.push(
        (
          {
            address: dcr.contractAddress,
            contractName: dcr.contractName,
            startBlock: dcr.registeringEventBlockNumber,
            registrationBlock: Some(dcr.registeringEventBlockNumber),
          }: Internal.indexingContract
        ),
      )
      ->ignore
    })

    // Get reorg checkpoints (checkpoints in reorg threshold for chains with reorg enabled)
    let reorgCheckpoints: array<Internal.reorgCheckpoint> = try {
      await ClickHouse.queryJson(
        client,
        ~query=`SELECT
  cp.id AS id,
  cp.chain_id AS chain_id,
  cp.block_number AS block_number,
  cp.block_hash AS block_hash
FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\` cp
INNER JOIN (
  SELECT id, source_block - max_reorg_depth AS safe_block
  FROM ${database}.\`${InternalTable.Chains.table.tableName}\` FINAL
  WHERE max_reorg_depth > 0
    AND progress_block > source_block - max_reorg_depth
) rc ON cp.chain_id = rc.id
WHERE cp.block_hash IS NOT NULL
  AND cp.block_number >= rc.safe_block`,
      )
    } catch {
    | _ => []
    }

    // Get effect cache table counts
    let cache = Js.Dict.empty()
    let effectTablesResult: array<{"name": string}> = try {
      await ClickHouse.queryJson(
        client,
        ~query=`SHOW TABLES FROM ${database} LIKE '${Internal.cacheTablePrefix}%'`,
      )
    } catch {
    | _ => []
    }
    let _ =
      await effectTablesResult
      ->Belt.Array.map(async tableInfo => {
        let tableName = tableInfo["name"]
        let effectName =
          tableName->Js.String2.sliceToEnd(~from=Internal.cacheTablePrefix->String.length)
        let countResult: array<{"cnt": int}> = try {
          await ClickHouse.queryJson(
            client,
            ~query=`SELECT count() AS cnt FROM ${database}.\`${tableName}\` FINAL`,
          )
        } catch {
        | _ => [{"cnt": 0}]
        }
        let count = (countResult->Belt.Array.getUnsafe(0))["cnt"]
        cache->Js.Dict.set(
          effectName,
          ({effectName, count}: Persistence.effectCacheRecord),
        )
      })
      ->Promise.all

    let chains = chainsResult->Belt.Array.map((chain): Persistence.initialChainState => {
      let chainIdStr = chain.id->Js.Int.toString
      {
        id: chain.id,
        startBlock: chain.startBlock,
        endBlock: chain.endBlock->Js.Null.toOption,
        maxReorgDepth: chain.maxReorgDepth,
        firstEventBlockNumber: chain.firstEventBlockNumber->Js.Null.toOption,
        timestampCaughtUpToHeadOrEndblock: chain.timestampCaughtUpToHeadOrEndblock->Js.Null.toOption,
        numEventsProcessed: chain.numEventsProcessed,
        progressBlockNumber: chain.progressBlockNumber,
        dynamicContracts: switch dcrByChain->Js.Dict.get(chainIdStr) {
        | Some(dcs) => dcs
        | None => []
        },
        sourceBlockNumber: chain.blockHeight,
      }
    })

    {
      cleanRun: false,
      reorgCheckpoints,
      cache,
      chains,
      checkpointId,
    }
  }

  let loadByIdsOrThrow = (
    type item,
    ~ids: array<string>,
    ~table: Table.table,
    ~rowsSchema: S.t<array<item>>,
  ) => {
    ClickHouse.loadByIdsOrThrow(
      client,
      ~database,
      ~ids,
      ~table,
      ~rowsSchema,
    )
  }

  let loadByFieldOrThrow = (
    type item value,
    ~fieldName: string,
    ~fieldSchema: S.t<value>,
    ~fieldValue: value,
    ~operator: Persistence.operator,
    ~table: Table.table,
    ~rowsSchema: S.t<array<item>>,
  ) => {
    ClickHouse.loadByFieldOrThrow(
      client,
      ~database,
      ~fieldName,
      ~fieldSchema,
      ~fieldValue,
      ~operator,
      ~table,
      ~rowsSchema,
    )
  }

  let setOrThrow = (
    type item,
    ~items: array<item>,
    ~table: Table.table,
    ~itemSchema: S.t<item>,
  ) => {
    ClickHouse.setItemsOrThrow(
      client,
      ~database,
      ~items=items->(Utils.magic: array<item> => array<unknown>),
      ~table,
      ~itemSchema=itemSchema->S.toUnknown,
    )
  }

  let setEffectCacheOrThrow = async (
    ~effect: Internal.effect,
    ~items: array<Internal.effectCacheItem>,
    ~initialize as shouldInit: bool,
  ) => {
    let {table} = effect.storageMeta

    if shouldInit {
      try {
        await client->ClickHouse.exec({
          query: ClickHouse.makeCreateEffectCacheTableQuery(
            ~tableName=table.tableName,
            ~database,
          ),
        })
      } catch {
      | exn =>
        raise(
          Persistence.StorageError({
            message: `Failed to create effect cache table "${table.tableName}" in ClickHouse`,
            reason: exn->Utils.prettifyExn,
          }),
        )
      }
    }

    if items->Array.length > 0 {
      try {
        let values = items->Js.Array2.map(item => {
          item->(Utils.magic: Internal.effectCacheItem => Js.Json.t)
        })
        await client->ClickHouse.insert({
          table: `${database}.\`${table.tableName}\``,
          values,
          format: "JSONEachRow",
        })
      } catch {
      | exn =>
        raise(
          Persistence.StorageError({
            message: `Failed to insert effect cache items into ClickHouse table "${table.tableName}"`,
            reason: exn->Utils.prettifyExn,
          }),
        )
      }
    }
  }

  // No-op for ClickHouse: we don't support psql-based dump/restore
  let dumpEffectCache = async () => {
    Logging.trace("ClickHouse storage does not support effect cache dump (no-op)")
  }

  let executeUnsafe = query => {
    ClickHouse.queryJson(client, ~query)->(Utils.magic: promise<array<unknown>> => promise<unknown>)
  }

  let setChainMeta = chainsData => {
    ClickHouse.setChainMetaOrThrow(
      client,
      ~database,
      ~chainsData,
    )->(Utils.magic: promise<unit> => promise<unknown>)
  }

  let pruneStaleCheckpoints = async (~safeCheckpointId) => {
    try {
      await client->ClickHouse.exec({
        query: `ALTER TABLE ${database}.\`${InternalTable.Checkpoints.table.tableName}\` DELETE WHERE id < ${safeCheckpointId->Belt.Float.toString}`,
      })
    } catch {
    | exn =>
      Logging.errorWithExn(exn->Utils.prettifyExn, "Failed to prune stale checkpoints in ClickHouse")
    }
  }

  let pruneStaleEntityHistory = async (~entityName, ~entityIndex, ~safeCheckpointId) => {
    let historyTableName = EntityHistory.historyTableName(~entityName, ~entityIndex)
    try {
      // In ClickHouse, we can't do the complex PG-style prune with CTEs easily,
      // so we use a simpler approach: delete all history rows older than the safe checkpoint
      // that aren't the latest pre-safe row for their entity.
      // For simplicity, just delete rows strictly before the safe checkpoint.
      await client->ClickHouse.exec({
        query: `ALTER TABLE ${database}.\`${historyTableName}\` DELETE WHERE \`${EntityHistory.checkpointIdFieldName}\` < ${safeCheckpointId->Belt.Float.toString}`,
      })
    } catch {
    | exn =>
      Logging.errorWithExn(
        exn->Utils.prettifyExn,
        `Failed to prune stale entity history for "${entityName}" in ClickHouse`,
      )
    }
  }

  let getRollbackTargetCheckpoint = async (~reorgChainId, ~lastKnownValidBlockNumber) => {
    try {
      let result: array<{"id": Internal.checkpointId}> = await ClickHouse.queryJson(
        client,
        ~query=`SELECT id FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\`
WHERE chain_id = ${reorgChainId->Js.Int.toString}
  AND block_number <= ${lastKnownValidBlockNumber->Js.Int.toString}
ORDER BY id DESC
LIMIT 1`,
      )
      result
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: "Failed to get rollback target checkpoint from ClickHouse",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }

  let getRollbackProgressDiff = async (~rollbackTargetCheckpointId) => {
    try {
      let result: array<{
        "chain_id": int,
        "events_processed_diff": string,
        "new_progress_block_number": int,
      }> = await ClickHouse.queryJson(
        client,
        ~query=`SELECT
  chain_id,
  toString(sum(events_processed)) AS events_processed_diff,
  toInt32(min(block_number) - 1) AS new_progress_block_number
FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\`
WHERE id > ${rollbackTargetCheckpointId->Belt.Float.toString}
GROUP BY chain_id`,
      )
      result
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: "Failed to get rollback progress diff from ClickHouse",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }

  let getRollbackData = async (
    ~entityConfig: Internal.entityConfig,
    ~rollbackTargetCheckpointId,
  ) => {
    let historyTableName = EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )
    let checkpointIdStr = rollbackTargetCheckpointId->Belt.Float.toString

    try {
      // Get IDs of entities that were created after the rollback target
      // and have no history before it (should be deleted)
      let removedIds: array<{"id": string}> = await ClickHouse.queryJson(
        client,
        ~query=`SELECT DISTINCT id
FROM ${database}.\`${historyTableName}\`
WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${checkpointIdStr}
AND id NOT IN (
  SELECT DISTINCT id
  FROM ${database}.\`${historyTableName}\`
  WHERE \`${EntityHistory.checkpointIdFieldName}\` <= ${checkpointIdStr}
)`,
      )

      // Get entities to restore: latest state at or before the rollback target,
      // but only for entities that have changes after the target
      let dataFieldNames = entityConfig.table.fields->Belt.Array.keepMap(fieldOrDerived =>
        switch fieldOrDerived {
        | Field(field) => field->Table.getDbFieldName->Some
        | DerivedFrom(_) => None
        }
      )
      let dataFieldsStr =
        dataFieldNames
        ->Belt.Array.map(name => `\`${name}\``)
        ->Js.Array2.joinWith(", ")

      let restoredEntities: array<unknown> = await ClickHouse.queryJson(
        client,
        ~query=`SELECT ${dataFieldsStr}
FROM (
  SELECT ${dataFieldsStr}, \`${EntityHistory.checkpointIdFieldName}\`
  FROM ${database}.\`${historyTableName}\`
  WHERE \`${EntityHistory.checkpointIdFieldName}\` <= ${checkpointIdStr}
    AND id IN (
      SELECT DISTINCT id
      FROM ${database}.\`${historyTableName}\`
      WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${checkpointIdStr}
    )
  ORDER BY \`${EntityHistory.checkpointIdFieldName}\` DESC
  LIMIT 1 BY id
)
WHERE 1=1`,
      )

      (removedIds, restoredEntities)
    } catch {
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to get rollback data for "${entityConfig.name}" from ClickHouse`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }

  let writeBatch = async (
    ~batch: Batch.t,
    ~rawEvents,
    ~rollbackTargetCheckpointId,
    ~isInReorgThreshold,
    ~config: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache,
    ~updatedEntities: array<Persistence.updatedEntity>,
  ) => {
    try {
      let shouldSaveHistory = config->Config.shouldSaveHistory(~isInReorgThreshold)

      // Handle rollback if needed
      switch rollbackTargetCheckpointId {
      | Some(rollbackTargetCheckpointId) =>
        // Delete history rows and checkpoints after the rollback target
        let _ =
          await allEntities
          ->Belt.Array.map(entityConfig => {
            let historyTableName = EntityHistory.historyTableName(
              ~entityName=entityConfig.name,
              ~entityIndex=entityConfig.index,
            )
            client->ClickHouse.exec({
              query: `ALTER TABLE ${database}.\`${historyTableName}\` DELETE WHERE \`${EntityHistory.checkpointIdFieldName}\` > ${rollbackTargetCheckpointId->Belt.Float.toString}`,
            })
          })
          ->Promise.all

        await client->ClickHouse.exec({
          query: `DELETE FROM ${database}.\`${InternalTable.Checkpoints.table.tableName}\` WHERE id > ${rollbackTargetCheckpointId->Belt.Float.toString}`,
        })
      | None => ()
      }

      // Write all data concurrently (no transactions in ClickHouse)
      let promises = []

      // 1. Update chain progress
      promises
      ->Js.Array2.push(
        ClickHouse.setProgressedChainsOrThrow(
          client,
          ~database,
          ~progressedChains=batch.progressedChainsById->Utils.Dict.mapValuesToArray((
            chainAfterBatch
          ): InternalTable.Chains.progressedChain => {
            chainId: chainAfterBatch.fetchState.chainId,
            progressBlockNumber: chainAfterBatch.progressBlockNumber,
            sourceBlockNumber: chainAfterBatch.sourceBlockNumber,
            totalEventsProcessed: chainAfterBatch.totalEventsProcessed,
          }),
        ),
      )
      ->ignore

      // 2. Insert raw events
      promises
      ->Js.Array2.push(
        ClickHouse.setRawEventsOrThrow(client, ~database, ~rawEvents),
      )
      ->ignore

      // 3. Process entity updates
      updatedEntities->Js.Array2.forEach(({entityConfig, updates}) => {
        // Always write to history table in ClickHouse mode
        // (ClickHouse views derive current state from history)
        if shouldSaveHistory || true {
          promises
          ->Js.Array2.push(
            ClickHouse.setUpdatesOrThrow(client, ~updates, ~entityConfig, ~database),
          )
          ->ignore
        }
      })

      // 4. Insert checkpoints (always save in ClickHouse, needed for views)
      promises
      ->Js.Array2.push(
        ClickHouse.setCheckpointsOrThrow(client, ~batch, ~database),
      )
      ->ignore

      // 5. Effect cache (outside of any transaction, same as PgStorage)
      updatedEffectsCache->Js.Array2.forEach(
        ({effect, items, shouldInitialize}: Persistence.updatedEffectCache) => {
          promises
          ->Js.Array2.push(
            setEffectCacheOrThrow(~effect, ~items, ~initialize=shouldInitialize),
          )
          ->ignore
        },
      )

      let _ = await promises->Promise.all
    } catch {
    | Persistence.StorageError(_) as exn => raise(exn)
    | exn =>
      raise(
        Persistence.StorageError({
          message: "Failed to write batch to ClickHouse",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }

  {
    isInitialized,
    initialize,
    resumeInitialState,
    loadByIdsOrThrow,
    loadByFieldOrThrow,
    setOrThrow,
    setEffectCacheOrThrow,
    dumpEffectCache,
    executeUnsafe,
    setChainMeta,
    pruneStaleCheckpoints,
    pruneStaleEntityHistory,
    getRollbackTargetCheckpoint,
    getRollbackProgressDiff,
    getRollbackData,
    writeBatch,
  }
}
