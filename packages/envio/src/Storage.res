let storeName = (store: StorageClient.store) =>
  switch store {
  | Postgres => "postgres"
  | ClickHouse => "clickhouse"
  }

let postgresName = Postgres->storeName

let postgresOptions = (
  ~pgSchema=Env.Db.publicSchema,
  ~isHasuraEnabled=false,
  ~maxConnections=Env.Db.maxConnections,
  ~isolated=false,
): StorageClient.postgresOptions => {
  {
    host: Env.Db.host,
    port: Env.Db.port,
    user: Env.Db.user,
    password: Env.Db.password,
    database: Env.Db.database,
    ssl: Env.Db.ssl->Sql.sslModeToString,
    maxConnections,
    // What pg_stat_activity, and a pooler's or provider's list of who is
    // connected, shows the indexer's connections as.
    applicationName: `hyperindex/${Utils.EnvioPackage.value.version}`,
    pgSchema,
    // Hasura cannot read a `numeric[]`, so a schema it tracks stores those as
    // `text[]` (issue #788).
    isHasuraEnabled,
    isolated,
  }
}

// One client per storage: the config it was created with decides every table
// and every statement the addon builds. Without one it keeps no entities.
let makeClient = (
  ~logger: Logger.t,
  ~config: option<Config.t>=?,
  ~postgres: StorageClient.postgresOptions,
  ~clickhouse: option<StorageClient.clickHouseOptions>=?,
): StorageClient.t =>
  StorageClient.make(
    {postgres, ?clickhouse},
    ~configJson=?config->Option.map(config => config.envioInfo->JSON.stringify),
    ~logger,
  )

let bounds = ({byChain}: CheckpointSequence.checkpointBoundsByChain): StorageClient.bounds => {
  chainIds: byChain->Frontier.chainIds,
  checkpointIds: byChain->Frontier.chainIds->Array.map(chainId => byChain->Frontier.get(chainId)),
}

let progress = (chain: InternalTable.Chains.progressedChain): StorageClient.progress => {
  chainId: chain.chainId,
  progressBlock: chain.progressBlockNumber,
  progressBlockTime: ?chain.progressBlockTime,
  eventsProcessed: chain.totalEventsProcessed,
  sourceBlock: chain.sourceBlockNumber,
}

let addressColumns = (rows: array<AddressRows.row>): StorageClient.addresses => {
  chainIds: rows->Array.map(row => row.chainId),
  addresses: rows->Array.map(row => row.address),
  contractIds: rows->Array.map(row => row.contractId),
  registrationBlocks: rows->Array.map(row => row.registrationBlock),
}

let toChainConfig = (chainConfig: Config.chain): StorageClient.chainConfig => {
  id: chainConfig.id,
  ecosystem: (chainConfig.ecosystem: Ecosystem.name :> string),
  startBlock: chainConfig->Config.startBlockOrThrow,
  endBlock: ?chainConfig.endBlock,
  maxReorgDepth: chainConfig.maxReorgDepth,
}

// A failed operation crosses as what it was doing, with the store's error as
// its `cause`.
let storageErrorOf = exn =>
  switch exn->JsExn.anyToExnInternal {
  | JsExn(error) =>
    switch (
      error->(Utils.magic: JsExn.t => {"cause": Nullable.t<unknown>})
    )["cause"]->Nullable.toOption {
    | Some(cause) =>
      Persistence.StorageError({
        message: error->JsExn.message->Option.getOr(""),
        reason: cause->JsExn.anyToExnInternal,
      })
    | None => exn
    }
  | _ => exn
  }

let rollbackRowStateSchema: Table.table => S.t<(
  EntityId.t,
  EntityHistory.RowAction.t,
)> = Utils.WeakMap.memoize(table =>
  S.object(s => (
    s.field(Table.idFieldName, table->Table.getIdSchema),
    s.field(EntityHistory.changeFieldName, EntityHistory.RowAction.schema),
  ))
)

// The chain a rollback row belongs to, read from the chain-id column both
// rollback queries select. None for a cross-chain entity, which has no column.
let rollbackChainIdSchema: Table.table => option<S.t<ChainId.t>> = Utils.WeakMap.memoize(table =>
  table
  ->Table.getChainIdField
  ->Option.map(field => S.object(s => s.field(field->Table.getPgDbFieldName, ChainId.schema)))
)

