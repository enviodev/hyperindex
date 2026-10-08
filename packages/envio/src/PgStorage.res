// The metric label, the `storage` field on this backend's logs, and the
// storage record's own name are all the same string.
let storageName = "postgres"

let formatSeconds = seconds => (Math.round(seconds *. 100.) /. 100.)->Float.toString

// Every index build blocks writes to its table for as long as it runs, and on a
// large database that is not quick. Both build paths say so up front, so a
// stalled-looking indexer is explainable from the logs alone.
let slowOnLargeDatabaseNotice = "This can take a long time on a large database."

let logIndexEvent = (~pgSchema, event: PgClient.indexEvent) =>
  switch event {
  | Invalid({names}) =>
    Logging.warn({
      "storage": storageName,
      "msg": `Ignoring invalid PostgreSQL indexes in schema "${pgSchema}". They can't serve queries, so the indexer builds its own alongside them.`,
      "indexes": names,
    })
  | Planned({declared, missing, rebuilt}) =>
    if rebuilt->Utils.Array.notEmpty {
      Logging.warn({
        "storage": storageName,
        "msg": `PostgreSQL reports ${rebuilt
          ->Array.length
          ->Int.toString} of the indexer's own indexes as invalid, so they can't serve queries. Rebuilding them.`,
        "indexes": rebuilt,
      })
    }
    switch missing {
    // The line that matters next is the indexer reporting itself ready, which
    // finalization logs.
    | [] =>
      Logging.info({
        "storage": storageName,
        "msg": `All ${declared->Int.toString} schema indexes are already in place. Marking the indexer ready.`,
      })
    | _ =>
      Logging.info({
        "storage": storageName,
        "msg": `Creating the ${missing
          ->Array.length
          ->Int.toString} remaining schema indexes before the indexer reports ready. Writes are paused until they are committed. ${slowOnLargeDatabaseNotice}`,
        "indexes": missing,
      })
    }
  | Building({purpose: Query, name, tableName, isRebuild}) =>
    Logging.info({
      "storage": storageName,
      "msg": `${isRebuild
          ? "Rebuilding unusable index"
          : "Creating index"} "${name}" to serve a getWhere query on "${tableName}". Writes to the table are paused until it completes. ${slowOnLargeDatabaseNotice}`,
    })
  | Building({purpose: Schema, name, isRebuild}) =>
    Logging.info({
      "storage": storageName,
      "msg": `${isRebuild
          ? "Rebuilding unusable index"
          : "Creating missing index"} "${name}" the schema promises but the database no longer has. Writes to the table are paused until it completes. ${slowOnLargeDatabaseNotice}`,
    })
  | Built({purpose, name, seconds}) =>
    Logging.info({
      "storage": storageName,
      "msg": `Index "${name}" is ready after ${seconds->formatSeconds}s.${switch purpose {
        | Query => " Resuming indexing."
        | Schema => ""
        }}`,
    })
  | Failed({purpose: Query, tableName, columns, error}) =>
    Logging.warn({
      "storage": storageName,
      "msg": `Failed to create an index on "${tableName}"(${columns
        ->Array.map(column => `"${column}"`)
        ->Array.joinUnsafe(", ")}) for a getWhere query. The query runs without it.`,
      "err": error,
    })
  | Failed({purpose: Schema, name, error}) =>
    Logging.warn({
      "storage": storageName,
      "msg": `Failed to restore the schema index "${name}". Queries relying on it run unindexed until the next restart.`,
      "err": error,
    })
  | ResyncFailed({name, error}) =>
    Logging.trace({
      "storage": storageName,
      "msg": `Could not re-read the index "${name}" after a failed build. The next attempt reads it again.`,
      "err": error,
    })
  | Committed({count, seconds}) =>
    Logging.info({
      "storage": storageName,
      "msg": `Committed ${count->Int.toString} schema indexes and the ready timestamp in ${seconds->formatSeconds}s.`,
    })
  }

