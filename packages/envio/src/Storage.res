let formatSeconds = seconds => (Math.round(seconds *. 100.) /. 100.)->Float.toString

// Every index build blocks writes to its table for as long as it runs, and on a
// large database that is not quick. Both build paths say so up front, so a
// stalled-looking indexer is explainable from the logs alone.
let slowOnLargeDatabaseNotice = "This can take a long time on a large database."

let storeName = (store: StorageClient.store) =>
  switch store {
  | Postgres => "postgres"
  | ClickHouse => "clickhouse"
  }

let postgresName = Postgres->storeName

let logIndexEvent = (~logger, ~pgSchema, event: StorageClient.indexEvent) =>
  switch event {
  | Invalid({names}) =>
    logger->Logger.warn(
      `Ignoring invalid PostgreSQL indexes in schema "${pgSchema}". They can't serve queries, so the indexer builds its own alongside them.`,
      ~params={"storage": postgresName, "indexes": names},
    )
  | Planned({declared, missing, rebuilt}) =>
    if rebuilt->Utils.Array.notEmpty {
      logger->Logger.warn(
        `PostgreSQL reports ${rebuilt
          ->Array.length
          ->Int.toString} of the indexer's own indexes as invalid, so they can't serve queries. Rebuilding them.`,
        ~params={"storage": postgresName, "indexes": rebuilt},
      )
    }
    switch missing {
    // The line that matters next is the indexer reporting itself ready, which
    // finalization logs.
    | [] =>
      logger->Logger.info(
        `All ${declared->Int.toString} schema indexes are already in place. Marking the indexer ready.`,
        ~params={"storage": postgresName},
      )
    | _ =>
      logger->Logger.info(
        `Creating the ${missing
          ->Array.length
          ->Int.toString} remaining schema indexes before the indexer reports ready. Writes are paused until they are committed. ${slowOnLargeDatabaseNotice}`,
        ~params={"storage": postgresName, "indexes": missing},
      )
    }
  | Building({purpose: Query, name, tableName, isRebuild}) =>
    logger->Logger.info(
      `${isRebuild
          ? "Rebuilding unusable index"
          : "Creating index"} "${name}" to serve a getWhere query on "${tableName}". Writes to the table are paused until it completes. ${slowOnLargeDatabaseNotice}`,
      ~params={"storage": postgresName},
    )
  | Building({purpose: Schema, name, isRebuild}) =>
    logger->Logger.info(
      `${isRebuild
          ? "Rebuilding unusable index"
          : "Creating missing index"} "${name}" the schema promises but the database no longer has. Writes to the table are paused until it completes. ${slowOnLargeDatabaseNotice}`,
      ~params={"storage": postgresName},
    )
  | Built({purpose, name, seconds}) =>
    logger->Logger.info(
      `Index "${name}" is ready after ${seconds->formatSeconds}s.${switch purpose {
        | Query => " Resuming indexing."
        | Schema => ""
        }}`,
      ~params={"storage": postgresName},
    )
  | Failed({purpose: Query, tableName, columns, error, ?code}) =>
    logger->Logger.warn(
      `Failed to create an index on "${tableName}"(${columns
        ->Array.map(column => `"${column}"`)
        ->Array.joinUnsafe(", ")}) for a getWhere query. The query runs without it.`,
      ~params={"storage": postgresName, "err": error, "code": code},
    )
  | Failed({purpose: Schema, name, error, ?code}) =>
    logger->Logger.warn(
      `Failed to restore the schema index "${name}". Queries relying on it run unindexed until the next restart.`,
      ~params={"storage": postgresName, "err": error, "code": code},
    )
  | ResyncFailed({name, error, ?code}) =>
    logger->Logger.trace(
      `Could not re-read the index "${name}" after a failed build. The next attempt reads it again.`,
      ~params={"storage": postgresName, "err": error, "code": code},
    )
  | Committed({count, seconds}) =>
    logger->Logger.info(
      `Committed ${count->Int.toString} schema indexes and the ready timestamp in ${seconds->formatSeconds}s.`,
      ~params={"storage": postgresName},
    )
  }

let postgresOptions = (
  ~pgSchema=Env.Db.publicSchema,
  ~isHasuraEnabled=false,
  ~maxConnections=Env.Db.maxConnections,
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
  }
}

// One client per storage: the stores and the chain-id mode it was created with
// decide every statement the addon builds.
let makeClient = (
  ~logger: Logger.t,
  ~chainIdMode: ChainId.mode=Int32,
  ~postgres: StorageClient.postgresOptions,
  ~clickhouse: option<StorageClient.clickHouseOptions>=?,
): StorageClient.t =>
  StorageClient.make(
    {chainIdMode: (chainIdMode :> string), postgres, ?clickhouse},
    ~onIndexEvent=event => logIndexEvent(~logger, ~pgSchema=postgres.pgSchema, event),
    ~onWarning=message => logger->Logger.warn(message, ~params={"storage": ClickHouse->storeName}),
  )

