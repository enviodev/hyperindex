// ClickHouse as the indexer's only storage. Entity history is written through
// the same RowBinary path the ClickHouse sink uses; materialized views turn it
// into one `ReplacingMergeTree` table per entity holding its current state,
// which handlers and APIs read with `FINAL`. ClickHouse has no transactions,
// so a batch lands in a fixed order — history (and through it the current
// tables), checkpoints, addresses, then each chain's row in
// `envio_chain_state` — and the chain row is what commits it: a resume trims
// and repairs everything above the checkpoint that row names.

let storageName = "clickhouse"

let chainStateTable = "envio_chain_state"
let addressesTable = "envio_addresses"
let infoTable = "envio_info"

type chainRow = {
  id: ChainId.t,
  ecosystem: string,
  @as("start_block") startBlock: int,
  @as("end_block") endBlock: Null.t<int>,
  @as("max_reorg_depth") maxReorgDepth: int,
  @as("source_block") mutable sourceBlock: int,
  @as("first_event_block") mutable firstEventBlock: Null.t<int>,
  @as("buffer_block") mutable bufferBlock: int,
  @as("progress_block") mutable progressBlock: int,
  @as("progress_block_time") mutable progressBlockTime: Null.t<int>,
  @as("ready_at") mutable readyAt: Null.t<float>,
  @as("events_processed") mutable eventsProcessed: float,
  @as("_is_hyper_sync") mutable isHyperSync: bool,
  // Decimal digits: a UInt64 outruns what a JS number holds exactly.
  @as("checkpoint_id") mutable checkpointId: string,
  @as("envio_version") mutable version: float,
}

type addressRow = {
  @as("chain_id") chainId: ChainId.t,
  address: string,
  @as("contract_id") contractId: int,
  @as("registration_block") registrationBlock: int,
  @as("envio_version") version: float,
  @as("envio_is_deleted") isDeleted: int,
}

type infoRow = {
  id: int,
  config: string,
  @as("contract_names") contractNames: array<string>,
  @as("envio_version") version: float,
}

let quoteIdent = name =>
  "`" ++ name->String.replaceAll("\\", "\\\\")->String.replaceAll("`", "\\`") ++ "`"

let quoteString = value =>
  "'" ++ value->String.replaceAll("\\", "\\\\")->String.replaceAll("'", "\\'") ++ "'"

// What every read is answered in: 64-bit and wider integers and decimals as
// strings, so no digit is lost to a JS number, and timestamps as ISO 8601.
let readSettings = " SETTINGS output_format_json_quote_64bit_integers = 1, output_format_json_quote_decimals = 1, date_time_output_format = 'iso' FORMAT JSONEachRow"

external asRows: array<'row> => array<JSON.t> = "%identity"

let parseLines = (text: string): array<JSON.t> =>
  text
  ->String.split("\n")
  ->Array.filterMap(line => line === "" ? None : Some(line->JSON.parseOrThrow))

%%private(
  let isoDate = S.string->S.transform(_ => {
    parser: text => text->Date.fromString,
    serializer: date => date->Date.toISOString,
  })

  // A Json column holds the document's text.
  let jsonText = S.string->S.transform(_ => {
    parser: text => text->JSON.parseOrThrow,
    serializer: json => json->JSON.stringify,
  })
)

let readFieldSchema = (f: Table.field) => {
  let shaped = base =>
    if f.isArray {
      S.array(base)->S.toUnknown
    } else if f.isNullable {
      Utils.Schema.nullTolerant(base)->S.toUnknown
    } else {
      base
    }
  switch f.fieldType {
  | Date => shaped(isoDate->S.toUnknown)
  | Json => shaped(jsonText->S.toUnknown)
  | _ => f.fieldSchema
  }
}