// One client per storage: the schema and the chain-id mode it was created
// with decide every statement the addon builds.
let makeClient = (
  ~pgSchema=Env.Db.publicSchema,
  ~chainIdMode: ChainId.mode=Int32,
  ~isHasuraEnabled=false,
  ~maxConnections=Env.Db.maxConnections,
): Sql.t =>
  PgClient.make(
    {
      host: Env.Db.host,
      port: Env.Db.port,
      user: Env.Db.user,
      password: Env.Db.password,
      database: Env.Db.database,
      ssl: Env.Db.ssl->Sql.sslModeToString,
      maxConnections,
      pgSchema,
      chainIdMode: (chainIdMode :> string),
      isHasuraEnabled,
    },
    ~onIndexEvent=event => logIndexEvent(~pgSchema, event),
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

let makeLoadQuery = (~pgSchema, ~tableName, ~condition) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE ${condition};`
}

// Appends the filter's serialized field values to params (mutated in place)
// and returns the matching SQL condition referencing them by index.
// Field names are spliced as quoted identifiers only after the queryFields
// lookup proves they exist on the table (and they originate from
// codegen-validated schemas), so the interpolation can't be abused.
let makeFilterCondition = (
  ~filter: EntityFilter.t,
  ~table: Table.table,
  ~pgSchema,
  ~params: array<unknown>,
) => {
  // Filters reference fields by API name, while the SQL references columns
  // by their possibly renamed db names.
  let getQueryFieldOrThrow = fieldName =>
    switch table->Table.queryFields->Dict.get(fieldName) {
    | Some(queryField) => queryField
    | None =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage. The table doesn't have the field "${fieldName}".`,
          reason: Table.NonExistingTableField(fieldName),
        }),
      )
    }
  let serializeParamOrThrow = (
    ~queryField: Table.queryField,
    ~fieldName,
    ~fieldValue: unknown,
    ~isArray,
  ) => {
    let param = try fieldValue->S.reverseConvertOrThrow(
      isArray ? queryField.arrayFieldSchema : queryField.fieldSchema,
    ) catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by field "${fieldName}". Couldn't serialize provided value.`,
          reason: exn,
        }),
      )
    }
    params->Array.push(param)->ignore
    `$${params->Array.length->Int.toString}`
  }

  let condition = ref("")
  filter
  ->EntityFilter.entries
  ->Utils.Dict.forEachWithKey((operators, fieldName) => {
    let queryField = getQueryFieldOrThrow(fieldName)
    operators->Utils.Dict.forEachWithKey((fieldValue, operator) => {
      let column = `"${queryField.pgDbFieldName}"`
      let part = switch operator {
      // A per-chain entity's table is partitioned by its chain-id column, and
      // Postgres can only prune a plan it caches when that column is a constant
      // in the SQL. Bound, the cached plan has to keep every partition, and the
      // planner ends up throwing it away and re-planning on every execution
      // instead — measured at 315us per load against 218us with the id written
      // in, on 30 chains.
      //
      // The cost is that each chain gets its own query text, so Postgres caches
      // a prepared statement per (entity, chain, filter shape) rather than per
      // (entity, filter shape). Measured at ~8KB of plan cache each, which is
      // ~10MB per connection for 40 entities across 30 chains — accepted, since
      // the alternative is a cached plan that can't prune.
      //
      // `EntityFilter.scoped` is what puts this filter here, and the value is
      // range-checked to a non-negative safe integer, so it can carry nothing
      // but digits.
      | "_eq" if queryField.isChainId =>
        `${column} = ${fieldValue->ChainId.normalizeOrThrow->ChainId.toString}`
      // Postgres arrays are rectangular, so candidates for a list column can't
      // be bound as one array unless they all have the same length. One
      // equality per candidate doesn't care.
      | "_in" if queryField.isArray =>
        switch fieldValue->EntityFilter.asArray {
        | [] => "FALSE"
        | candidates =>
          `(${candidates
            ->Array.map(
              candidate =>
                `${column} = ${serializeParamOrThrow(
                    ~queryField,
                    ~fieldName,
                    ~fieldValue=candidate,
                    ~isArray=false,
                  )}`,
            )
            ->Array.join(" OR ")})`
        }
      | "_in" =>
        let param = serializeParamOrThrow(~queryField, ~fieldName, ~fieldValue, ~isArray=true)
        switch queryField.fieldType {
        // A bound array of strings is text[], which has no equality with an
        // enum. The insert casts the same way.
        | Enum({config}) => `${column} = ANY(${param}::TEXT[]::"${pgSchema}".${config.name}[])`
        | _ => `${column} = ANY(${param})`
        }
      | _ =>
        let sqlOperator = switch operator {
        | "_eq" => "="
        | "_gt" => ">"
        | "_lt" => "<"
        | "_gte" => ">="
        | "_lte" => "<="
        | _ =>
          throw(
            Persistence.StorageError({
              message: `Failed loading "${table.tableName}" from storage. Unknown filter operator "${operator}".`,
              reason: Utils.Error.make(`Unknown filter operator "${operator}"`),
            }),
          )
        }
        `${column} ${sqlOperator} ${serializeParamOrThrow(
            ~queryField,
            ~fieldName,
            ~fieldValue,
            ~isArray=false,
          )}`
      }
      condition := (condition.contents === "" ? part : condition.contents ++ " AND " ++ part)
    })
  })

  condition.contents
}

let makeLoadAllQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}";`
}

// A table as the addon writes it: its handle, and how a batch of its rows
// crosses over — staged into an arena column by column, or rendered a
// parameter per cell when it has an array column.
type registered = {
  handle: int,
  table: Table.table,
  // The columns a batch's rows carry, in the order the addon expects them.
  fields: array<Table.field>,
  staged: option<array<Staging.column>>,
}

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

let register = (
  sql: Sql.t,
  ~table: Table.table,
  ~itemSchema: S.t<unknown>,
  ~appendOnly=false,
  ~history=?,
): registered => {
  let fields = table->Table.schemaOrderedFields(~schema=itemSchema)
  let chainIdField = table->Table.getChainIdField
  let {handle, ?kinds} = sql->PgClient.registerTable({
    tableName: table.tableName,
    columns: table->Table.getFields->Array.map(pgColumnInput),
    writeColumns: fields->Array.map(Table.getPgDbFieldName),
    partitionByColumn: ?(chainIdField->Option.map(Table.getPgDbFieldName)),
    appendOnly,
    historyTable: ?history,
    chainIdColumn: ?switch history {
    | Some(_) => chainIdField->Option.map(Table.getPgDbFieldName)
    | None => None
    },
  })
  {
    handle,
    table,
    fields,
    staged: kinds->Option.map(kinds => PgWriting.columns(fields, ~kinds)),
  }
}

// An item schema compiled for one table's columns: rows in, one array per
// column out. The values are validated by the type system on the way in, and
// a value its column cannot take is refused by the server, which says why.
let converters: Utils.WeakMap.t<
  S.t<unknown>,
  array<unknown> => array<array<unknown>>,