// Both rollback queries must yield ids in the entity's own representation, or
// the two halves of the diff would disagree (Postgres hands back a NUMERIC id
// as a string, not a bigint).
let rollbackRemovedIdSchema: Table.table => S.t<EntityId.t> = Utils.WeakMap.memoize(table =>
  S.object(s => s.field(Table.idFieldName, table->Table.getIdSchema))
)

// A change set is the entity's fields, then each change's checkpoint and 1
// for a change that deletes the entity.
let changeColumns: array<Staging.column> = [
  {name: EntityHistory.checkpointIdFieldName, kind: I64, isNullable: false},
  {name: EntityHistory.changeFieldName, kind: F64, isNullable: false},
]

// Fills a stage the addon lent for `rows`, handing it back once every value
// is in, or abandoning it if one is refused.
let stageOrThrow = (arena, ~columns, ~rows, fill) => {
  let stage = arena->Staging.begin(~rows, ~columns)
  try {
    fill(stage)
    stage->Staging.commit
  } catch {
  | exn =>
    stage->Staging.abort
    throw(exn)
  }
}

// Rows of a fixed layout, each value read off the item by its column's name.
let stageRowsOrThrow = (arena, ~writers, items: array<dict<unknown>>) =>
  arena->stageOrThrow(~columns=writers->StagedRows.columnsOf, ~rows=items->Array.length, stage =>
    items->Array.forEachWithIndex((item, row) =>
      writers->Array.forEachWithIndex(({field}: StagedRows.writer, column) =>
        stage->StagedRows.writeField(~writers, ~column, ~row, item->Dict.getUnsafe(field.name))
      )
    )
  )

// Every change a group made, in order: what a set wrote, or the id a delete
// removed. Each store reads what it keeps off the same rows.
let stageChangesOrThrow = (arena, ~writers, ~changes: array<Change.t<Internal.entity>>) => {
  let fields = writers->Array.length
  arena->stageOrThrow(
    ~columns=writers->StagedRows.columnsOf->Array.concat(changeColumns),
    ~rows=changes->Array.length,
    stage =>
      changes->Array.forEachWithIndex((change, row) => {
        let entityId = change->Change.getEntityId->(Utils.magic: EntityId.t => unknown)
        switch change {
        | Set({entity}) =>
          let values = entity->(Utils.magic: Internal.entity => dict<unknown>)
          writers->Array.forEachWithIndex(({field}: StagedRows.writer, column) =>
            stage->StagedRows.writeField(
              ~writers,
              ~column,
              ~row,
              field.name === Table.idFieldName ? entityId : values->Dict.getUnsafe(field.name),
            )
          )
        | Delete(_) =>
          writers->Array.forEachWithIndex(({field}: StagedRows.writer, column) =>
            if field.name === Table.idFieldName {
              stage->StagedRows.writeField(~writers, ~column, ~row, entityId)
            } else {
              stage->Staging.writeDeletedValue(~column, ~row, %raw(`undefined`))
            }
          )
        }
        stage->Staging.writeValue(
          ~column=fields,
          ~row,
          change->Change.getCheckpointId->(Utils.magic: bigint => unknown),
        )
        stage->Staging.writeValue(
          ~column=fields + 1,
          ~row,
          (
            switch change {
            | Set(_) => 0.
            | Delete(_) => 1.
            }
          )->(Utils.magic: float => unknown),
        )
      }),
  )
}