let makeRowsSchema = (table: Table.table, ~skipChainId) =>
  S.array(
    S.object(s => {
      let dict = Dict.make()
      table.fields->Array.forEach(field =>
        switch field {
        | Field({isChainId: true}) if skipChainId => ()
        | Field(f) =>
          dict->Dict.set(
            f->Table.getApiFieldName,
            s.field(f->Table.getClickHouseDbFieldName, readFieldSchema(f)),
          )
        | DerivedFrom(_) => ()
        }
      )
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<unknown>),
  )

let rowsSchema: Table.table => S.t<array<unknown>> = Utils.WeakMap.memoize(table =>
  table->makeRowsSchema(~skipChainId=false)
)

// Shaped like the entity handlers see, without the chain column the scope
// already says.
let entityRowsSchema: Table.table => S.t<array<unknown>> = Utils.WeakMap.memoize(table =>
  table->makeRowsSchema(~skipChainId=true)
)

let selectColumns: Table.table => string = Utils.WeakMap.memoize((table: Table.table) =>
  table.fields
  ->Array.filterMap(field =>
    switch field {
    | Field(f) => Some(f->Table.getClickHouseDbFieldName->quoteIdent)
    | DerivedFrom(_) => None
    }
  )
  ->Array.join(", ")
)

%%private(
  let renderValue = (value: Null.t<string>, ~kind: LoadCondition.valueKind) =>
    switch value->Null.toOption {
    | None => "NULL"
    | Some(text) =>
      switch kind {
      | Boolean => text === "true" ? "true" : "false"
      | Timestamp => `parseDateTime64BestEffort(${text->quoteString}, 3, 'UTC')`
      // A number travels as a string literal too: ClickHouse converts it to the
      // column's own type, where a bare literal past UInt64 would turn Float64.
      | _ => text->quoteString
      }
    }

  let renderElements = (elements: array<Null.t<string>>, ~condition: LoadCondition.t) =>
    condition.isList
      ? "[" ++
        elements
        ->Array.map(value => value->renderValue(~kind=condition.kind))
        ->Array.join(", ") ++ "]"
      : elements->Array.getUnsafe(0)->renderValue(~kind=condition.kind)

  let renderCondition = (condition: LoadCondition.t) => {
    let column = condition.column->quoteIdent
    let comparison = symbol => {
      let elements = condition.values->Array.getUnsafe(0)
      let isNull = !condition.isList && elements->Array.getUnsafe(0)->Null.toOption->Option.isNone
      switch (symbol, isNull) {
      | ("=", true) => `isNull(${column})`
      | (_, true) => "false"
      | _ => `${column} ${symbol} ${elements->renderElements(~condition)}`
      }
    }
    switch condition.operator {
    | Eq => comparison("=")
    | Gt => comparison(">")
    | Lt => comparison("<")
    | Gte => comparison(">=")
    | Lte => comparison("<=")
    | In =>
      condition.values->Utils.Array.isEmpty
        ? "false"
        : `${column} IN (${condition.values
            ->Array.map(elements => elements->renderElements(~condition))
            ->Array.join(", ")})`
    }
  }
)

// The ids a filter asks for when ids are all it asks for, together with the
// chain a per-chain entity's scope adds. Those are the loads a lookup table
// answers.
let byIds = (conditions: array<LoadCondition.t>) => {
  let ids = ref(None)
  let chainId = ref(None)
  let other = ref(false)
  conditions->Array.forEach(condition => {
    let texts = () =>
      condition.values->Array.filterMap(elements => elements->Array.getUnsafe(0)->Null.toOption)
    switch condition {
    | {column: "id", operator: In | Eq, isList: false} if ids.contents->Option.isNone =>
      ids := Some(texts())
    | {isChainId: true, operator: Eq} if chainId.contents->Option.isNone =>
      chainId := texts()->Array.get(0)
    | _ => other := true
    }
  })
  switch (ids.contents, other.contents) {
  | (Some(ids), false) => Some((ids, chainId.contents))
  | _ => None
  }
}

type lookup = Requested | Ready

// The columns Postgres would index for the schema — every `@index`, the first
// column of every composite index, and the column each `@derivedFrom` reads —
// as data-skipping indexes: a bloom filter for a column filtered by equality,
// a min/max for one filtered by range.
let skippingIndexes = (entities: array<Internal.entityConfig>) => {
  let derivedSchema = Schema.make(entities->Array.map(e => e.table))
  let tables = Dict.make()
  entities->Array.forEach(entityConfig =>
    tables->Dict.set(entityConfig.table.tableName, entityConfig.table)
  )
  let columns = []
  entities->Array.forEach(({table}) => {
    table->Table.getSingleIndexes->Array.forEach(column => columns->Array.push((table, column)))
    table
    ->Table.getCompositeIndexes
    ->Array.forEach(indexFields =>
      switch indexFields->Array.get(0) {
      | Some({fieldName}) => columns->Array.push((table, fieldName))
      | None => ()
      }
    )
    table
    ->Table.getDerivedFromFields
    ->Array.forEach(derivedFromField =>
      switch (
        tables->Utils.Dict.dangerouslyGetNonOption(derivedFromField.derivedFromEntity),
        derivedSchema->Schema.getDerivedFromPgFieldName(derivedFromField),
      ) {
      | (Some(target), Ok(column)) => columns->Array.push((target, column))
      | _ => ()
      }
    )
  })
  let seen = Utils.Set.make()
  columns->Array.filterMap(((table: Table.table, column)) => {
    let identity = `${table.tableName}.${column}`
    let field = table.fields->Array.find(field =>
      switch field {
      | Field(f) => f->Table.getPgDbFieldName === column
      | DerivedFrom(_) => false
      }
    )
    switch field {
    | Some(Field(f)) if !(seen->Utils.Set.has(identity)) && column !== Table.idFieldName =>
      seen->Utils.Set.add(identity)->ignore
      Some((
        table.tableName,
        f->Table.getClickHouseDbFieldName,
        switch f.fieldType {
        | String | Bytea | Enum(_) => "bloom_filter(0.01)"
        | _ => "minmax"
        },
      ))
    | _ => None
    }
  })
}

// The rows above each chain's bound, for a table whose chain column is
// `chainColumn`. One shared counter holds every chain to its lowest bound.
let aboveBounds = (
  {sequence, byChain}: CheckpointSequence.checkpointBoundsByChain,
  ~chainColumn: option<string>,
  ~checkpointColumn,
) => {
  let checkpoint = checkpointColumn->quoteIdent
  switch (sequence, chainColumn) {
  | (SharedAcrossChains, _) | (PerChain, None) =>
    `${checkpoint} > ${byChain->Frontier.min->BigInt.toString}`
  | (PerChain, Some(chainColumn)) =>
    switch byChain->Frontier.entries {
    | [] => "false"
    | entries =>
      entries
      ->Array.map(((chainId, checkpointId)) =>
        `(${chainColumn->quoteIdent} = ${chainId->ChainId.toString} AND ${checkpoint} > ${checkpointId->BigInt.toString})`
      )
      ->Array.join(" OR ")
    }
  }
}

let make = (
  ~host,
  ~database,
  ~username,
  ~password,
  ~chainIdMode: ChainId.mode,
  ~ecosystem: Ecosystem.name,
): Persistence.storage => {
  let sink = ClickHouse.makeSink(~host, ~username, ~password, ~database, ~chainIdMode)
  let registry = ClickHouse.makeRegistry(~primary=true)
  let db = database->quoteIdent
  let tableRef = name => `${db}.${name->quoteIdent}`

  let query = async statement =>
    try await sink->ClickHouseSink.query(statement) catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: "Failed a ClickHouse statement",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  let select = async statement => (await query(statement ++ readSettings))->parseLines
  let selectWithIds = async (statement, ids) =>
    try (
      await sink->ClickHouseSink.queryWithIds(statement ++ readSettings, ids)
    )->parseLines catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: "Failed a ClickHouse statement",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }

  // Lookup tables are local to the node, so a replicated deployment does
  // without them.
  let lookupsEnabled = !Env.ClickHouse.replicated()
  let lookups: dict<lookup> = Dict.make()
  let entitiesByTable: dict<Internal.entityConfig> = Dict.make()
  let rememberEntities = (entities: array<Internal.entityConfig>) =>
    entities->Array.forEach(entityConfig =>
      if entityConfig.storage.clickhouse {
        entitiesByTable->Dict.set(entityConfig.table.tableName, entityConfig)
      }
    )
  let insertRows = async (table, rows: array<JSON.t>) =>
    if rows->Utils.Array.notEmpty {
      let _ = await query(
        `INSERT INTO ${table->tableRef} FORMAT JSONEachRow\n` ++
        rows->Array.map(JSON.stringify(_))->Array.join("\n"),
      )
    }

  // Every replaced row has to win over the one before it, across restarts too.
  let lastVersion = ref(Date.now() *. 1000.)
  let nextVersion = () => {
    lastVersion := Math.max(lastVersion.contents +. 1., Date.now() *. 1000.)
    lastVersion.contents
  }

  let chainRows: dict<chainRow> = Dict.make()
  let writeChainRows = async (rows: array<chainRow>) => {
    rows->Array.forEach(row => row.version = nextVersion())
    await insertRows(chainStateTable, rows->asRows)
  }
  let rowOf = chainId => chainRows->Utils.Dict.dangerouslyGetNonOption(chainId->ChainId.toString)

  let addressRowOf = (row: AddressRows.row, ~isDeleted) => {
    chainId: row.chainId,
    address: row.address->NodeJs.Buffer.toHex,
    contractId: row.contractId,
    registrationBlock: row.registrationBlock,
    version: nextVersion(),
    isDeleted,
  }

  let primaryEntities = (entities: array<Internal.entityConfig>) =>
    entities->Array.filter(e => e.storage.clickhouse)
  let entitySpecs = entities =>
    entities
    ->primaryEntities
    ->Array.map(entityConfig => ClickHouse.entitySpec(~entityConfig, ~primary=true))

  let isInitialized = async () => {
    let answer = await select(
      `SELECT count() AS tables FROM system.tables WHERE database = ${database->quoteString} AND name = ${infoTable->quoteString}`,
    )
    switch answer->(Utils.magic: array<JSON.t> => array<{"tables": string}>) {
    | [row] if row["tables"] !== "0" =>
      (await select(`SELECT id FROM ${infoTable->tableRef} FINAL LIMIT 1`))->Utils.Array.notEmpty
    | _ => false
    }
  }

  let readEffectCacheRecords = async () => {
    let cache = Dict.make()

    (
      await select(
        `SELECT name, total_rows FROM system.tables WHERE database = ${database->quoteString} AND name LIKE '%effect%'`,
      )
    )->Array.forEach(row => {
      let row = row->(Utils.magic: JSON.t => {"name": string, "total_rows": Null.t<string>})
      switch Internal.EffectCache.fromTableName(row["name"]) {
      | Some((effectName, scope)) =>
        cache->Dict.set(
          row["name"],
          (
            {
              effectName,
              scope,
              tableName: row["name"],
              count: row["total_rows"]
              ->Null.toOption
              ->Option.flatMap(Int.fromString(_))
              ->Option.getOr(0),
            }: Persistence.effectCacheRecord
          ),
        )
      | None => ()
      }
    })
    cache
  }

  let newChainRow = (chainConfig: Config.chain) => {
    id: chainConfig.id,
    ecosystem: (chainConfig.ecosystem :> string),
    startBlock: chainConfig->Config.startBlockOrThrow,
    endBlock: chainConfig.endBlock->Null.fromOption,
    maxReorgDepth: chainConfig.maxReorgDepth,
    sourceBlock: 0,
    firstEventBlock: Null.null,
    bufferBlock: -1,
    progressBlock: -1,
    progressBlockTime: Null.null,
    readyAt: Null.null,
    eventsProcessed: 0.,
    isHyperSync: false,
    checkpointId: "0",
    version: 0.,
  }

  let initialize = async (
    ~chainConfigs=[],
    ~entities=[],
    ~enums as _=[],
    ~contractMapping,
    ~envioInfo,
  ): Persistence.initialState => {
    rememberEntities(entities)
    lookups->Utils.Dict.forEachWithKey((_, key) => lookups->Utils.Dict.deleteInPlace(key))
    try await sink->ClickHouseSink.initialize({
      entities: entities->entitySpecs,
      checkpointColumns: ClickHouse.checkpointColumnSpecs,
      replicated: Env.ClickHouse.replicated(),
      databaseEngine: ?Env.ClickHouse.databaseEngine(),
      primary: true,
    }) catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: "Failed to initialize ClickHouse storage",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }

    let rowsByChain =
      chainConfigs->Array.map(chainConfig =>
        chainConfig->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      )
    await insertRows(
      addressesTable,
      rowsByChain->Array.flat->Array.map(row => row->addressRowOf(~isDeleted=0))->asRows,
    )
    await insertRows(
      infoTable,
      [
        {
          id: 1,
          config: envioInfo->JSON.stringify,
          contractNames: contractMapping->ContractMapping.names,
          version: nextVersion(),
        },
      ]->asRows,
    )
    chainRows->Utils.Dict.forEachWithKey((_, key) => chainRows->Utils.Dict.deleteInPlace(key))
    let rows = chainConfigs->Array.map(newChainRow)
    rows->Array.forEach(row => chainRows->Dict.set(row.id->ChainId.toString, row))
    // Last: the chain rows are what says the storage exists.
    await writeChainRows(rows)

    {
      cleanRun: true,
      cache: Dict.make(),
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

  let readChainRows = async () =>
    (
      await select(
        `SELECT id, ecosystem, toInt32(start_block) AS start_block, toInt32OrNull(toString(end_block)) AS end_block, max_reorg_depth, toInt32(source_block) AS source_block, toInt32OrNull(toString(first_event_block)) AS first_event_block, toInt32(buffer_block) AS buffer_block, toInt32(progress_block) AS progress_block, toInt32OrNull(toString(progress_block_time)) AS progress_block_time, toFloat64OrNull(toString(ready_at)) AS ready_at, events_processed, _is_hyper_sync, toString(checkpoint_id) AS checkpoint_id, toFloat64(envio_version) AS envio_version FROM ${chainStateTable->tableRef} FINAL`,
      )
    )->Array.map(row => {
      let row = row->(Utils.magic: JSON.t => chainRow)
      {...row, id: row.id->ChainId.normalizeOrThrow}
    })

  let readAddressRows = async (~onlyConfig) =>
    (
      await select(
        `SELECT chain_id, address, contract_id, toInt32(registration_block) AS registration_block FROM ${addressesTable->tableRef} FINAL${onlyConfig
            ? ` WHERE registration_block = ${AddressRows.configRegistrationBlock->Int.toString}`
            : ""} ORDER BY chain_id`,
      )
    )->Array.map(row => {
      let row = row->(Utils.magic: JSON.t => addressRow)

      (
        {
          chainId: row.chainId->ChainId.normalizeOrThrow,
          address: row.address->NodeJs.Buffer.fromHex,
          contractId: row.contractId,
          registrationBlock: row.registrationBlock,
        }: AddressRows.row
      )
    })

  let readStoredConfig = async (): ResumePlan.stored => {
    let (infos, chains, configAddresses) = await Promise.all3((
      select(`SELECT config, contract_names FROM ${infoTable->tableRef} FINAL`),
      readChainRows(),
      readAddressRows(~onlyConfig=true),
    ))
    switch infos {
    | [info] =>
      let info = info->(Utils.magic: JSON.t => infoRow)
      let configAddressesByChain = Dict.make()
      configAddresses->Array.forEach(row =>
        configAddressesByChain->Utils.Dict.push(row.chainId->ChainId.toString, row)
      )
      {
        envioInfo: Some(info.config->JSON.parseOrThrow),
        chains: chains->Array.map((chain): ResumePlan.storedChain => {
          id: chain.id,
          ecosystem: chain.ecosystem,
          startBlock: chain.startBlock,
          endBlock: chain.endBlock->Null.toOption,
          maxReorgDepth: chain.maxReorgDepth,
          configAddresses: configAddressesByChain
          ->Utils.Dict.dangerouslyGetNonOption(chain.id->ChainId.toString)
          ->Option.getOr([]),
        }),
        contractMapping: ContractMapping.fromStoredNames(info.contractNames),
      }
    | _ => {envioInfo: None, chains: [], contractMapping: ContractMapping.empty}
    }
  }

  let addChain = async (~chainConfig: Config.chain, ~entities as _, ~contractMapping) => {
    await insertRows(
      addressesTable,
      chainConfig
      ->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      ->Array.map(row => row->addressRowOf(~isDeleted=0))
      ->asRows,
    )
    let row = chainConfig->newChainRow
    chainRows->Dict.set(row.id->ChainId.toString, row)
    await writeChainRows([row])
  }

  let resumeInitialState = async (
    ~entities,
    ~chainIds,
    ~contractMapping,
  ): Persistence.initialState => {
    rememberEntities(entities)
    let stored = (await readChainRows())->Array.filter(chain => chainIds->Array.includes(chain.id))
    stored->Array.forEach(row => chainRows->Dict.set(row.id->ChainId.toString, row))

    (
      await select(
        `SELECT name FROM system.tables WHERE database = ${database->quoteString} AND startsWith(name, 'envio_kv_')`,
      )
    )->Array.forEach(row => {
      let name = row->(Utils.magic: JSON.t => {"name": string})
      lookups->Dict.set(name["name"]->String.slice(~start=9), Ready)
    })
    let isLookupReady = (entityConfig: Internal.entityConfig) =>
      lookups->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) === Some(Ready)

    // Drops what an interrupted batch left uncommitted, applies what it
    // committed, and trims history and checkpoints past each chain row.
    try await sink->ClickHouseSink.resume({
      perChain: switch CheckpointSequence.fromEntities(entities) {
      | PerChain => true
      | SharedAcrossChains => false
      },
      chainProgress: stored->Array.map((chain): ClickHouseSink.chainProgressInput => {
        chainId: chain.id->ChainId.toString,
        progressBlockNumber: chain.progressBlock,
        committedCheckpointId: chain.checkpointId,
      }),
      historyTables: entities
      ->entitySpecs
      ->Array.map(spec => {
        ClickHouseSink.name: spec.historyTable,
        chainIdColumn: ?spec.chainIdColumn,
      }),
      primaryEntities: entities
      ->primaryEntities
      ->Array.map((entityConfig): ClickHouseSink.redoInput => {
        entity: ClickHouse.entitySpec(~entityConfig, ~primary=true),
        keepHistory: true,
        lookup: entityConfig->isLookupReady,
      }),
    }) catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: "Failed to resume ClickHouse storage",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }

    let reorgChains =
      stored->Array.filter(chain =>
        chain.maxReorgDepth > 0 && chain.progressBlock > chain.sourceBlock - chain.maxReorgDepth
      )
    let (cache, addressRows, reorgCheckpoints) = await Promise.all3((
      readEffectCacheRecords(),
      readAddressRows(~onlyConfig=false),
      reorgChains->Utils.Array.isEmpty
        ? Promise.resolve([])
        : select(
            `SELECT toString(id) AS id, chain_id, block_number, block_hash FROM ${InternalTable.Checkpoints.table.tableName->tableRef} WHERE block_hash IS NOT NULL AND (${reorgChains
              ->Array.map(chain =>
                `(chain_id = ${chain.id->ChainId.toString} AND block_number >= ${(chain.sourceBlock -
                  chain.maxReorgDepth)->Int.toString})`
              )
              ->Array.join(" OR ")}) ORDER BY id`,
          ),
    ))
    let addressRowsByChainId = addressRows->AddressRows.group

    {
      cleanRun: false,
      cache,
      contractMapping,
      reorgCheckpoints: reorgCheckpoints->Array.map((row): Internal.reorgCheckpoint => {
        let row =
          row->(
            Utils.magic: JSON.t => {
              "id": string,
              "chain_id": float,
              "block_number": int,
              "block_hash": string,
            }
          )
        {
          checkpointId: row["id"]->BigInt.fromStringOrThrow,
          chainId: row["chain_id"]->ChainId.normalizeOrThrow,
          blockNumber: row["block_number"],
          blockHash: row["block_hash"],
        }
      }),
      chains: stored->Array.map((chain): Persistence.initialChainState => {
        id: chain.id,
        startBlock: chain.startBlock,
        endBlock: chain.endBlock->Null.toOption,
        maxReorgDepth: chain.maxReorgDepth,
        firstEventBlockNumber: chain.firstEventBlock->Null.toOption,
        timestampCaughtUpToHeadOrEndblock: chain.readyAt->Null.toOption->Option.map(Date.fromTime),
        numEventsProcessed: chain.eventsProcessed,
        progressBlockNumber: chain.progressBlock,
        progressBlockTime: chain.progressBlockTime->Null.toOption,
        addressRows: addressRowsByChainId
        ->Utils.Dict.dangerouslyGetNonOption(chain.id->ChainId.toString)
        ->Option.getOr(AddressRows.emptySeedRows()),
        sourceBlockNumber: chain.sourceBlock,
      }),
      checkpointFrontier: Frontier.fromEntries(
        stored->Array.map(chain => (chain.id, chain.checkpointId->BigInt.fromStringOrThrow)),
      ),
    }
  }

  let loadOrThrow = async (~filter: EntityFilter.t, ~table: Table.table) => {
    let conditions = LoadFilter.make(~filter, ~table, ~column=field => field.clickhouseDbFieldName)
    let entityConfig = entitiesByTable->Utils.Dict.dangerouslyGetNonOption(table.tableName)
    let rows = switch (conditions->byIds, entityConfig) {
    | (Some((ids, chainId)), Some(entityConfig))
      if lookups->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) === Some(Ready) =>
      let keys = switch chainId {
      | Some(chainId) => ids->Array.map(id => `${chainId}:${id}`)
      | None => ids
      }
      selectWithIds(
        `SELECT ${table->selectColumns} FROM ${ClickHouseSink.lookupTableName(
            entityConfig.name,
          )->tableRef} WHERE envio_key IN _ids AND envio_is_deleted = 0`,
        keys,
      )
    | (Some((ids, chainId)), _) =>
      switch entityConfig {
      | Some(entityConfig) if lookupsEnabled && !(lookups->Dict.has(entityConfig.name)) =>
        lookups->Dict.set(entityConfig.name, Requested)
      | _ => ()
      }
      let chainFilter = switch (chainId, table->Table.getChainIdField) {
      | (Some(chainId), Some(field)) =>
        ` AND ${field->Table.getClickHouseDbFieldName->quoteIdent} = ${chainId->quoteString}`
      | _ => ""
      }
      selectWithIds(
        `SELECT ${table->selectColumns} FROM ${table.tableName->tableRef} FINAL WHERE ${Table.idFieldName->quoteIdent} IN _ids${chainFilter}`,
        ids,
      )
    | (None, _) =>
      let where = switch conditions {
      | [] => ""
      | conditions => " WHERE " ++ conditions->Array.map(renderCondition)->Array.join(" AND ")
      }
      select(`SELECT ${table->selectColumns} FROM ${table.tableName->tableRef} FINAL${where}`)
    }
    switch await rows {
    | exception exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by ${conditions->LoadFilter.describe}.`,
          reason: exn,
        }),
      )
    | rows =>
      try rows
      ->(Utils.magic: array<JSON.t> => unknown)
      ->S.parseOrThrow(table->entityRowsSchema) catch {
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

  let setReadyAt = async (~chainIds, ~readyAt: Date.t) => {
    let rows = chainIds->Array.filterMap(rowOf)
    rows->Array.forEach(row => row.readyAt = Null.make(readyAt->Date.getTime))
    await writeChainRows(rows)
  }

  let applyMeta = (chainsData: dict<InternalTable.Chains.metaFields>) =>
    chainsData
    ->Dict.toArray
    ->Array.filterMap(((chainId, meta)) =>
      chainId
      ->ChainId.normalizeOrThrow
      ->rowOf
      ->Option.map(row => {
        row.firstEventBlock = meta.firstEventBlockNumber
        row.bufferBlock = meta.latestFetchedBlockNumber
        row.readyAt = meta.timestampCaughtUpToHeadOrEndblock->Null.map(Date.getTime)
        row.isHyperSync = meta.isHyperSync
        row
      })
    )

  let applyProgress = (progress: InternalTable.Chains.progressedChain) =>
    progress.chainId
    ->rowOf
    ->Option.map(row => {
      row.progressBlock = progress.progressBlockNumber
      row.progressBlockTime = progress.progressBlockTime->Null.fromOption
      row.sourceBlock = progress.sourceBlockNumber
      row.eventsProcessed = progress.totalEventsProcessed
      row
    })

  let setChainMeta = async chainsData => {
    await writeChainRows(chainsData->applyMeta)
    %raw(`undefined`)
  }

  let getRollbackTargetCheckpoint = async (~reorgChainId, ~lastKnownValidBlockNumber) => {
    let rows = await select(
      `SELECT toString(id) AS id FROM ${InternalTable.Checkpoints.table.tableName->tableRef} WHERE chain_id = ${reorgChainId->ChainId.toString} AND block_number <= ${lastKnownValidBlockNumber->Int.toString} ORDER BY id DESC LIMIT 1`,
    )
    switch rows->(Utils.magic: array<JSON.t> => array<{"id": string}>) {
    | [row] => Some(row["id"]->BigInt.fromStringOrThrow)
    | _ => None
    }
  }

  let getRollbackProgressDiff = async (~floors: RollbackFloors.t) =>
    (
      await select(
        `SELECT chain_id, toString(sum(events_processed)) AS events_processed_diff, toInt32(min(block_number) - 1) AS new_progress_block_number FROM ${InternalTable.Checkpoints.table.tableName->tableRef} WHERE ${floors.checkpointBounds->aboveBounds(
            ~chainColumn=Some("chain_id"),
            ~checkpointColumn="id",
          )} GROUP BY chain_id`,
      )
    )->Array.map(row => {
      let row =
        row->(
          Utils.magic: JSON.t => {
            "chain_id": float,
            "events_processed_diff": string,
            "new_progress_block_number": int,
          }
        )
      {
        "chain_id": row["chain_id"]->ChainId.normalizeOrThrow,
        "events_processed_diff": row["events_processed_diff"],
        "new_progress_block_number": row["new_progress_block_number"],
      }
    })

  let historyRef = (entityConfig: Internal.entityConfig) =>
    EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    )->tableRef

  let historyAbove = (entityConfig: Internal.entityConfig, ~bounds) =>
    bounds->aboveBounds(
      ~chainColumn=entityConfig.table
      ->Table.getChainIdField
      ->Option.map(Table.getClickHouseDbFieldName),
      ~checkpointColumn=EntityHistory.checkpointIdFieldName,
    )

  let getRollbackData = async (~entityConfig: Internal.entityConfig, ~floors: RollbackFloors.t) => {
    let table = entityConfig.table
    let chainField = table->Table.getChainIdField
    let key =
      [Table.idFieldName]
      ->Array.concat(
        switch chainField {
        | Some(field) => [field->Table.getClickHouseDbFieldName]
        | None => []
        },
      )
      ->Array.map(quoteIdent)
      ->Array.join(", ")
    let history = entityConfig->historyRef
    let above = entityConfig->historyAbove(~bounds=floors.checkpointBounds)
    let change = EntityHistory.changeFieldName->quoteIdent
    let (removedRows, restoredRows) = await Promise.all2((
      select(
        `SELECT DISTINCT ${key} FROM ${history} WHERE (${above}) AND (${key}) NOT IN (SELECT ${key} FROM ${history} WHERE NOT (${above}))`,
      ),
      select(
        `SELECT ${table->selectColumns}, toString(${change}) AS ${change} FROM ${history} WHERE NOT (${above}) AND (${key}) IN (SELECT ${key} FROM ${history} WHERE ${above}) ORDER BY ${key}, ${EntityHistory.checkpointIdFieldName->quoteIdent} DESC LIMIT 1 BY ${key}`,
      ),
    ))
    let scopeOf = (row: JSON.t) =>
      switch chainField {
      | None => Internal.CrossChain
      | Some(field) =>
        Internal.Chain(
          row
          ->(Utils.magic: JSON.t => dict<unknown>)
          ->Dict.getUnsafe(field->Table.getClickHouseDbFieldName)
          ->ChainId.normalizeOrThrow,
        )
      }
    let idOf = (row: JSON.t) =>
      row
      ->(Utils.magic: JSON.t => dict<unknown>)
      ->Dict.getUnsafe(Table.idFieldName)
      ->S.parseOrThrow(table->Table.getIdSchema)
    let removals = removedRows->Array.map((row): Persistence.rollbackRemoval => {
      entityId: row->idOf,
      scope: row->scopeOf,
    })
    let restored = []
    restoredRows->Array.forEach(row =>
      switch row
      ->(Utils.magic: JSON.t => dict<string>)
      ->Dict.getUnsafe(EntityHistory.changeFieldName) {
      | "SET" => restored->Array.push(row)
      | _ => removals->Array.push({entityId: row->idOf, scope: row->scopeOf})
      }
    )
    (
      removals,
      restored
      ->(Utils.magic: array<JSON.t> => unknown)
      ->S.parseOrThrow(table->rowsSchema)
      ->(Utils.magic: array<unknown> => array<Internal.entity>),
    )
  }

  let writeEffectCaches = async (updatedEffectsCache: array<Persistence.updatedEffectCache>) => {
    let _ = await updatedEffectsCache
    ->Array.map(async ({table, itemSchema, items, shouldInitialize}) => {
      if shouldInitialize {
        let _ = await query(
          `CREATE TABLE IF NOT EXISTS ${table.tableName->tableRef} (id String, output String) ENGINE = ReplacingMergeTree ORDER BY id`,
        )
      }
      await insertRows(
        table.tableName,
        items
        ->Array.map(item => {
          let row =
            item
            ->S.reverseConvertOrThrow(itemSchema)
            ->(Utils.magic: unknown => {"id": string, "output": JSON.t})
          {"id": row["id"], "output": row["output"]->JSON.stringify}
        })
        ->asRows,
      )
    })
    ->Promise.all
  }

  let writeBatch = async (
    ~batch: Batch.t,
    ~rollback: option<Persistence.rollback>,
    ~config as _: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache: array<Persistence.updatedEffectCache>,
    ~updatedEntities: array<Persistence.updatedEntity>,
    ~registeredAddresses: array<AddressRows.staged>,
    ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
    ~onWrite,
  ) => {
    let timerRef = Performance.now()
    let touched: dict<chainRow> = Dict.make()
    let touch = (row: chainRow) => touched->Dict.set(row.id->ChainId.toString, row)

    switch rollback {
    | Some({floors, progressedChains, rolledBackAddresses}) =>
      // The chains move back first: a crash past this point resumes from the
      // rollback target and trims and repairs everything above it.
      let moved = progressedChains->Array.filterMap(applyProgress)
      moved->Array.forEach(row =>
        switch floors.checkpointBounds.byChain->Frontier.find(row.id) {
        | Some(floor) => row.checkpointId = floor->BigInt.toString
        | None => ()
        }
      )
      await writeChainRows(moved)
      let bounds = floors.checkpointBounds
      let _ = await allEntities
      ->primaryEntities
      ->Array.map(entityConfig =>
        query(
          `DELETE FROM ${entityConfig->historyRef} WHERE ${entityConfig->historyAbove(
              ~bounds,
            )} SETTINGS lightweight_deletes_sync = 1`,
        )
      )
      ->Promise.all
      let _ = await query(
        `DELETE FROM ${InternalTable.Checkpoints.table.tableName->tableRef} WHERE ${bounds->aboveBounds(
            ~chainColumn=Some("chain_id"),
            ~checkpointColumn="id",
          )} SETTINGS lightweight_deletes_sync = 1`,
      )
      await insertRows(
        addressesTable,
        rolledBackAddresses
        ->Array.map((key): addressRow => {
          chainId: key.chainId,
          address: key.address->NodeJs.Buffer.toHex,
          contractId: key.contractId,
          registrationBlock: 0,
          version: nextVersion(),
          isDeleted: 1,
        })
        ->asRows,
      )
    | None => ()
    }

    let entities = []
    let checkpoints = try {
      updatedEntities->Array.forEach(({entityConfig, scope, changes}) =>
        switch ClickHouse.stageUpdatesOrThrow(sink, ~registry, ~changes, ~entityConfig, ~scope) {
        | Some(handle) => entities->Array.push(handle)
        | None => ()
        }
      )
      // No rows for a rollback's diff: the current tables don't resolve through
      // checkpoints, and a later rollback reading one back would take its chain
      // to the block before the one the diff left it at.
      ClickHouse.stageCheckpointsOrThrow(sink, ~registry, ~batch, ~diffCheckpoints=[])
    } catch {
    | exn =>
      sink->ClickHouseSink.discard(entities)
      throw(exn)
    }
    await ClickHouse.writeStagedOrThrow(sink, ~entities, ~checkpoints)

    let _ = await Promise.all2((
      insertRows(
        addressesTable,
        registeredAddresses->Array.map(staged => staged.row->addressRowOf(~isDeleted=0))->asRows,
      ),
      writeEffectCaches(updatedEffectsCache),
    ))

    // A chain the rollback moved and the batch then progressed ends where the
    // batch took it.
    switch rollback {
    | Some({progressedChains}) =>
      progressedChains->Array.forEach(progress => progress->applyProgress->Option.forEach(touch))
    | None => ()
    }
    batch.progressedChainsById->Utils.Dict.forEach(chainAfterBatch =>
      applyProgress({
        chainId: chainAfterBatch.fetchState.chainId,
        progressBlockNumber: chainAfterBatch.progressBlockNumber,
        progressBlockTime: chainAfterBatch.progressBlockTime,
        sourceBlockNumber: chainAfterBatch.sourceBlockNumber,
        totalEventsProcessed: chainAfterBatch.totalEventsProcessed,
      })->Option.forEach(touch)
    )
    chainMetaData->Option.forEach(meta => meta->applyMeta->Array.forEach(touch))
    Persistence.writtenFrontier(~batch, ~rollback)
    ->Frontier.entries
    ->Array.forEach(((chainId, checkpointId)) =>
      chainId
      ->rowOf
      ->Option.forEach(row => {
        row.checkpointId = checkpointId->BigInt.toString
        touch(row)
      })
    )
    await writeChainRows(touched->Dict.valuesToArray)

    // Committed: the batch moves out of the redo tables. A lookup a handler
    // asked for since the last write is built first, from current tables that
    // hold every batch before this one, and then takes this one with them.
    let building =
      lookups
      ->Dict.toArray
      ->Array.filterMap(((name, state)) => state === Requested ? Some(name) : None)
    let _ = await building
    ->Array.filterMap(name =>
      entitiesByTable
      ->Dict.valuesToArray
      ->Array.find(entityConfig => entityConfig.name === name)
    )
    ->Array.map(entityConfig =>
      sink->ClickHouseSink.buildLookup(ClickHouse.entitySpec(~entityConfig, ~primary=true))
    )
    ->Promise.all
    let redo: dict<ClickHouseSink.redoInput> = Dict.make()
    updatedEntities->Array.forEach(({entityConfig, shouldSaveHistory}) =>
      switch redo->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) {
      | Some(input) =>
        redo->Dict.set(
          entityConfig.name,
          {...input, keepHistory: input.keepHistory || shouldSaveHistory},
        )
      | None =>
        redo->Dict.set(
          entityConfig.name,
          {
            entity: ClickHouse.entitySpec(~entityConfig, ~primary=true),
            keepHistory: shouldSaveHistory,
            lookup: lookups->Dict.has(entityConfig.name) &&
              (lookups->Dict.getUnsafe(entityConfig.name) === Ready ||
                building->Array.includes(entityConfig.name)),
          },
        )
      }
    )
    try await sink->ClickHouseSink.applyRedo(redo->Dict.valuesToArray) catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: "Failed to apply a committed batch in ClickHouse",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
    building->Array.forEach(name => lookups->Dict.set(name, Ready))
    onWrite(~storage=storageName, ~timeSeconds=timerRef->Performance.secondsSince)
  }

  let reset = async () => {
    let _ = await query(`DROP DATABASE IF EXISTS ${db} SYNC`)
  }

  {
    name: storageName,
    isInitialized,
    initialize,
    readStoredConfig,
    addChain,
    resumeInitialState,
    loadOrThrow,
    ensureQueryIndexes: async (~entityConfig as _, ~scope as _, ~filters as _) => (),
    ensureSchemaIndexes: async (~entities as _, ~chainIds as _) => (),
    finalizeBackfill: async (~entities, ~chainIds, ~readyAt) => {
      // Built once the backfill is done, as Postgres builds its indexes, and
      // waited on so `ready_at` means the queries can use them.
      let _ = await entities
      ->primaryEntities
      ->skippingIndexes
      ->Array.map(async ((tableName, column, indexType)) => {
        let index = `envio_idx_${column}`->quoteIdent
        let _ = await query(
          `ALTER TABLE ${tableName->tableRef} ADD INDEX IF NOT EXISTS ${index} ${column->quoteIdent} TYPE ${indexType} GRANULARITY 1`,
        )
        let _ = await query(
          `ALTER TABLE ${tableName->tableRef} MATERIALIZE INDEX ${index} SETTINGS mutations_sync = 2`,
        )
      })
      ->Promise.all
      await setReadyAt(~chainIds, ~readyAt)
    },
    dumpEffectCache: async () =>
      Logging.info("Dumping the effect cache is not supported by ClickHouse-only storage yet."),
    reset,
    setChainMeta,
    pruneStaleCheckpoints: async (~safeCheckpoints as _) => (),
    pruneStaleEntityHistory: async (~entityConfig as _, ~safeCheckpoints as _) => (),
    getRollbackTargetCheckpoint,
    getRollbackProgressDiff,
    getRollbackData,
    writeBatch,
    close: async () => (),
  }
}

let makeFromEnv = (~config: Config.t) => {
  let required = (value, name) =>
    switch value {
    | Some(value) => value
    | None =>
      JsError.throwWithMessage(
        `ClickHouse is the indexer's only storage, but ${name} is not set. Set ENVIO_CLICKHOUSE_HOST, ENVIO_CLICKHOUSE_DATABASE, ENVIO_CLICKHOUSE_USERNAME and ENVIO_CLICKHOUSE_PASSWORD.`,
      )
    }
  make(
    ~host=Env.ClickHouse.host()->required("ENVIO_CLICKHOUSE_HOST"),
    ~database=Env.ClickHouse.database()->required("ENVIO_CLICKHOUSE_DATABASE"),
    ~username=Env.ClickHouse.username()->required("ENVIO_CLICKHOUSE_USERNAME"),
    ~password=Env.ClickHouse.password()->required("ENVIO_CLICKHOUSE_PASSWORD"),
    ~chainIdMode=config.chainIdMode,
    ~ecosystem=config.ecosystem.name,
  )
}