// A per-chain entity's rows are partitioned by the chain that owns them, so a
// chain-filtered read scans one chain's partition rather than the whole table.
// `$` can't occur in a GraphQL entity name, so a partition name can never
// collide with the table another entity claims; past the identifier limit the
// entity index keeps what survives truncation unique.
let partitionTableName = (~entityConfig: Internal.entityConfig, ~chainId: ChainId.t) => {
  let chainIdStr = chainId->ChainId.toString
  Table.fitPgTableName(
    `${entityConfig.table.tableName}$${chainIdStr}`,
    ~uniqueSuffix=`$${entityConfig.index->Int.toString}$${chainIdStr}`,
  )
}

// The physical tables an index on the entity is built on. A per-chain entity's
// rows are partitioned by chain, and an index declared on the parent cascades
// to every partition, which is what a run driving every chain wants: one
// declaration, one build. An isolated run instead builds on its own chains'
// partitions only: the planner uses a partition's own index either way, and
// building one chain's index then neither waits for nor locks the rows of a
// chain a sibling process drives.
let indexTableNames = (entityConfig: Internal.entityConfig, ~partitionChainIds) =>
  switch (entityConfig.table->Table.getChainIdField, partitionChainIds) {
  | (Some(_), Some(chainIds)) =>
    chainIds->Array.map(chainId => partitionTableName(~entityConfig, ~chainId))
  | _ => [entityConfig.table.tableName]
  }

// Every index the entity schema promises: an `@index` field, a composite index,
// or the index backing a derived relationship. Deferred past the initial DDL
// and created once backfill completes, so a chain that reports itself ready
// always has all of them. With `partitionChainIds`, a per-chain entity's index
// is one per partition of those chains rather than one on the parent.
//
// `entities` is the Postgres-backed set, and every `@derivedFrom` target within
// it resolves: config parsing rejects a Postgres entity deriving from one that
// isn't in Postgres (`validate_relationship_storage`).
let getSchemaIndexes = (
  ~entities: array<Internal.entityConfig>,
  ~partitionChainIds: option<array<ChainId.t>>=?,
): array<IndexDefinition.t> => {
  let derivedSchema = Schema.make(entities->Array.map(e => e.table))
  let all = []

  entities->Array.forEach(({table}) => {
    table
    ->Table.getSingleIndexes
    ->Array.forEach(column =>
      all->Array.push(IndexDefinition.single(~tableName=table.tableName, ~column))->ignore
    )
    table
    ->Table.getCompositeIndexes
    ->Array.forEach(indexFields =>
      all
      ->Array.push(IndexDefinition.fromIndexFields(~tableName=table.tableName, ~indexFields))
      ->ignore
    )
  })

  entities->Array.forEach(({table}) =>
    table
    ->Table.getDerivedFromFields
    ->Array.forEach(derivedFromField => {
      let column =
        derivedSchema->Schema.getDerivedFromPgFieldName(derivedFromField)->Utils.unwrapResultExn
      all
      ->Array.push(IndexDefinition.single(~tableName=derivedFromField.derivedFromEntity, ~column))
      ->ignore
    })
  )

  // An `@index` field and a derived relationship pointing at it describe the
  // same index, so the list is deduped on identity rather than on name.
  let seen = Utils.Set.make()
  let entityByTableName = Dict.make()
  entities->Array.forEach(entityConfig =>
    entityByTableName->Dict.set(entityConfig.table.tableName, entityConfig)
  )

  all
  ->Array.filter(definition => {
    let identity = definition->IndexDefinition.describe
    if seen->Utils.Set.has(identity) {
      false
    } else {
      seen->Utils.Set.add(identity)->ignore
      true
    }
  })
  ->Array.flatMap(definition =>
    entityByTableName
    ->Dict.get(definition.tableName)
    ->Option.getOrThrow
    ->indexTableNames(~partitionChainIds)
    ->Array.map(tableName => {...definition, IndexDefinition.tableName})
  )
}

let pgColumnInput = (field: Table.field): Core.pgColumnInput => {
  let (fieldType, precision, scale, enumName) = field.fieldType->Table.pgFieldTypeParts
  {
    name: field->Table.getPgDbFieldName,
    fieldType,
    isArray: field.isArray,
    isNullable: field.isNullable,
    isPrimaryKey: field.isPrimaryKey,
    defaultValue: ?field.defaultValue,
    ?precision,
    ?scale,
    ?enumName,
  }
}