let make = (
  ~client: StorageClient.t,
  ~logger: Logger.t,
  // Where the effect cache is dumped to and uploaded from.
  ~cacheDir: option<NodeJs.Path.t>=?,
  // Decides how wide an address key is, both when the config's addresses are
  // encoded at initialize and when stored rows are grouped on resume.
  ~ecosystem: Ecosystem.name,
  ~onInitialize=?,
): Persistence.storage => {
  let cacheDirPath = switch cacheDir {
  | Some(cacheDir) => cacheDir
  | None =>
    NodeJs.Path.resolve([
      // Right at the project root
      ".envio",
      "cache",
    ])
  }

  let layouts = client->StorageClient.layouts
  let entityIndexByName = Dict.make()
  layouts.entities->Array.forEachWithIndex((layout, index) =>
    entityIndexByName->Dict.set(layout.name, index)
  )
  let entityIndex = (table: Table.table) =>
    switch entityIndexByName->Utils.Dict.dangerouslyGetNonOption(table.tableName) {
    | Some(index) => index
    | None => JsError.throwWithMessage(`The storage has no entity "${table.tableName}".`)
    }
  let entityWriters = layouts.entities->Array.map(layout => layout.fields->StagedRows.writersOf)
  let rawEventWriters = layouts.rawEvents->StagedRows.writersOf
  let effectCacheWriters = layouts.effectCache->StagedRows.writersOf

  let holding = () => client->StorageClient.holding

  // Scans .envio/cache into a list of (cache table, absolute TSV path). Flat
  // `<name>.tsv` files map to cross-chain caches; a numeric subdirectory
  // `<chainId>/<name>.tsv` maps to a chain-scoped cache. Exactly one directory
  // level is supported. A non-numeric directory that contains TSVs is rejected.
  // Returns [] when .envio/cache doesn't exist.
  let scanCacheDir = async () => {
    let topEntries = try {
      await NodeJs.Fs.Promises.readdir(cacheDirPath)
    } catch {
    | _ => []
    }
    let result = []
    let _ = await topEntries
    ->Array.map(async entry => {
      let entryPath = NodeJs.Path.join(cacheDirPath, entry)
      let isDir = (await NodeJs.Fs.Promises.stat(entryPath))->NodeJs.Fs.Promises.statsIsDirectory
      if isDir {
        let subEntries = await NodeJs.Fs.Promises.readdir(entryPath)
        let tsvs = subEntries->Array.filter(sub => sub->String.endsWith(".tsv"))
        switch Internal.EffectCache.parseChainId(entry) {
        | Some(chainId) =>
          tsvs->Array.forEach(sub => {
            let effectName = sub->String.slice(~start=0, ~end=-4)
            result
            ->Array.push((
              Internal.EffectCache.toTableName(~effectName, ~scope=Chain(chainId)),
              NodeJs.Path.join(entryPath, sub)->NodeJs.Path.toString,
            ))
            ->ignore
          })
        | None =>
          if tsvs->Utils.Array.notEmpty {
            JsError.throwWithMessage(
              `Invalid effect cache directory ".envio/cache/${entry}". Chain cache directories must be named by a numeric chain id (e.g. "1"). Found cache files: ${tsvs->Array.joinUnsafe(
                  ", ",
                )}.`,
            )
          }
        }
      } else if entry->String.endsWith(".tsv") {
        let effectName = entry->String.slice(~start=0, ~end=-4)
        result
        ->Array.push((
          Internal.EffectCache.toTableName(~effectName, ~scope=CrossChain),
          entryPath->NodeJs.Path.toString,
        ))
        ->ignore
      }
    })
    ->Promise.all
    result
  }

  let restoreEffectCache = async (~withUpload) => {
    if withUpload {
      switch await scanCacheDir() {
      | [] => logger->Logger.info("No saved effect cache to load from .envio/cache.")
      | entries =>
        try {
          await client->StorageClient.uploadEffectCache(
            entries->Array.map(((table, path)): StorageClient.cacheUpload => {table, path}),
          )
          logger->Logger.info("Successfully uploaded cache.")
        } catch {
        | exn => logger->Logger.errorWithExn("Failed to upload cache, continuing without it.", exn)
        }
      }
    }

    let cache = Dict.make()
    (await client->StorageClient.effectCacheTables)->Array.forEach(({tableName, rows}) => {
      switch Internal.EffectCache.fromTableName(tableName) {
      | Some((effectName, scope)) =>
        cache->Dict.set(
          tableName,
          ({effectName, scope, tableName, count: rows}: Persistence.effectCacheRecord),
        )
      | None => ()
      }
    })
    cache
  }

  let initialize = async (
    ~chainConfigs=[],
    ~contractMapping,
    ~envioInfo,
  ): Persistence.initialState => {
    let rowsByChain =
      chainConfigs->Array.map(chainConfig =>
        chainConfig->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      )

    await client->StorageClient.initialize({
      chains: chainConfigs->Array.map(toChainConfig),
      envioInfo: envioInfo->JSON.stringify,
      contractNames: contractMapping->ContractMapping.names,
      addresses: rowsByChain->Array.flat->addressColumns,
    })

    let cache = await restoreEffectCache(~withUpload=true)

    // Integration with other tools like Hasura
    switch onInitialize {
    | Some(onInitialize) => await onInitialize()
    | None => ()
    }

    {
      cleanRun: true,
      cache,
      reorgCheckpoints: [],
      contractMapping,
      chains: chainConfigs->Array.mapWithIndex((
        chainConfig,
        idx,
      ): Persistence.initialChainState => {
        id: chainConfig.id,
        startBlock: chainConfig->Config.startBlockOrThrow,
        endBlock: chainConfig.endBlock,
        maxReorgDepth: chainConfig.maxReorgDepth,
        progressBlockNumber: -1,
        numEventsProcessed: 0.,
        firstEventBlockNumber: None,
        timestampCaughtUpToHeadOrEndblock: None,
        addressRows: rowsByChain->Array.getUnsafe(idx)->AddressRows.seedRowsOf,
        progressBlockTime: None,
        sourceBlockNumber: 0,
      }),
      checkpointFrontier: Frontier.empty(),
    }
  }

  let loadOrThrow = async (~filter: EntityFilter.t, ~table: Table.table) => {
    let conditions = LoadFilter.make(~filter, ~table, ~column=field => field.pgDbFieldName)
    let loading = switch Internal.EffectCache.fromTableName(table.tableName) {
    | Some(_) => client->StorageClient.loadEffectCache(~table=table.tableName, ~conditions)
    | None => client->StorageClient.loadWhere(~entity=table->entityIndex, ~conditions)
    }
    switch await loading {
    | exception exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by ${conditions->LoadFilter.describe}.`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(table->Table.pgEntityRowsSchema) catch {
      | exn =>
        throw(
          Persistence.StorageError({
            message: `Failed to parse "${table.tableName}" loaded from storage by ${conditions->LoadFilter.describe}.`,
            reason: exn,
          }),
        )
      }
    }
  }

  // The physical columns a filter reads, deduped and in first-seen order.
  // Unknown field names are left to `loadOrThrow`, which reports them properly.
  let filterColumns = (~table: Table.table, ~filters: array<EntityFilter.t>) => {
    let queryFields = table->Table.queryFields
    let columns = []
    let seen = Utils.Set.make()
    filters->Array.forEach(filter =>
      filter
      ->EntityFilter.entries
      ->Utils.Dict.forEachWithKey((_, fieldName) =>
        switch queryFields->Utils.Dict.dangerouslyGetNonOption(fieldName) {
        | Some({pgDbFieldName}) =>
          if !(seen->Utils.Set.has(pgDbFieldName)) {
            seen->Utils.Set.add(pgDbFieldName)->ignore
            columns->Array.push(pgDbFieldName)->ignore
          }
        | None => ()
        }
      )
    )
    columns
  }

  let ensureQueryIndexes = async (
    ~entityConfig: Internal.entityConfig,
    ~scope: Internal.chainScope,
    ~filters: array<EntityFilter.t>,
  ) =>
    switch client->StorageClient.ensureQueryIndexes(
      ~entity=entityConfig.index,
      ~chainId=scope->Internal.chainScopeChainId->Null.fromOption,
      ~columns=filterColumns(~table=entityConfig.table, ~filters),
    ) {
    | Value(building) => await building
    | Null => ()
    }

  // Runs on a resumed indexer that is already ready, so handlers may be issuing
  // getWhere queries alongside it. Nothing here writes `ready_at` — the chains
  // already carry theirs.
  let ensureSchemaIndexes = (~chainIds) => client->StorageClient.ensureSchemaIndexes(chainIds)

  let finalizeBackfill = (~chainIds, ~readyAt: Date.t) =>
    client->StorageClient.finalizeBackfill(chainIds, readyAt->Date.getTime)

  let dumpEffectCache = async () => {
    try {
      let tables =
        (await client->StorageClient.effectCacheTables)->Array.filter(({rows}) => rows > 0)
      if tables->Utils.Array.notEmpty {
        logger->Logger.info(
          `Dumping cache: ${tables
            ->Array.map(({tableName, rows}) => tableName ++ " (" ++ rows->Int.toString ++ " rows)")
            ->Array.joinUnsafe(", ")}`,
        )
        await client->StorageClient.dumpEffectCache(
          tables->Array.filterMap(({tableName}) =>
            Internal.EffectCache.fromTableName(tableName)->Option.map(((
              effectName,
              scope,
            )): StorageClient.cacheDump => {
              tableName,
              // Chain-scoped caches dump into a directory of their chain's.
              path: NodeJs.Path.join(
                cacheDirPath,
                Internal.EffectCache.toCachePath(~effectName, ~scope),
              )->NodeJs.Path.toString,
            })
          ),
        )
        logger->Logger.info(`Successfully dumped cache to ${cacheDirPath->NodeJs.Path.toString}`)
      }
    } catch {
    | exn => logger->Logger.errorWithExn(`Failed to dump cache.`, exn)
    }
  }

  let readAddressRows = (result): array<AddressRows.row> =>
    client
    ->StorageClient.read(result)
    ->(Utils.magic: array<dict<unknown>> => array<AddressRows.row>)

  let readStoredConfig = async (): ResumePlan.stored => {
    let stored = await client->StorageClient.readStoredConfig
    let configAddresses = stored.configAddresses->readAddressRows
    // Both are written in one transaction. A missing mapping means an older
    // envio wrote this schema, so the record is unreadable rather than decoded
    // against ids nothing assigned.
    switch (stored.envioInfo, stored.contractNames) {
    | (Some(envioInfo), Some(contractNames)) =>
      let configAddressesByChain = Dict.make()
      configAddresses->Array.forEach(row =>
        configAddressesByChain->Utils.Dict.push(
          row.chainId->ChainId.normalizeOrThrow->ChainId.toString,
          row,
        )
      )
      {
        envioInfo: Some(envioInfo->JSON.parseOrThrow),
        chains: stored.chains->Array.map((chain): ResumePlan.storedChain => {
          let id = chain.id->ChainId.normalizeOrThrow
          {
            id,
            ecosystem: chain.ecosystem,
            startBlock: chain.startBlock,
            endBlock: chain.endBlock,
            maxReorgDepth: chain.maxReorgDepth,
            configAddresses: configAddressesByChain
            ->Utils.Dict.dangerouslyGetNonOption(id->ChainId.toString)
            ->Option.getOr([]),
          }
        }),
        contractMapping: ContractMapping.fromStoredNames(contractNames),
      }
    | _ => {envioInfo: None, chains: [], contractMapping: ContractMapping.empty}
    }
  }

  let addChain = (~chainConfig: Config.chain, ~contractMapping) =>
    client->StorageClient.addChain({
      chain: chainConfig->toChainConfig,
      addresses: chainConfig
      ->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      ->addressColumns,
    })

  let resumeInitialState = async (~chainIds, ~contractMapping): Persistence.initialState => {
    let (cache, resumed) = await Promise.all2((
      restoreEffectCache(~withUpload=false),
      client->StorageClient.resume(chainIds),
    ))
    let addressRowsByChainId = resumed.addresses->readAddressRows->AddressRows.group
    let stored =
      resumed.chains
      ->Array.map(chain => (chain.id->ChainId.normalizeOrThrow, chain))
      ->Array.filter(((id, _)) => chainIds->Array.includes(id))
    let chains = stored->Array.map(((id, chain)): Persistence.initialChainState => {
      id,
      startBlock: chain.startBlock,
      endBlock: chain.endBlock,
      maxReorgDepth: chain.maxReorgDepth,
      firstEventBlockNumber: chain.firstEventBlock,
      timestampCaughtUpToHeadOrEndblock: chain.readyAt->Option.map(Date.fromTime),
      numEventsProcessed: chain.eventsProcessed,
      progressBlockNumber: chain.progressBlock,
      progressBlockTime: chain.progressBlockTime->Option.map(Float.toInt),
      addressRows: addressRowsByChainId
      ->Utils.Dict.dangerouslyGetNonOption(id->ChainId.toString)
      ->Option.getOr(AddressRows.emptySeedRows()),
      sourceBlockNumber: chain.sourceBlock,
    })
    let checkpointFrontier = Frontier.fromEntries(
      stored->Array.map(((id, chain)) => (id, chain.checkpointId)),
    )
    let reorgCheckpoints = resumed.reorgCheckpoints->Array.map((
      checkpoint
    ): Internal.reorgCheckpoint => {
      checkpointId: checkpoint.id,
      chainId: checkpoint.chainId->ChainId.normalizeOrThrow,
      blockNumber: checkpoint.blockNumber,
      blockHash: checkpoint.blockHash,
    })

    {
      cleanRun: false,
      reorgCheckpoints,
      cache,
      chains,
      checkpointFrontier,
      contractMapping,
    }
  }

  let reset = () => client->StorageClient.reset

  let chainMeta = (chainsData: dict<InternalTable.Chains.metaFields>) =>
    chainsData
    ->Dict.toArray
    ->Array.map(((chainId, meta)): StorageClient.chainMeta => {
      chainId: chainId->ChainId.normalizeOrThrow,
      firstEventBlock: ?(meta.firstEventBlockNumber->Null.toOption),
      bufferBlock: meta.latestFetchedBlockNumber,
      readyAt: ?(meta.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime)),
      isHyperSync: meta.isHyperSync,
    })

  let setChainMeta = chainsData =>
    client
    ->StorageClient.setChainMeta(chainsData->chainMeta)
    ->Promise.thenResolve(_ => %raw(`undefined`))

  let pruneStaleCheckpoints = (~safeCheckpoints) =>
    client->StorageClient.pruneCheckpoints(safeCheckpoints->bounds)

  let pruneStaleEntityHistory = (~entityConfig: Internal.entityConfig, ~safeCheckpoints) =>
    client->StorageClient.pruneHistory(entityConfig.index, safeCheckpoints->bounds)

  let getRollbackTargetCheckpoint = async (~reorgChainId, ~lastKnownValidBlockNumber) =>
    (
      await client->StorageClient.rollbackTargetCheckpoint(reorgChainId, lastKnownValidBlockNumber)
    )->Nullable.toOption

  let getRollbackProgressDiff = async (~floors: RollbackFloors.t) =>
    (
      await client->StorageClient.rollbackProgressDiff(floors.checkpointBounds->bounds)
    )->Array.map(diff =>
      {
        "chain_id": diff.chainId->ChainId.normalizeOrThrow,
        "events_processed_diff": diff.eventsProcessed,
        "new_progress_block_number": diff.progressBlock,
      }
    )

  let getRollbackData = async (~entityConfig: Internal.entityConfig, ~floors: RollbackFloors.t) => {
    let {removed, restored} = await client->StorageClient.rollbackData(
      entityConfig.index,
      floors.checkpointBounds->bounds,
    )
    let removedIdRows = try client->StorageClient.read(removed) catch {
    | exn =>
      client->StorageClient.releaseResult(restored.handle, [])
      throw(exn)
    }
    let rollbackRows = client->StorageClient.read(restored)

    let chainIdSchema = rollbackChainIdSchema(entityConfig.table)
    let scopeOf = row =>
      switch chainIdSchema {
      | None => Internal.CrossChain
      | Some(schema) => Internal.Chain(row->S.parseOrThrow(schema))
      }
    let removals = removedIdRows->Array.map((row): Persistence.rollbackRemoval => {
      entityId: row->S.parseOrThrow(rollbackRemovedIdSchema(entityConfig.table)),
      scope: scopeOf(row),
    })
    let restoredEntitiesResult = []
    rollbackRows->Array.forEach(row => {
      let (entityId, action) = row->S.parseOrThrow(rollbackRowStateSchema(entityConfig.table))
      switch action {
      | SET => restoredEntitiesResult->Array.push(row)->ignore
      | DELETE => removals->Array.push({entityId, scope: scopeOf(row)})->ignore
      }
    })

    (
      removals,
      restoredEntitiesResult
      ->(Utils.magic: array<dict<unknown>> => array<unknown>)
      ->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema)
      ->(Utils.magic: array<unknown> => array<Internal.entity>),
    )
  }

  let stageRows = (~table, ~writers, items) =>
    client
    ->StorageClient.arena((~rows) => client->StorageClient.beginRows(~table, ~rows))
    ->stageRowsOrThrow(~writers, items)

  let stageChanges = ({entityConfig, changes}: Persistence.updatedEntity) =>
    client
    ->StorageClient.arena((~rows) =>
      client->StorageClient.beginChanges(~entity=entityConfig.index, ~rows)
    )
    ->stageChangesOrThrow(~writers=entityWriters->Array.getUnsafe(entityConfig.index), ~changes)

  // A value a store can't take is reported as the store's own refusal: the
  // store of record's, for an entity it keeps.
  let changesErrorOf = (entityConfig: Internal.entityConfig, exn) => Persistence.StorageError({
    message: entityConfig.storage.postgres
      ? `Failed to insert items into table "${entityConfig.table.tableName}"`
      : `Failed to convert items for ClickHouse table "${EntityHistory.historyTableName(
            ~entityName=entityConfig.name,
            ~entityIndex=entityConfig.index,
          )}"`,
    reason: exn->Utils.prettifyExn,
  })

  let writeBatch = async (
    ~batch: Batch.t,
    ~rollback: option<Persistence.rollback>,
    ~config: Config.t,
    ~updatedEffectsCache: array<Persistence.updatedEffectCache>,
    ~updatedEntities: array<Persistence.updatedEntity>,
    ~registeredAddresses: array<AddressRows.staged>,
    ~chainMetaData,
    ~onWrite,
  ) => {
    let (frontierChainIds, frontierCheckpointIds) = {
      let frontier = Persistence.writtenFrontier(~batch, ~rollback)
      let chainIds = frontier->Frontier.chainIds
      (chainIds, chainIds->Array.map(chainId => frontier->Frontier.get(chainId)))
    }

    // A single on-chain log fans out to one item per matching registration;
    // `raw_events` records the log itself, so it is deduped by its coordinate
    // (chain, block, logIndex) to keep one row per log.
    let rawEvents = if config.enableRawEvents {
      let seenLogCoordinates = Utils.Set.make()
      batch.items->Array.filterMap(item =>
        switch item {
        | Internal.Event(_) =>
          let eventItem = item->Internal.castUnsafeEventItem
          let coordinate = `${eventItem.chainId->ChainId.toString}-${eventItem.blockNumber->Int.toString}-${eventItem.logIndex->Int.toString}`
          if seenLogCoordinates->Utils.Set.has(coordinate) {
            None
          } else {
            seenLogCoordinates->Utils.Set.add(coordinate)->ignore
            Some(config.ecosystem.toRawEvent(eventItem))
          }
        | Internal.Block(_) => None
        }
      )
    } else {
      []
    }

    let handles = []
    let staged = handle => {
      handles->Array.push(handle)
      handle
    }
    let stagingStarted = Performance.now()
    let input: StorageClient.batch = try {
      rollback: ?(
        rollback->Option.map(({
          floors,
          rolledBackAddresses,
          progressedChains,
          diffCheckpoints,
        }): StorageClient.rollbackWrite => {
          bounds: floors.checkpointBounds->bounds,
          progress: progressedChains->Array.map(progress),
          removedAddresses: {
            chainIds: rolledBackAddresses->Array.map(key => key.chainId),
            addresses: rolledBackAddresses->Array.map(key => key.address),
            contractIds: rolledBackAddresses->Array.map(key => key.contractId),
          },
          diffCheckpoints: diffCheckpoints->Array.map((diff): StorageClient.diffCheckpoint => {
            chainId: diff.chainId,
            checkpointId: diff.checkpointId,
            blockNumber: diff.blockNumber,
          }),
        })
      ),
      progress: batch.progressedChainsById->Utils.Dict.mapValuesToArray(chainAfterBatch =>
        progress({
          chainId: chainAfterBatch.fetchState.chainId,
          progressBlockNumber: chainAfterBatch.progressBlockNumber,
          progressBlockTime: chainAfterBatch.progressBlockTime,
          sourceBlockNumber: chainAfterBatch.sourceBlockNumber,
          totalEventsProcessed: chainAfterBatch.totalEventsProcessed,
        })
      ),
      rawEvents: ?(
        rawEvents->Utils.Array.notEmpty
          ? Some(
              try stageRows(
                ~table=RawEvents,
                ~writers=rawEventWriters,
                rawEvents->(Utils.magic: array<Internal.rawEvent> => array<dict<unknown>>),
              )->staged catch {
              | exn =>
                throw(
                  Persistence.StorageError({
                    message: `Failed to insert items into table "${InternalTable.RawEvents.table.tableName}"`,
                    reason: exn->Utils.prettifyExn,
                  }),
                )
              },
            )
          : None
      ),
      changes: updatedEntities->Array.filterMap(update =>
        switch update.changes {
        | [] => None
        | _ =>
          let handle = try update->stageChanges->staged catch {
          | exn => throw(changesErrorOf(update.entityConfig, exn))
          }
          Some(
            (
              {
                entity: update.entityConfig.index,
                chainId: ?(update.scope->Internal.chainScopeChainId),
                keepsHistory: update.shouldSaveHistory,
                changes: handle,
              }: StorageClient.changes
            ),
          )
        }
      ),
      chainMeta: chainMetaData->Option.mapOr([], chainMeta),
      addresses: registeredAddresses->Array.map(staged => staged.row)->addressColumns,
      frontier: {chainIds: frontierChainIds, checkpointIds: frontierCheckpointIds},
      // A checkpoint anchors the history its chain keeps, which the batch
      // decides chain by chain.
      checkpoints: {
        ids: batch.checkpointIds,
        chainIds: batch.checkpointChainIds,
        blockNumbers: batch.checkpointBlockNumbers,
        blockHashes: batch.checkpointBlockHashes,
        eventsProcessed: batch.checkpointEventsProcessed,
        keepsHistory: batch.checkpointChainIds->Array.map(chainId =>
          batch.history->HistoryPolicy.forChain(chainId)
        ),
      },
      // Never rolled back, so written outside the batch's commit.
      effectCaches: updatedEffectsCache->Array.map(({
        table,
        itemSchema,
        items,
        shouldInitialize,
      }): StorageClient.effectCacheWrite => {
        table: table.tableName,
        create: shouldInitialize,
        rows: try stageRows(
          ~table=EffectCache,
          ~writers=effectCacheWriters,
          items->Array.map(item =>
            item
            ->S.reverseConvertOrThrow(itemSchema)
            ->(Utils.magic: unknown => dict<unknown>)
          ),
        )->staged catch {
        | S.Raised(_) as exn =>
          throw(
            Persistence.StorageError({
              message: `Failed to convert items for table "${table.tableName}"`,
              reason: exn,
            }),
          )
        | exn =>
          throw(
            Persistence.StorageError({
              message: `Failed to insert items into table "${table.tableName}"`,
              reason: exn->Utils.prettifyExn,
            }),
          )
        },
      }),
    } catch {
    | exn =>
      client->StorageClient.discardStaged(handles)
      throw(exn)
    }
    let stagingSeconds = stagingStarted->Performance.secondsSince

    let timings = try await client->StorageClient.writeBatch(input) catch {
    | exn =>
      // Batches the addon never took, because it refused the call itself.
      client->StorageClient.discardStaged(handles)
      throw(exn->storageErrorOf)
    }
    // One staging feeds every store, so its time is the store of record's.
    timings->Array.forEach(({store, seconds}) =>
      onWrite(
        ~storage=store->storeName,
        ~timeSeconds=store === Postgres ? seconds +. stagingSeconds : seconds,
      )
    )
  }

  let close = () => client->StorageClient.close

  {
    name: postgresName,
    entityStoreName: entityConfig =>
      (layouts.entities->Array.getUnsafe(entityConfig.index)).home->Option.mapOr(
        postgresName,
        storeName,
      ),
    holding,
    initialize,
    readStoredConfig,
    addChain,
    resumeInitialState,
    loadOrThrow,
    ensureQueryIndexes,
    ensureSchemaIndexes,
    finalizeBackfill,
    dumpEffectCache,
    reset,
    setChainMeta,
    pruneStaleCheckpoints,
    pruneStaleEntityHistory,
    getRollbackTargetCheckpoint,
    getRollbackProgressDiff,
    getRollbackData,
    writeBatch,
    close,
  }
}