> = Utils.WeakMap.make()
let converterOf = (registered, ~itemSchema) =>
  switch converters->Utils.WeakMap.get(itemSchema) {
  | Some(convert) => convert
  | None =>
    let documents =
      registered.fields->Array.filterMapWithIndex((field, index) =>
        field.fieldType === Table.Json ? Some((index, field)) : None
      )
    let schema = switch registered.staged {
    // Booleans travel as 1/0 and bigints as their digits, which is what the
    // arena's slots hold.
    | Some(_) => registered.table->Table.toDbSchema(~schema=itemSchema)
    | None => itemSchema
    }
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

// Lays rows out for the addon. A staged batch is handed back by handle, and
// recorded in `staged` so a write that fails before reaching the addon can free
// it.
let rowsOrThrow = (
  sql: Sql.t,
  registered,
  ~itemSchema,
  items: array<unknown>,
  ~staged: array<int>,
): PgClient.rows => {
  let rows = items->Array.length
  try {
    let values = (registered->converterOf(~itemSchema))(items)
    switch registered.staged {
    | Some(columns) =>
      let handle =
        sql
        ->PgClient.arena
        ->PgWriting.stage(~table=registered.handle, ~columns, ~values, ~rows)
      staged->Array.push(handle)
      {staged: handle, rows}
    | None => {
        cells: values->Utils.Array.flatten->Sql.params,
        rows,
      }
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
}

// Ids as the text their column reads them from.
let renderIds = (table: Table.table, ids: array<EntityId.t>) =>
  table
  ->Table.encodeIdsToJson(ids)
  ->(Utils.magic: JSON.t => array<unknown>)
  ->Array.map(Sql.render)

let sequenceName = (sequence: CheckpointSequence.t) =>
  switch sequence {
  | SharedAcrossChains => "SharedAcrossChains"
  | PerChain => "PerChain"
  }

let bounds = ({sequence, byChain}: CheckpointSequence.checkpointBoundsByChain): PgClient.bounds => {
  let (chainIds, checkpointIds) = byChain->Frontier.unnestParams
  {sequence: sequence->sequenceName, chainIds, checkpointIds}
}

let progress = (chain: InternalTable.Chains.progressedChain): PgClient.progress => {
  chainId: chain.chainId,
  progressBlock: chain.progressBlockNumber,
  progressBlockTime: ?chain.progressBlockTime,
  eventsProcessed: chain.totalEventsProcessed,
  sourceBlock: chain.sourceBlockNumber,
}

let addressColumns = (rows: array<AddressRows.row>): PgClient.addresses => {
  chainIds: rows->Array.map(row => row.chainId),
  addresses: rows->Array.map(row => row.address),
  contractIds: rows->Array.map(row => row.contractId),
  registrationBlocks: rows->Array.map(row => row.registrationBlock),
}

let toChainConfig = (chainConfig: Config.chain): PgClient.chainConfig => {
  id: chainConfig.id,
  ecosystem: (chainConfig.ecosystem: Ecosystem.name :> string),
  startBlock: chainConfig->Config.startBlockOrThrow,
  endBlock: ?chainConfig.endBlock,
  maxReorgDepth: chainConfig.maxReorgDepth,
}

// A failed statement crosses as what it was doing, with the server's error as
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

// The checkpoints a write inserts: every one the batch made, or those of the
// chains whose history it keeps.
type pickedCheckpoints = AllCheckpoints | CheckpointIndexes(array<int>)

let pickCheckpoints = (column, picked) =>
  switch picked {
  | AllCheckpoints => column
  | CheckpointIndexes(indexes) => indexes->Array.map(index => column->Array.getUnsafe(index))
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

// Same reason as above for the id-only rows: both rollback queries must yield
// ids in the entity's own representation, or the two halves of the diff would
// disagree (Postgres hands back a NUMERIC id as a string, not a bigint).
let rollbackRemovedIdSchema: Table.table => S.t<EntityId.t> = Utils.WeakMap.memoize(table =>
  S.object(s => s.field(Table.idFieldName, table->Table.getIdSchema))
)

let make = (
  ~pgSchema,
  ~chainIdMode: ChainId.mode=Int32,
  // Hasura cannot read a `numeric[]`, so a schema it tracks stores those as
  // `text[]` (issue #788).
  ~isHasuraEnabled=false,
  ~maxConnections=?,
  // A client of its own otherwise, created for `pgSchema`.
  ~sql: option<Sql.t>=?,
  // Where the effect cache is dumped to and uploaded from.
  ~cacheDir: option<NodeJs.Path.t>=?,
  // Decides how wide an address key is, both when the config's addresses are
  // encoded at initialize and when stored rows are grouped on resume.
  ~ecosystem: Ecosystem.name,
  ~sink: option<Sink.t>=?,
  // An `envio start --chain` process: builds and looks for a per-chain entity's
  // indexes on its own chains' partitions, never on the parent table, so no
  // build reaches into the rows a sibling process drives.
  ~isolated=false,
  ~onInitialize=?,
): Persistence.storage => {
  let sql = switch sql {
  | Some(sql) => sql
  | None => makeClient(~pgSchema, ~chainIdMode, ~isHasuraEnabled, ~maxConnections?)
  }
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
  // a write names it by.
  let registry: dict<registered> = Dict.make()
  let registered = (~table: Table.table, ~itemSchema, ~appendOnly=?, ~history=?) =>
    switch registry->Utils.Dict.dangerouslyGetNonOption(table.tableName) {
    | Some(registered) => registered
    | None =>
      let registered = sql->register(~table, ~itemSchema, ~appendOnly?, ~history?)
      registry->Dict.set(table.tableName, registered)
      registered
    }
  let entityTable = (entityConfig: Internal.entityConfig) =>
    registered(
      ~table=entityConfig.table,
      ~itemSchema=entityConfig->getRowSchema->S.toUnknown,
      ~history=EntityHistory.historyTableName(
        ~entityName=entityConfig.name,
        ~entityIndex=entityConfig.index,
      ),
    )
  let rawEventsTable = () =>
    registered(
      ~table=InternalTable.RawEvents.table,
      ~itemSchema=InternalTable.RawEvents.schema->S.toUnknown,
      ~appendOnly=true,
    )
  // Every cache table has the same two columns, whatever its effect's output.
  let cacheTable = (table: Table.table) =>
    registered(~table, ~itemSchema=Internal.cacheItemSchema->S.toUnknown)

  // A per-chain entity's rows live in one partition per chain.
  let partitions = (entities: array<Internal.entityConfig>, ~chainIds) =>
    entities
    ->Array.filter(entityConfig => entityConfig.table->Table.getChainIdField->Option.isSome)
    ->Array.flatMap(entityConfig =>
      chainIds->Array.map((chainId): PgClient.partition => {
        table: (entityConfig->entityTable).handle,
        chainId,
        name: partitionTableName(~entityConfig, ~chainId),
      })
    )

  let isInitialized = () => sql->PgClient.isInitialized

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
      | [] => Logging.info("No saved effect cache to load from .envio/cache.")
      | entries =>
        try {
          await sql->PgClient.uploadEffectCache(
            entries->Array.map(((table, path)): PgClient.cacheUpload => {
              table: (table->cacheTable).handle,
              path,
            }),
          )
          Logging.info("Successfully uploaded cache.")
        } catch {
        | exn =>
          Logging.errorWithExn(
            exn->Utils.prettifyExn,
            "Failed to upload cache, continuing without it.",
          )
        }
      }
    }

    let cache = Dict.make()
    (await sql->PgClient.effectCacheTables)->Array.forEach(({tableName, rows}) => {
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
    // PG owns tables only for entities that opted into Postgres; the sink
    // picks its own out of the full list.
    let pgEntities = entities->Array.filter((e: Internal.entityConfig) => e.storage.postgres)

    // Refused before anything is touched: initializing drops the schema.
    let isEmptySchema = await sql->PgClient.checkSchemaForInitialize

    switch sink {
    | Some(sink) => await sink.initialize(~entities)
    | None => ()
    }

    let rowsByChain =
      chainConfigs->Array.map(chainConfig =>
        chainConfig->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      )

    await sql->PgClient.initialize({
      sequence: CheckpointSequence.fromEntities(entities)->sequenceName,
      isEmptySchema,
      tables: [rawEventsTable().handle]->Array.concat(
        pgEntities->Array.map(entityConfig => (entityConfig->entityTable).handle),
      ),
      partitions: pgEntities->partitions(
        ~chainIds=chainConfigs->Array.map((chainConfig: Config.chain) => chainConfig.id),
      ),
      enums: enums->Array.map((enumConfig: Table.enumConfig<Table.enum>): PgClient.enum => {
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
    let params = []
    let condition = makeFilterCondition(~filter, ~table, ~pgSchema, ~params)
    switch await sql->Sql.query(
      makeLoadQuery(~pgSchema, ~tableName=table.tableName, ~condition),
      ~params,
    ) {
    | exception exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by condition: ${condition}`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(table->Table.pgEntityRowsSchema) catch {
      | exn =>
        throw(
          Persistence.StorageError({
            message: `Failed to parse "${table.tableName}" loaded from storage by condition: ${condition}`,
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
    switch sql->PgClient.ensureQueryIndexes(
      queryTableName(~entityConfig, ~scope),
      filterColumns(~table=entityConfig.table, ~filters),
    ) {
    | Value(building) => await building
    | Null => ()
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
    sql->PgClient.ensureSchemaIndexes(schemaIndexes(~entities, ~chainIds))

  let finalizeBackfill = (~entities, ~chainIds, ~readyAt: Date.t) =>
    sql->PgClient.finalizeBackfill(
      schemaIndexes(~entities, ~chainIds),
      chainIds,
      readyAt->Date.getTime,
    )

  let dumpEffectCache = async () => {
    try {
      let tables = (await sql->PgClient.effectCacheTables)->Array.filter(({rows}) => rows > 0)
      if tables->Utils.Array.notEmpty {
        Logging.info(
          `Dumping cache: ${tables
            ->Array.map(({tableName, rows}) => tableName ++ " (" ++ rows->Int.toString ++ " rows)")
            ->Array.joinUnsafe(", ")}`,
        )
        await sql->PgClient.dumpEffectCache(
          tables->Array.filterMap(({tableName}) =>
            Internal.EffectCache.fromTableName(tableName)->Option.map(((
              effectName,
              scope,
            )): PgClient.cacheDump => {
              tableName,
              // Chain-scoped caches dump into a directory of their chain's.
              path: NodeJs.Path.join(
                cacheDirPath,
                Internal.EffectCache.toCachePath(~effectName, ~scope),
              )->NodeJs.Path.toString,
            })
          ),
        )
        Logging.info(`Successfully dumped cache to ${cacheDirPath->NodeJs.Path.toString}`)
      }
    } catch {
    | exn => Logging.errorWithExn(exn->Utils.prettifyExn, `Failed to dump cache.`)
    }
  }

  let readAddressRows = (result): array<AddressRows.row> =>
    sql->PgClient.read(result)->(Utils.magic: array<dict<unknown>> => array<AddressRows.row>)

  let readStoredConfig = async (): ResumePlan.stored => {
    let stored = await sql->PgClient.readStoredConfig
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
    sql->PgClient.addChain({
      chain: chainConfig->toChainConfig,
      partitions: entities
      ->Array.filter((entityConfig: Internal.entityConfig) => entityConfig.storage.postgres)
      ->partitions(~chainIds=[chainConfig.id]),
      addresses: chainConfig
      ->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      ->addressColumns,
    })

  let resumeInitialState = async (
    ~entities,
    ~chainIds,
    ~contractMapping,
  ): Persistence.initialState => {
    let (cache, resumed) = await Promise.all2((
      restoreEffectCache(~withUpload=false),
      sql->PgClient.resume,
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

    // Resume sink if present - needed to rollback any reorg changes
    switch sink {
    | Some(sink) => await sink.resume(~frontier=checkpointFrontier, ~chains, ~entities)
    | None => ()
    }

    {
      cleanRun: false,
      reorgCheckpoints,
      cache,
      chains,
      checkpointFrontier,
      contractMapping,
    }
  }

  let reset = () => sql->PgClient.reset

  let chainMeta = (chainsData: dict<InternalTable.Chains.metaFields>) =>
    chainsData
    ->Dict.toArray
    ->Array.map(((chainId, meta)): PgClient.chainMeta => {
      chainId: chainId->ChainId.normalizeOrThrow,
      firstEventBlock: ?(meta.firstEventBlockNumber->Null.toOption),
      bufferBlock: meta.latestFetchedBlockNumber,
      readyAt: ?(meta.timestampCaughtUpToHeadOrEndblock->Null.toOption->Option.map(Date.getTime)),
      isHyperSync: meta.isHyperSync,
    })

  let setChainMeta = chainsData =>
    sql
    ->PgClient.setChainMeta(chainsData->chainMeta)
    ->Promise.thenResolve(_ => %raw(`undefined`))

  let pruneStaleCheckpoints = (~safeCheckpoints) =>
    sql->PgClient.pruneCheckpoints(safeCheckpoints->bounds)

  let pruneStaleEntityHistory = (~entityConfig, ~safeCheckpoints) =>
    sql->PgClient.pruneHistory((entityConfig->entityTable).handle, safeCheckpoints->bounds)

  let getRollbackTargetCheckpoint = async (~reorgChainId, ~lastKnownValidBlockNumber) =>
    (await sql->PgClient.rollbackTargetCheckpoint(reorgChainId, lastKnownValidBlockNumber))
    ->Nullable.toOption
    ->Option.map(BigInt.fromStringOrThrow)

  let getRollbackProgressDiff = async (~floors: RollbackFloors.t) =>
    (await sql->PgClient.rollbackProgressDiff(floors.checkpointBounds->bounds))->Array.map(diff =>
      {
        "chain_id": diff.chainId->ChainId.normalizeOrThrow,
        "events_processed_diff": diff.eventsProcessed,
        "new_progress_block_number": diff.progressBlock,
      }
    )

  let getRollbackData = async (~entityConfig: Internal.entityConfig, ~floors: RollbackFloors.t) => {
    let {removed, restored} = await sql->PgClient.rollbackData(
      (entityConfig->entityTable).handle,
      floors.checkpointBounds->bounds,
    )
    let removedIdRows = try sql->PgClient.read(removed) catch {
    | exn =>
      sql->PgClient.releaseResult(restored.handle, [])
      throw(exn)
    }
    let rollbackRows = sql->PgClient.read(restored)

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

  // One write group's changes, laid out for the addon: the latest change of
  // each id for the entity table, and every change for its history.
  let entityWrite = (
    {entityConfig, scope, changes, shouldSaveHistory}: Persistence.updatedEntity,
    ~rollback: option<Persistence.rollback>,
    ~config: Config.t,
    ~staged,
  ): PgClient.entityWrite => {
    let table = entityConfig->entityTable

    // Every row in this group belongs to the group's scope, so the chain id
    // is stamped once here instead of being looked up per row downstream.
    let scopeChainId = switch scope {
    | Internal.CrossChain => None
    | Chain(chainId) => Some(chainId)
    }
    let changes = switch (entityConfig.table->Table.getChainIdField, scopeChainId) {
    | (Some(field), Some(chainId)) =>
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
    | _ => changes
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
    changes->Array.forEach(change => {
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
            sql->rowsOrThrow(
              table,
              ~itemSchema=entityConfig->getRowSchema->S.toUnknown,
              entities->(Utils.magic: array<Internal.entity> => array<unknown>),
              ~staged,
            ),
          )
        : None
    {
      table: table.handle,
      chainId: ?switch (entityConfig.table->Table.getChainIdField, scopeChainId) {
      | (Some(_), Some(chainId)) => Some(chainId)
      | _ => None
      },
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
                }: PgClient.historyWrite
              ),
            )
          : None
      ),
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
    ~sinkPromise: option<promise<option<exn>>>,
    ~chainMetaData,
  ) => {
    // A checkpoint anchors the history its chain keeps, so the batch's
    // decision picks the checkpoints chain by chain.
    let pickedCheckpoints = {
      let indexes =
        batch.checkpointChainIds->Array.filterMapWithIndex((chainId, index) =>
          batch.history->HistoryPolicy.forChain(chainId) ? Some(index) : None
        )
      if indexes->Array.length === batch.checkpointIds->Array.length {
        AllCheckpoints
      } else {
        CheckpointIndexes(indexes)
      }
    }
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

    let staged = []
    let input: PgClient.batch = try {
      rollback: ?(
        rollback->Option.map(({
          floors,
          rolledBackAddresses,
          progressedChains,
        }): PgClient.rollbackWrite => {
          bounds: floors.checkpointBounds->bounds,
          // Postgres owns history tables only for Postgres-backed entities.
          histories: allEntities
          ->Array.filter(entityConfig => entityConfig.storage.postgres)
          ->Array.map(entityConfig => (entityConfig->entityTable).handle),
          progress: progressedChains->Array.map(progress),
          removedAddresses: {
            chainIds: rolledBackAddresses->Array.map(key => key.chainId),
            addresses: rolledBackAddresses->Array.map(key => key.address),
            contractIds: rolledBackAddresses->Array.map(key => key.contractId),
          },
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
                    rows: sql->rowsOrThrow(
                      table,
                      ~itemSchema=InternalTable.RawEvents.schema->S.toUnknown,
                      rawEvents->(Utils.magic: array<Internal.rawEvent> => array<unknown>),
                      ~staged,
                    ),
                  }: PgClient.rawEventsWrite
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
      checkpoints: {
        ids: batch.checkpointIds
        ->pickCheckpoints(pickedCheckpoints)
        ->Array.map(id => id->BigInt.toString),
        chainIds: batch.checkpointChainIds->pickCheckpoints(pickedCheckpoints),
        blockNumbers: batch.checkpointBlockNumbers->pickCheckpoints(pickedCheckpoints),
        blockHashes: batch.checkpointBlockHashes->pickCheckpoints(pickedCheckpoints),
        eventsProcessed: batch.checkpointEventsProcessed->pickCheckpoints(pickedCheckpoints),
      },
      // Never rolled back, so written outside the batch's transaction.
      effectCaches: updatedEffectsCache->Array.map(({
        table,
        itemSchema,
        items,
        shouldInitialize,
      }): PgClient.tableWrite => {
        let registered = table->cacheTable
        {
          table: registered.handle,
          create: shouldInitialize,
          rows: sql->rowsOrThrow(
            registered,
            ~itemSchema=itemSchema->S.toUnknown,
            items->(Utils.magic: array<Internal.effectCacheItem> => array<unknown>),
            ~staged,
          ),
        }
      }),
    } catch {
    | exn =>
      sql->PgClient.discardStaged(staged)
      throw(exn)
    }

    try await sql->PgClient.writeBatch(
      input,
      sinkPromise
      ->Option.map(sinkPromise => sinkPromise->Promise.thenResolve(Option.isNone))
      ->Null.fromOption,
    ) catch {
    | exn =>
      // Batches the addon never took, because it refused the call itself.
      sql->PgClient.discardStaged(staged)
      // A batch the sink refused is rolled back, and the sink's own error is
      // the one that says why. Any other failure is Postgres's, reported as is.
      switch (exn->Utils.exnMessage, sinkPromise) {
      | (Some("SinkFailed"), Some(sinkPromise)) =>
        switch await sinkPromise {
        | Some(sinkExn) => throw(sinkExn)
        | None => throw(exn)
        }
      | _ => throw(exn->storageErrorOf)
      }
    }
  }

  let writeBatchMethod = async (
    ~batch,
    ~rollback,
    ~config,
    ~allEntities,
    ~updatedEffectsCache,
    ~updatedEntities,
    ~registeredAddresses,
    ~chainMetaData,
    ~onWrite,
  ) => {
    let pgUpdates = []
    let chUpdates = []
    for i in 0 to updatedEntities->Array.length - 1 {
      let update = updatedEntities->Array.getUnsafe(i)
      let {entityConfig}: Persistence.updatedEntity = update
      if entityConfig.storage.postgres {
        pgUpdates->Array.push(update)
      }
      if entityConfig.storage.clickhouse {
        chUpdates->Array.push(update)
      }
    }

    let sinkPromise = switch sink {
    | Some(sink) => {
        let timerRef = Performance.now()
        Some(
          sink.writeBatch(
            ~batch,
            ~diffCheckpoints=switch (rollback: option<Persistence.rollback>) {
            | Some({diffCheckpoints}) => diffCheckpoints
            | None => []
            },
            ~updatedEntities=chUpdates,
          )
          ->Promise.thenResolve(_ => {
            onWrite(~storage=sink.name, ~timeSeconds=timerRef->Performance.secondsSince)
            None
          })
          // Otherwise it fails with unhandled exception
          ->Utils.Promise.catchResolve(exn => Some(exn)),
        )
      }
    | None => None
    }

    let primaryTimerRef = Performance.now()
    await writeBatch(
      ~batch,
      ~rollback,
      ~config,
      ~allEntities,
      ~updatedEffectsCache,
      ~updatedEntities=pgUpdates,
      ~registeredAddresses,
      ~sinkPromise,
      ~chainMetaData,
    )
    onWrite(~storage=storageName, ~timeSeconds=primaryTimerRef->Performance.secondsSince)
  }

  let close = () => sql->Sql.close

  {
    name: storageName,
    isInitialized,
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
    writeBatch: writeBatchMethod,
    close,
  }
}

let makeStorageFromEnv = (
  ~config: Config.t,
  ~pgSchema=Env.Db.publicSchema,
  ~isHasuraEnabled=Env.Hasura.enabled,
  ~maxConnections=?,
  ~cacheDir=?,
) => {
  make(
    ~pgSchema,
    ~chainIdMode=config.chainIdMode,
    ~isHasuraEnabled,
    ~maxConnections?,
    ~cacheDir?,
    ~ecosystem=config.ecosystem.name,
    ~isolated=config.isolated,
    ~sink=?{
      // Internally ClickHouse storage is implemented as a sync of the
      // Postgres storage. Required env vars are validated here only when
      // the user opts in via `storage.clickhouse: true` in config.yaml.
      if config.storage.clickhouse {
        let host = Env.ClickHouse.host()
        let username = Env.ClickHouse.username()
        let password = Env.ClickHouse.password()
        let database = Env.ClickHouse.database()
        let missing = []
        let checkEnv = (opt, name) =>
          switch opt {
          | Some(_) => ()
          | None => missing->Array.push(name)->ignore
          }
        host->checkEnv("ENVIO_CLICKHOUSE_HOST")
        username->checkEnv("ENVIO_CLICKHOUSE_USERNAME")
        password->checkEnv("ENVIO_CLICKHOUSE_PASSWORD")
        database->checkEnv("ENVIO_CLICKHOUSE_DATABASE")
        if missing->Array.length > 0 {
          JsError.throwWithMessage(
            `ClickHouse storage is enabled but required env vars are not set: ${missing->Array.joinUnsafe(
                ", ",
              )}. Please set them, disable clickhouse in the \`storage\` config, or run \`envio dev\` for a pre-configured local ClickHouse.`,
          )
        }
        Some(
          Sink.makeClickHouse(
            ~host=host->Option.getUnsafe,
            ~database=database->Option.getUnsafe,
            ~username=username->Option.getUnsafe,
            ~password=password->Option.getUnsafe,
            ~sequence=config.checkpointSequence,
            ~chainIdMode=config.chainIdMode,
          ),
        )
      } else {
        None
      }
    },
    ~onInitialize=?{
      if isHasuraEnabled {
        Some(
          () => {
            Hasura.trackDatabase(
              ~endpoint=Env.Hasura.graphqlEndpoint,
              ~auth={
                role: Env.Hasura.role,
                secret: Env.Hasura.secret,
              },
              ~pgSchema,
              ~userEntities=config->Config.getPgUserEntities,
              ~responseLimit=Env.Hasura.responseLimit,
              ~schema=Schema.make(config.userEntities->Array.map(e => e.table)),
              ~aggregateEntities=Env.Hasura.aggregateEntities,
            )->Promise.catch(err => {
              Logging.errorWithExn(err->Utils.prettifyExn, `Error tracking tables`)->Promise.resolve
            })
          },
        )
      } else {
        None
      }
    },
  )
}

let makePersistenceFromConfig = (~config: Config.t, ~storage=makeStorageFromEnv(~config)) => {
  Persistence.make(~userEntities=config.userEntities, ~allEnums=config.allEnums, ~storage)
}