// The entity as it's stored: the handler-visible schema plus the chain-id
// column a per-chain entity's table carries. The value for that column is
// stamped from the flush group's scope right before serialization, so it never
// has to be re-derived from a checkpoint.
let rowSchemaCache = Utils.WeakMap.make()
let getRowSchema = (entityConfig: Internal.entityConfig): S.t<Internal.entity> =>
  switch rowSchemaCache->Utils.WeakMap.get(entityConfig) {
  | Some(cached) => cached
  | None =>
    let schema = switch entityConfig.table->Table.getChainIdField {
    | None => entityConfig.schema
    | Some(chainIdField) =>
      S.schema(s => {
        let dict = Dict.make()
        switch entityConfig.schema->S.classify {
        | Object({items}) =>
          items->Array.forEach(({location, schema}) => dict->Dict.set(location, s.matches(schema)))
        | _ =>
          JsError.throwWithMessage(
            `Unexpected non-object schema for entity "${entityConfig.name}".`,
          )
        }
        dict->Dict.set(chainIdField.fieldName, s.matches(ChainId.schema->S.toUnknown))
        dict
      })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.entity>)
    }
    rowSchemaCache->Utils.WeakMap.set(entityConfig, schema)->ignore
    schema
  }

// How a batch of a Postgres table's rows crosses over: staged into an arena
// column by column, or rendered a parameter per cell when it has an array
// column.
type postgresTable = {staged: option<array<Staging.column>>}

// A table as the addon writes it: its handle, the columns a batch's rows carry
// in the order the addon expects them, and what each store that keeps it made
// of it.
type registered = {
  handle: int,
  home: StorageClient.store,
  table: Table.table,
  fields: array<Table.field>,
  postgres: option<postgresTable>,
  clickhouse: option<ClickHouse.table>,
}

%%private(
  let register = (
    client: StorageClient.t,
    ~table: Table.table,
    ~itemSchema: S.t<unknown>,
    ~postgres=true,
    ~clickhouse: option<StorageClient.clickHouseTable>=?,
    ~appendOnly=false,
    ~history=?,
  ): registered => {
    let fields = table->Table.schemaOrderedFields(~schema=itemSchema)
    let chainIdField = table->Table.getChainIdField
    let registered = client->StorageClient.registerTable({
      name: table.tableName,
      postgres: ?(
        postgres
          ? Some({
              Core.columns: table->Table.getFields->Array.map(pgColumnInput),
              writeColumns: fields->Array.map(Table.getPgDbFieldName),
              partitionByColumn: ?(chainIdField->Option.map(Table.getPgDbFieldName)),
              appendOnly,
              historyTable: ?history,
              chainIdColumn: ?switch history {
              | Some(_) => chainIdField->Option.map(Table.getPgDbFieldName)
              | None => None
              },
            })
          : None
      ),
      ?clickhouse,
    })
    {
      handle: registered.handle,
      home: registered.home,
      table,
      fields,
      postgres: registered.postgres->Option.map(({?kinds}): postgresTable => {
        staged: kinds->Option.map(kinds =>
          PgWriting.columns(fields, ~kinds=kinds->Array.map(Staging.kindOfOrdinal))
        ),
      }),
      // Named for where its rows go, which for an entity is its history table.
      clickhouse: registered.clickhouse->Option.map(
        ClickHouse.makeTable(
          ~handle=registered.handle,
          ~name=history->Option.getOr(table.tableName),
          _,
        ),
      ),
    }
  }
)

let registerEntity = (client, entityConfig: Internal.entityConfig) =>
  client->register(
    ~table=entityConfig.table,
    ~itemSchema=entityConfig->getRowSchema->S.toUnknown,
    ~postgres=entityConfig.storage.postgres,
    ~clickhouse=?entityConfig.storage.clickhouse
      ? Some(ClickHouse.entityTable(entityConfig))
      : None,
    ~history=EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    ),
  )

// A json column holds a document, which is as readily a string or a boolean as
// an object. By the time a parameter is rendered there is only the value to go
// on, and there a string is text and a boolean is `t` — neither of which the
// server will read back as the document it was. So the document becomes its own
// text here, where the column it belongs to is still known.
//
// JSON `null` is a document of its own, which a required column stores as one.
// A column that takes NULL keeps the two apart the other way: there `null` is
// the absent value, since only one of the two can survive the field's schema.
%%private(
  let renderDocument = (value, ~isNullable) =>
    switch value->(Utils.magic: unknown => Nullable.t<unknown>) {
    | Value(_) => value->Sql.stringifyDocument->(Utils.magic: string => unknown)
    | Null if !isNullable => "null"->(Utils.magic: string => unknown)
    | Null | Undefined => value
    }
)

// A list of documents is bound as an array whose elements are each their own
// document's text.
%%private(
  let renderDocuments = (columns: array<array<unknown>>, ~at: array<(int, Table.field)>) => {
    at->Array.forEach(((index, field)) => {
      let values = columns->Array.getUnsafe(index)
      for row in 0 to values->Array.length - 1 {
        let value = values->Array.getUnsafe(row)
        values->Array.setUnsafe(
          row,
          switch value->(Utils.magic: unknown => Nullable.t<array<unknown>>)->Nullable.toOption {
          | Some(documents) if field.isArray =>
            documents
            ->Array.map(document => document->renderDocument(~isNullable=true))
            ->(Utils.magic: array<unknown> => unknown)
          | _ => value->renderDocument(~isNullable=field.isNullable)
          },
        )
      }
    })
    columns
  }
)