let clientFromEnv = (
  ~config: Config.t,
  ~logger,
  ~pgSchema=Env.Db.publicSchema,
  ~isHasuraEnabled,
  ~maxConnections=?,
) =>
  makeClient(
    ~logger,
    ~config,
    ~postgres=postgresOptions(
      ~pgSchema,
      ~isHasuraEnabled,
      ~maxConnections?,
      ~isolated=config.isolated,
    ),
    ~clickhouse=?config.storage.clickhouse ? Some(ClickHouse.optionsFromEnvOrThrow()) : None,
  )

let makeStorageFromEnv = (
  ~config: Config.t,
  ~logger,
  ~pgSchema=Env.Db.publicSchema,
  ~isHasuraEnabled=Env.Hasura.enabled,
  ~maxConnections=?,
  ~cacheDir=?,
) => {
  make(
    ~client=clientFromEnv(~config, ~logger, ~pgSchema, ~isHasuraEnabled, ~maxConnections?),
    ~logger,
    ~cacheDir?,
    ~ecosystem=config.ecosystem.name,
    ~onInitialize=?isHasuraEnabled
      ? Some(
          () =>
            Hasura.trackDatabase(
              ~logger,
              ~endpoint=Env.Hasura.graphqlEndpoint,
              ~auth={role: Env.Hasura.role, secret: Env.Hasura.secret},
              ~pgSchema,
              ~userEntities=config->Config.getPgUserEntities,
              ~responseLimit=Env.Hasura.responseLimit,
              ~schema=Schema.make(config.userEntities->Array.map(e => e.table)),
              ~aggregateEntities=Env.Hasura.aggregateEntities,
            )->Promise.catch(err => {
              logger->Logger.errorWithExn(`Error tracking tables`, err)->Promise.resolve
            }),
        )
      : None,
  )
}

let makePersistenceFromConfig = (
  ~config: Config.t,
  ~logger,
  ~storage=makeStorageFromEnv(~config, ~logger),
) => {
  Persistence.make(~userEntities=config.userEntities, ~allEnums=config.allEnums, ~storage)
}