// An item schema compiled for one table's columns: rows in, one array per
// column out. The values are validated by the type system on the way in, and a
// value its column cannot take is refused by the server, which says why.
type converters = Utils.WeakMap.t<S.t<unknown>, array<unknown> => array<array<unknown>>>
let arenaConverters: converters = Utils.WeakMap.make()
let cellConverters: converters = Utils.WeakMap.make()
let converterOf = (registered, ~forArena, ~itemSchema) => {
  let converters = forArena ? arenaConverters : cellConverters
  switch converters->Utils.WeakMap.get(itemSchema) {
  | Some(convert) => convert
  | None =>
    let documents =
      registered.fields->Array.filterMapWithIndex((field, index) =>
        field.fieldType === Table.Json ? Some((index, field)) : None
      )
    // Booleans travel as 1/0 and bigints as their digits, which is what an
    // arena's slots hold.
    let schema = forArena ? registered.table->Table.toDbSchema(~schema=itemSchema) : itemSchema
    let convert = S.compile(
      S.unnest(schema)
      ->S.preprocess(_ => {
        serializer: columns =>
          columns
          ->(Utils.magic: unknown => array<array<unknown>>)
          ->renderDocuments(~at=documents)
          ->(Utils.magic: array<array<unknown>> => unknown),
      })
      ->S.toUnknown,
      ~input=Value,
      ~output=Unknown,
      ~mode=Sync,
      ~typeValidation=false,
    )->(Utils.magic: (unknown => unknown) => array<unknown> => array<array<unknown>>)
    converters->Utils.WeakMap.set(itemSchema, convert)->ignore
    convert
  }
}

// Staging refuses a non-finite float for a staged table. A table bound a cell
// at a time has to refuse it too: the server would store it, and the field's
// schema would then refuse it on every load.
%%private(
  let refuseNonFinite = (values: array<array<unknown>>, ~fields: array<Table.field>) =>
    fields->Array.forEachWithIndex((field, index) =>
      if field.fieldType === Table.Number {
        let column = field->Table.getPgDbFieldName
        let check = (value: Nullable.t<float>) =>
          switch value {
          | Value(number) => number->Staging.finiteOrThrow(~column)->ignore
          | Null | Undefined => ()
          }
        values
        ->Array.getUnsafe(index)
        ->Array.forEach(value =>
          if field.isArray {
            switch value->(Utils.magic: unknown => Nullable.t<array<Nullable.t<float>>>) {
            | Value(elements) => elements->Array.forEach(check)
            | Null | Undefined => ()
            }
          } else {
            check(value->(Utils.magic: unknown => Nullable.t<float>))
          }
        )
      }
    )
)

// What a batch has laid out on its way to the addon: the staged handles, freed
// if the write never reaches it, and each store's time spent laying its rows
// out, which is part of writing to it.
type staged = {handles: array<int>, seconds: dict<float>}

let stagedFor = (staged, ~store, stage) => {
  let started = Performance.now()
  let result = stage()
  let name = store->storeName
  staged.seconds->Dict.set(
    name,
    staged.seconds->Dict.get(name)->Option.getOr(0.) +. started->Performance.secondsSince,
  )
  result
}

// A Postgres table's rows for a write. A staged batch is handed back by handle.
%%private(
  let rowsOrThrow = (
    client: StorageClient.t,
    registered,
    ~itemSchema,
    items: array<unknown>,
    ~staged: staged,
  ): StorageClient.rows =>
    staged->stagedFor(~store=Postgres, () => {
      let rows = items->Array.length
      try {
        switch registered.postgres {
        | Some({staged: Some(columns)}) =>
          let values = (registered->converterOf(~forArena=true, ~itemSchema))(items)
          let handle =
            client
            ->StorageClient.arena(~store=Postgres)
            ->PgWriting.stage(~table=registered.handle, ~columns, ~values, ~rows)
          staged.handles->Array.push(handle)
          ({staged: handle, rows}: StorageClient.rows)
        | Some({staged: None}) =>
          let values = (registered->converterOf(~forArena=false, ~itemSchema))(items)
          values->refuseNonFinite(~fields=registered.fields)
          {
            cells: values->Utils.Array.flatten->Sql.params,
            rows,
          }
        | None => JsError.throwWithMessage(`Postgres doesn't keep "${registered.table.tableName}"`)
        }
      } catch {
      | S.Raised(_) as exn =>
        throw(
          Persistence.StorageError({
            message: `Failed to convert items for table "${registered.table.tableName}"`,
            reason: exn,
          }),
        )
      | exn =>
        throw(
          Persistence.StorageError({
            message: `Failed to insert items into table "${registered.table.tableName}"`,
            reason: exn->Utils.prettifyExn,
          }),
        )
      }
    })
)

// Ids as the text their column reads them from.
let renderIds = (table: Table.table, ids: array<EntityId.t>) =>
  table
  ->Table.encodeIdsToJson(ids)
  ->(Utils.magic: JSON.t => array<unknown>)
  ->Array.map(Sql.render)

let bounds = (
  {sequence, byChain}: CheckpointSequence.checkpointBoundsByChain,
): StorageClient.bounds => {
  let (chainIds, checkpointIds) = byChain->Frontier.unnestParams
  {sequence, chainIds, checkpointIds}
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

let make = (
  ~client: StorageClient.t,
  ~logger: Logger.t,
  // The entities a load can name before initialize or resume has.
  ~entities: array<Internal.entityConfig>=[],
  // Where the effect cache is dumped to and uploaded from.
  ~cacheDir: option<NodeJs.Path.t>=?,
  // Decides how wide an address key is, both when the config's addresses are
  // encoded at initialize and when stored rows are grouped on resume.
  ~ecosystem: Ecosystem.name,
  // An `envio start --chain` process: builds and looks for a per-chain entity's
  // indexes on its own chains' partitions, never on the parent table, so no
  // build reaches into the rows a sibling process drives.
  ~isolated=false,
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

  // Every table is registered with the addon once, by name: the handle is what
  // an operation names it by.
  let registry: dict<registered> = Dict.make()
  let registered = (~table: Table.table, register) =>
    switch registry->Utils.Dict.dangerouslyGetNonOption(table.tableName) {
    | Some(registered) => registered
    | None =>
      let registered = register()
      registry->Dict.set(table.tableName, registered)
      registered
    }
  let entityTable = (entityConfig: Internal.entityConfig) =>
    registered(~table=entityConfig.table, () => client->registerEntity(entityConfig))
  let ownTable = (~table: Table.table, ~itemSchema: S.t<unknown>, ~appendOnly=?) =>
    registered(~table, () => client->register(~table, ~itemSchema, ~appendOnly?))
  let rawEventsTable = () =>
    ownTable(
      ~table=InternalTable.RawEvents.table,
      ~itemSchema=InternalTable.RawEvents.schema->S.toUnknown,
      ~appendOnly=true,
    )
  // Every cache table has the same two columns, whatever its effect's output.
  let cacheTable = (table: Table.table) =>
    ownTable(~table, ~itemSchema=Internal.cacheItemSchema->S.toUnknown)
  entities->Array.forEach(entityConfig => entityConfig->entityTable->ignore)
  let tableOf = (table: Table.table) =>
    switch registry->Utils.Dict.dangerouslyGetNonOption(table.tableName) {
    | Some(registered) => registered
    // An effect's cache is loaded before anything wrote or created it.
    | None if Internal.EffectCache.fromTableName(table.tableName)->Option.isSome =>
      cacheTable(table)
    | None => JsError.throwWithMessage(`The storage has no table "${table.tableName}".`)
    }

  // A per-chain entity's Postgres rows live in one partition per chain.
  let partitions = (entities: array<Internal.entityConfig>, ~chainIds) =>
    entities
    ->Array.filter(entityConfig =>
      entityConfig.storage.postgres && entityConfig.table->Table.getChainIdField->Option.isSome
    )
    ->Array.flatMap(entityConfig =>
      chainIds->Array.map((chainId): StorageClient.partition => {
        table: (entityConfig->entityTable).handle,
        chainId,
        name: partitionTableName(~entityConfig, ~chainId),
      })
    )

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
            let table = Internal.makeCacheTable(~effectName, ~scope=Chain(chainId))
            result
            ->Array.push((table, NodeJs.Path.join(entryPath, sub)->NodeJs.Path.toString))
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
        let table = Internal.makeCacheTable(~effectName, ~scope=CrossChain)
        result->Array.push((table, entryPath->NodeJs.Path.toString))->ignore
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
            entries->Array.map(((table, path)): StorageClient.cacheUpload => {
              table: (table->cacheTable).handle,
              path,
            }),
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
    ~entities=[],
    ~enums=[],
    ~contractMapping,
    ~envioInfo,
  ): Persistence.initialState => {
    let rowsByChain =
      chainConfigs->Array.map(chainConfig =>
        chainConfig->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      )

    await client->StorageClient.initialize({
      sequence: CheckpointSequence.fromEntities(entities),
      tables: [rawEventsTable().handle]->Array.concat(
        entities->Array.map(entityConfig => (entityConfig->entityTable).handle),
      ),
      partitions: entities->partitions(
        ~chainIds=chainConfigs->Array.map((chainConfig: Config.chain) => chainConfig.id),
      ),
      enums: enums->Array.map((enumConfig: Table.enumConfig<Table.enum>): StorageClient.enum => {
        name: enumConfig.name,
        variants: enumConfig.variants->(Utils.magic: array<Table.enum> => array<string>),
      }),
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
    switch await client->StorageClient.loadWhere(~table=(table->tableOf).handle, ~conditions) {
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

  let partitionChainIds = chainIds => isolated ? Some(chainIds) : None

  // The physical table a query index for `scope` is built on. A per-chain
  // entity's query carries the scope's chain id, so it is planned against that
  // chain's partition, which an index on the parent covers by cascading.
  let queryTableName = (~entityConfig: Internal.entityConfig, ~scope: Internal.chainScope) =>
    switch scope {
    | Chain(chainId) =>
      indexTableNames(
        entityConfig,
        ~partitionChainIds=partitionChainIds([chainId]),
      )->Array.getUnsafe(0)
    | CrossChain => entityConfig.table.tableName
    }

  let ensureQueryIndexes = async (
    ~entityConfig: Internal.entityConfig,
    ~scope: Internal.chainScope,
    ~filters: array<EntityFilter.t>,
  ) =>
    switch client->StorageClient.ensureQueryIndexes(
      (entityConfig->entityTable).handle,
      queryTableName(~entityConfig, ~scope),
      filterColumns(~table=entityConfig.table, ~filters),
    ) {
    | Value(building) => await building
    | Null => ()
    }

  let loadFieldBloom = async (
    ~entityConfig: Internal.entityConfig,
    ~scope: Internal.chainScope,
    ~fieldName,
    ~minCapacity,
  ) =>
    if !entityConfig.storage.postgres {
      None
    } else {
      let table = entityConfig.table
      let column = (table->Table.queryFields->Dict.getUnsafe(fieldName)).pgDbFieldName
      let (chainColumn, chainId) = switch (scope, table->Table.getChainIdField) {
      | (Chain(chainId), Some(field)) => (Some(field->Table.getPgDbFieldName), Some(chainId))
      | _ => (None, None)
      }
      let {words, count} = await client->StorageClient.loadColumnBloom(
        (entityConfig->entityTable).handle,
        queryTableName(~entityConfig, ~scope),
        column,
        chainColumn,
        chainId,
        minCapacity,
      )
      // The bytes are copied into words of their own: the buffer napi hands
      // over needn't start on a word boundary.
      let bits = Uint32Array.fromLength(words->TypedArray.byteLength / 4)
      Uint8Array.fromBuffer(bits->TypedArray.buffer)->TypedArray.setArray(
        words->(Utils.magic: Uint8Array.t => array<int>),
      )
      Some((bits, count))
    }

  let schemaIndexes = (~entities: array<Internal.entityConfig>, ~chainIds) =>
    getSchemaIndexes(
      ~entities=entities->Array.filter((e: Internal.entityConfig) => e.storage.postgres),
      ~partitionChainIds=?partitionChainIds(chainIds),
    )->Array.map(IndexDefinition.toInput)

  // Runs on a resumed indexer that is already ready, so handlers may be issuing
  // getWhere queries alongside it. Nothing here writes `ready_at` — the chains
  // already carry theirs.
  let ensureSchemaIndexes = (~entities, ~chainIds) =>
    client->StorageClient.ensureSchemaIndexes(schemaIndexes(~entities, ~chainIds))

  let finalizeBackfill = (~entities, ~chainIds, ~readyAt: Date.t) =>
    client->StorageClient.finalizeBackfill(
      schemaIndexes(~entities, ~chainIds),
      chainIds,
      readyAt->Date.getTime,
    )

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

  let addChain = (~chainConfig: Config.chain, ~entities, ~contractMapping) =>
    client->StorageClient.addChain({
      chain: chainConfig->toChainConfig,
      partitions: entities->partitions(~chainIds=[chainConfig.id]),
      addresses: chainConfig
      ->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      ->addressColumns,
    })

  let resumeInitialState = async (
    ~entities: array<Internal.entityConfig>,
    ~chainIds,
    ~contractMapping,
  ): Persistence.initialState => {
    let (cache, resumed) = await Promise.all2((
      restoreEffectCache(~withUpload=false),
      client->StorageClient.resume({
        sequence: CheckpointSequence.fromEntities(entities),
        tables: entities->Array.map(entityConfig => (entityConfig->entityTable).handle),
        chainIds,
      }),
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
      stored->Array.map(((id, chain)) => (id, chain.checkpointId->BigInt.fromStringOrThrow)),
    )
    let reorgCheckpoints = resumed.reorgCheckpoints->Array.map((
      checkpoint
    ): Internal.reorgCheckpoint => {
      checkpointId: checkpoint.id->BigInt.fromStringOrThrow,
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

  let pruneStaleEntityHistory = (~entityConfig, ~safeCheckpoints) =>
    client->StorageClient.pruneHistory((entityConfig->entityTable).handle, safeCheckpoints->bounds)

  let getRollbackTargetCheckpoint = async (~reorgChainId, ~lastKnownValidBlockNumber, ~sequence) =>
    (
      await client->StorageClient.rollbackTargetCheckpoint(
        reorgChainId,
        lastKnownValidBlockNumber,
        sequence,
      )
    )
    ->Nullable.toOption
    ->Option.map(BigInt.fromStringOrThrow)

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
      (entityConfig->entityTable).handle,
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

  // One write group's changes, laid out for every store that keeps the entity:
  // for Postgres the latest change of each id for the entity table, and every
  // change for its history; for ClickHouse every change as a history row.
  let entityWrite = (
    {entityConfig, scope, changes, shouldSaveHistory}: Persistence.updatedEntity,
    ~rollback: option<Persistence.rollback>,
    ~config: Config.t,
    ~staged,
  ): StorageClient.entityWrite => {
    let table = entityConfig->entityTable

    let chainIdStamp = switch (entityConfig.table->Table.getChainIdField, scope) {
    | (Some(field), Internal.Chain(chainId)) => Some((field, chainId))
    | _ => None
    }

    let postgresWrite = (): StorageClient.postgresEntityWrite => {
      // Every row in this group belongs to the group's scope, so the chain id
      // is stamped once here instead of being looked up per row downstream.
      let stamped = switch chainIdStamp {
      | Some((field, chainId)) =>
        changes->Array.map(change =>
          switch change {
          | Change.Set(set) =>
            Change.Set({
              ...set,
              entity: set.entity->Internal.stampChainId(~fieldName=field.fieldName, ~chainId),
            })
          | Delete(_) => change
          }
        )
      | None => changes
      }

      // The rollback-diff change is written to the entity table only, never the
      // history table; when present it is an id's oldest change.
      let diffCheckpointId =
        rollback->Option.flatMap(r =>
          config.checkpointSequence->CheckpointSequence.findForScope(r.diffFrontier, ~scope)
        )

      let historySets = []
      let historySetCheckpointIds = []
      let historyDeleteIds = []
      let historyDeleteCheckpointIds = []
      let idsWithDiff = Utils.Set.make()

      // Each id's latest change (the last one seen) and, when saving history,
      // every change but the diff for the history table. Keyed by the id's
      // string key, while what goes to SQL keeps the real id so it serializes
      // with the id column's type.
      let latestChangeById = Dict.make()
      let orderedIds = []
      stamped->Array.forEach(change => {
        let entityId = change->Change.getEntityId
        let entityKey = entityId->EntityId.toKey
        if latestChangeById->Utils.Dict.dangerouslyGetNonOption(entityKey)->Option.isNone {
          orderedIds->Array.push(entityId)
        }
        latestChangeById->Dict.set(entityKey, change)
        if shouldSaveHistory {
          if Some(change->Change.getCheckpointId) === diffCheckpointId {
            idsWithDiff->Utils.Set.add(entityKey)->ignore
          } else {
            switch change {
            | Delete({entityId, checkpointId}) =>
              historyDeleteIds->Array.push(entityId)
              historyDeleteCheckpointIds->Array.push(checkpointId->BigInt.toString)
            | Set({entity, checkpointId}) =>
              historySets->Array.push(entity)
              historySetCheckpointIds->Array.push(checkpointId->BigInt.toString)
            }
          }
        }
      })

      let sets = []
      let deletes = []
      let backfill = []
      orderedIds->Array.forEach(entityId => {
        let entityKey = entityId->EntityId.toKey
        switch latestChangeById->Dict.getUnsafe(entityKey) {
        | Set({entity}) => sets->Array.push(entity)
        | Delete({entityId}) => deletes->Array.push(entityId)
        }

        // An id needs a history backfill iff none of its changes is the diff.
        if shouldSaveHistory && !(idsWithDiff->Utils.Set.has(entityKey)) {
          backfill->Array.push(entityId)
        }
      })

      let rowsOf = entities =>
        entities->Utils.Array.notEmpty
          ? Some(
              client->rowsOrThrow(
                table,
                ~itemSchema=entityConfig->getRowSchema->S.toUnknown,
                entities->(Utils.magic: array<Internal.entity> => array<unknown>),
                ~staged,
              ),
            )
          : None
      {
        sets: ?rowsOf(sets),
        deletes: entityConfig.table->renderIds(deletes),
        history: ?(
          shouldSaveHistory
            ? Some(
                (
                  {
                    backfill: entityConfig.table->renderIds(backfill),
                    sets: ?rowsOf(historySets),
                    setCheckpointIds: historySetCheckpointIds,
                    deleteIds: entityConfig.table->renderIds(historyDeleteIds),
                    deleteCheckpointIds: historyDeleteCheckpointIds,
                  }: StorageClient.historyWrite
                ),
              )
            : None
        ),
      }
    }

    {
      table: table.handle,
      chainId: ?(chainIdStamp->Option.map(((_, chainId)) => chainId)),
      postgres: ?(table.postgres->Option.map(_ => postgresWrite())),
      clickhouse: ?switch (table.clickhouse, changes) {
      | (_, []) | (None, _) => None
      | (Some(chTable), _) =>
        let handle = staged->stagedFor(~store=ClickHouse, () =>
          client
          ->StorageClient.arena(~store=ClickHouse)
          ->ClickHouse.stageChangesOrThrow(chTable, ~entityConfig, ~scope, ~changes)
        )
        staged.handles->Array.push(handle)
        Some(handle)
      },
    }
  }

  let writeBatch = async (
    ~batch: Batch.t,
    ~rollback: option<Persistence.rollback>,
    ~config: Config.t,
    ~allEntities: array<Internal.entityConfig>,
    ~updatedEffectsCache: array<Persistence.updatedEffectCache>,
    ~updatedEntities: array<Persistence.updatedEntity>,
    ~registeredAddresses: array<AddressRows.staged>,
    ~chainMetaData,
    ~onWrite,
  ) => {
    let (frontierChainIds, frontierCheckpointIds) =
      Persistence.writtenFrontier(~batch, ~rollback)->Frontier.unnestParams

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

    let staged = {handles: [], seconds: Dict.make()}
    let input: StorageClient.batch = try {
      rollback: ?(
        rollback->Option.map(({
          floors,
          rolledBackAddresses,
          progressedChains,
          diffCheckpoints,
        }): StorageClient.rollbackWrite => {
          bounds: floors.checkpointBounds->bounds,
          tables: allEntities->Array.map(entityConfig => (entityConfig->entityTable).handle),
          progress: progressedChains->Array.map(progress),
          removedAddresses: {
            chainIds: rolledBackAddresses->Array.map(key => key.chainId),
            addresses: rolledBackAddresses->Array.map(key => key.address),
            contractIds: rolledBackAddresses->Array.map(key => key.contractId),
          },
          diffCheckpoints: diffCheckpoints->Array.map((diff): StorageClient.diffCheckpoint => {
            chainId: diff.chainId,
            checkpointId: diff.checkpointId->BigInt.toString,
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
          ? {
              let table = rawEventsTable()
              Some(
                (
                  {
                    table: table.handle,
                    rows: client->rowsOrThrow(
                      table,
                      ~itemSchema=InternalTable.RawEvents.schema->S.toUnknown,
                      rawEvents->(Utils.magic: array<Internal.rawEvent> => array<unknown>),
                      ~staged,
                    ),
                  }: StorageClient.tableWrite
                ),
              )
            }
          : None
      ),
      entities: updatedEntities->Array.map(update =>
        update->entityWrite(~rollback, ~config, ~staged)
      ),
      chainMeta: chainMetaData->Option.mapOr([], chainMeta),
      addresses: registeredAddresses->Array.map(staged => staged.row)->addressColumns,
      frontier: {chainIds: frontierChainIds, checkpointIds: frontierCheckpointIds},
      // A checkpoint anchors the history its chain keeps, which the batch
      // decides chain by chain.
      checkpoints: {
        ids: batch.checkpointIds->Array.map(id => id->BigInt.toString),
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
        let registered = table->cacheTable
        {
          table: registered.handle,
          create: shouldInitialize,
          rows: client->rowsOrThrow(
            registered,
            ~itemSchema=itemSchema->S.toUnknown,
            items->(Utils.magic: array<Internal.effectCacheItem> => array<unknown>),
            ~staged,
          ),
        }
      }),
    } catch {
    | exn =>
      client->StorageClient.discardStaged(staged.handles)
      throw(exn)
    }

    let timings = try await client->StorageClient.writeBatch(input) catch {
    | exn =>
      // Batches the addon never took, because it refused the call itself.
      client->StorageClient.discardStaged(staged.handles)
      throw(exn->storageErrorOf)
    }
    timings->Array.forEach(({store, seconds}) => {
      let name = store->storeName
      onWrite(
        ~storage=name,
        ~timeSeconds=seconds +. staged.seconds->Dict.get(name)->Option.getOr(0.),
      )
    })
  }

  let close = () => client->StorageClient.close

  {
    name: postgresName,
    entityStoreName: entityConfig => (entityConfig->entityTable).home->storeName,
    holding,
    initialize,
    readStoredConfig,
    addChain,
    resumeInitialState,
    loadOrThrow,
    ensureQueryIndexes,
    loadFieldBloom,
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
    ~chainIdMode=config.chainIdMode,
    ~postgres=postgresOptions(~pgSchema, ~isHasuraEnabled, ~maxConnections?),
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
    ~entities=config.userEntities,
    ~cacheDir?,
    ~ecosystem=config.ecosystem.name,
    ~isolated=config.isolated,
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
