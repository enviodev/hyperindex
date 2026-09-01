let makeClient = () => {
  Postgres.makeSql(
    ~config={
      host: Env.Db.host,
      port: Env.Db.port,
      username: Env.Db.user,
      password: Env.Db.password,
      database: Env.Db.database,
      ssl: Env.Db.ssl,
      // TODO: think how we want to pipe these logs to pino.
      onnotice: ?(
        Env.userLogLevel == Some(#warn) || Env.userLogLevel == Some(#error)
          ? None
          : Some(_str => ())
      ),
      transform: {undefined: Null},
      max: Env.Db.maxConnections,
      // debug: (~connection, ~query, ~params as _, ~types as _) => Js.log2(connection, query),
    },
  )
}

let formatSeconds = (timeRef: Performance.timeRef) =>
  (Math.round(timeRef->Performance.secondsSince *. 100.) /. 100.)->Float.toString

// Every index build blocks writes to its table for as long as it runs, and on a
// large database that is not quick. Both build paths say so up front, so a
// stalled-looking indexer is explainable from the logs alone.
let slowOnLargeDatabaseNotice = "This can take a long time on a large database."

// Every index the entity schema promises: an `@index` field, a composite index,
// or the index backing a derived relationship. Deferred past the initial DDL and
// created in one transaction once backfill completes, so a resumed indexer that
// reports itself ready always has all of them.
//
// `entities` is the Postgres-backed set, and every `@derivedFrom` target within
// it resolves: config parsing rejects a Postgres entity deriving from one that
// isn't in Postgres (`validate_relationship_storage`).
let getSchemaIndexes = (~entities: array<Internal.entityConfig>): array<IndexDefinition.t> => {
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
  all->Array.filter(definition => {
    let key = definition->IndexDefinition.key
    if seen->Utils.Set.has(key) {
      false
    } else {
      seen->Utils.Set.add(key)->ignore
      true
    }
  })
}

let makeCreateTableQuery = (
  table: Table.table,
  ~pgSchema,
  ~isNumericArrayAsText,
  ~chainIdMode: ChainId.mode=Int32,
  ~partitionByColumn: option<string>=?,
) => {
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getPgDbFieldName

      {
        `"${fieldName}" ${Table.getPgFieldType(
            ~chainIdMode,
            ~fieldType,
            ~pgSchema,
            ~isArray,
            ~isNullable,
            ~isNumericArrayAsText,
          )}${switch defaultValue {
          | Some(defaultValue) => ` DEFAULT ${defaultValue}`
          | None => isNullable ? `` : ` NOT NULL`
          }}`
      }
    })
    ->Array.joinUnsafe(", ")

  let primaryKeyFieldNames = table->Table.getPgPrimaryKeyFieldNames
  let primaryKey = primaryKeyFieldNames->Array.map(field => `"${field}"`)->Array.joinUnsafe(", ")

  `CREATE TABLE IF NOT EXISTS "${pgSchema}"."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""})${switch partitionByColumn {
    | Some(column) => ` PARTITION BY LIST ("${column}")`
    | None => ""
    }};`
}

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

let entityHistoryCache = Utils.WeakMap.make()
let getEntityHistory = (~entityConfig: Internal.entityConfig): EntityHistory.pgEntityHistory<
  'entity,
> => {
  switch entityHistoryCache->Utils.WeakMap.get(entityConfig) {
  | Some(cache) => cache
  | None =>
    let cache = {
      let id = "id"

      let dataFields = entityConfig.table.fields->Array.filterMap(field =>
        switch field {
        | Field(field) =>
          switch field.fieldName {
          //id is not nullable and should be part of the pk
          | "id" => {...field, fieldName: id, isPrimaryKey: true}->Table.Field->Some
          // Same for the chain id of a per-chain entity: it completes the row's
          // identity, so it can neither be nulled out nor left out of the pk.
          | _ if field.isChainId => field->Table.Field->Some
          | _ =>
            {
              ...field,
              isNullable: true, //All entity fields are nullable in the case
              isIndex: false, //No need to index any additional entity data fields in entity history
            }
            ->Field
            ->Some
          }

        | DerivedFrom(_) => None
        }
      )

      let actionField = Table.mkField(
        EntityHistory.changeFieldName,
        EntityHistory.changeFieldType,
        ~fieldSchema=S.never,
      )

      let checkpointIdField = Table.mkField(
        EntityHistory.checkpointIdFieldName,
        EntityHistory.checkpointIdFieldType,
        ~fieldSchema=EntityHistory.unsafeCheckpointIdSchema,
        ~isPrimaryKey=true,
      )

      let entityTableName = entityConfig.table.tableName
      let historyTableName = EntityHistory.historyTableName(
        ~entityName=entityTableName,
        ~entityIndex=entityConfig.index,
      )
      //ignore composite indexes
      let table = Table.mkTable(
        historyTableName,
        ~fields=dataFields->Array.concat([checkpointIdField, actionField]),
      )

      let setChangeSchema = EntityHistory.makeSetUpdateSchema(
        ~idSchema=entityConfig.table->Table.getIdSchema,
        entityConfig->getRowSchema,
      )

      {
        EntityHistory.table,
        setChangeSchema,
        setChangeSchemaRows: S.array(setChangeSchema),
      }
    }

    entityHistoryCache->Utils.WeakMap.set(entityConfig, cache)->ignore
    cache
  }
}

// Every table an entity needs: its own, one partition per chain when it's
// per-chain, and its history table. The chain set is fixed for the life of a
// schema — changing it fails the resume compat check against `envio_info` and
// forces a resync — so every partition the entity will ever need is created
// here, at init.
//
// History stays unpartitioned: it is only ever read by checkpoint, never by
// chain, so partitioning it would route every write and prune nothing.
let makeCreateEntityTableQueries = (
  entityConfig: Internal.entityConfig,
  ~pgSchema,
  ~isNumericArrayAsText,
  ~chainIdMode: ChainId.mode=Int32,
  ~chainIds: array<ChainId.t>,
) => {
  let createTable = (table, ~partitionByColumn=?) =>
    makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText, ~chainIdMode, ~partitionByColumn?)

  switch entityConfig.table->Table.getChainIdField {
  | None => [entityConfig.table->createTable]
  | Some(chainIdField) =>
    [
      entityConfig.table->createTable(~partitionByColumn=chainIdField->Table.getPgDbFieldName),
    ]->Array.concat(
      chainIds->Array.map(chainId =>
        `CREATE TABLE IF NOT EXISTS "${pgSchema}"."${partitionTableName(
            ~entityConfig,
            ~chainId,
          )}" PARTITION OF "${pgSchema}"."${entityConfig.table.tableName}" FOR VALUES IN (${chainId->ChainId.toString});`
      ),
    )
  }->Array.concat([getEntityHistory(~entityConfig).table->createTable])
}

let makeInitializeTransaction = (
  ~pgSchema,
  ~pgUser,
  ~isHasuraEnabled,
  ~chainConfigs=[],
  ~entities=[],
  ~enums=[],
  ~isEmptyPgSchema=false,
  // Backfill writes are far cheaper without the schema's read indexes, so the
  // initial DDL creates only tables, primary keys, views and chain rows; the
  // rest is created by `finalizeBackfill` before the indexer reports ready.
  ~deferSchemaIndexes=false,
  ~chainIdMode: ChainId.mode=Int32,
) => {
  let generalTables = [
    InternalTable.Chains.table,
    InternalTable.EnvioInfo.table,
    InternalTable.EnvioContracts.table,
    InternalTable.EnvioAddresses.table,
    InternalTable.Checkpoints.table,
    InternalTable.RawEvents.table,
  ]

  let chainIds = chainConfigs->Array.map((chainConfig: Config.chain) => chainConfig.id)

  let tableQueries =
    generalTables
    ->Array.map(table =>
      makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=isHasuraEnabled, ~chainIdMode)
    )
    ->Array.concat(
      entities->Array.flatMap((entityConfig: Internal.entityConfig) =>
        entityConfig->makeCreateEntityTableQueries(
          ~pgSchema,
          ~isNumericArrayAsText=isHasuraEnabled,
          ~chainIdMode,
          ~chainIds,
        )
      ),
    )

  let schemaIndexes = getSchemaIndexes(~entities)

  let query = ref(
    (
      isEmptyPgSchema && pgSchema === "public"
      // Hosted Service already have a DB with the created public schema
      // It also doesn't allow to simply drop it,
      // so we reuse the existing schema when it's empty.
      // IF NOT EXISTS handles the case where public was previously dropped.
        ? `CREATE SCHEMA IF NOT EXISTS "${pgSchema}";\n`
        : `DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;
CREATE SCHEMA "${pgSchema}";\n`
    ) ++
    `GRANT ALL ON SCHEMA "${pgSchema}" TO "${pgUser}";
GRANT ALL ON SCHEMA "${pgSchema}" TO public;`,
  )

  // Optimized enum creation - direct when cleanRun, conditional otherwise
  enums->Array.forEach((enumConfig: Table.enumConfig<Table.enum>) => {
    let enumCreateQuery = `CREATE TYPE "${pgSchema}".${enumConfig.name} AS ENUM(${enumConfig.variants
      ->Array.map(v => `'${v->(Utils.magic: Table.enum => string)}'`)
      ->Array.joinUnsafe(", ")});`

    query := query.contents ++ "\n" ++ enumCreateQuery
  })

  // Batch all table creation first (optimal for PostgreSQL)
  tableQueries->Array.forEach(tableQuery => {
    query := query.contents ++ "\n" ++ tableQuery
  })

  // Then batch all indexes (better performance when tables exist)
  if !deferSchemaIndexes {
    schemaIndexes->Array.forEach(definition => {
      query := query.contents ++ "\n" ++ definition->IndexDefinition.makeCreateQuery(~pgSchema)
    })
  }

  // Create views for Hasura integration
  query := query.contents ++ "\n" ++ InternalTable.Views.makeMetaViewQuery(~pgSchema)
  query := query.contents ++ "\n" ++ InternalTable.Views.makeChainMetadataViewQuery(~pgSchema)

  // Populate initial chain data
  switch InternalTable.Chains.makeInitialValuesQuery(~pgSchema, ~chainConfigs) {
  | Some(initialChainsValuesQuery) => query := query.contents ++ "\n" ++ initialChainsValuesQuery
  | None => ()
  }

  [query.contents]
}

let makeLoadQuery = (~pgSchema, ~tableName, ~condition) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE ${condition};`
}

// Appends the filter's serialized field values to params (mutated in place)
// and returns the matching SQL condition referencing them by index.
// Field names are spliced as quoted identifiers only after the queryFields
// lookup proves they exist on the table (and they originate from
// codegen-validated schemas), so the interpolation can't be abused.
let rec makeFilterCondition = (
  ~filter: EntityFilter.t,
  ~table: Table.table,
  ~params: array<JSON.t>,
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
    let param = try fieldValue->S.reverseConvertToJsonOrThrow(
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
  let scalarCondition = (~fieldName, ~fieldValue, ~op) => {
    let queryField = getQueryFieldOrThrow(fieldName)
    `"${queryField.pgDbFieldName}" ${op} ${serializeParamOrThrow(
        ~queryField,
        ~fieldName,
        ~fieldValue,
        ~isArray=false,
      )}`
  }
  switch filter {
  // A per-chain entity's table is partitioned by its chain-id column, and
  // Postgres can only prune a plan it caches when that column is a constant in
  // the SQL. Bound, the cached plan has to keep every partition, and the
  // planner ends up throwing it away and re-planning on every execution
  // instead — measured at 315us per load against 218us with the id written in,
  // on 30 chains.
  //
  // The cost is that each chain gets its own query text, so Postgres caches a
  // prepared statement per (entity, chain, filter shape) rather than per
  // (entity, filter shape). Measured at ~8KB of plan cache each, which is ~10MB
  // per connection for 40 entities across 30 chains — accepted, since the
  // alternative is a cached plan that can't prune.
  //
  // `LoadLayer.scopeFilter` is what puts this filter here, and the value is
  // range-checked to a non-negative safe integer, so it can carry nothing but
  // digits.
  | Eq({fieldName, fieldValue}) if getQueryFieldOrThrow(fieldName).isChainId =>
    `"${getQueryFieldOrThrow(fieldName).pgDbFieldName}" = ${fieldValue
      ->ChainId.normalizeOrThrow
      ->ChainId.toString}`
  | Eq({fieldName, fieldValue}) => scalarCondition(~fieldName, ~fieldValue, ~op="=")
  | Gt({fieldName, fieldValue}) => scalarCondition(~fieldName, ~fieldValue, ~op=">")
  | Lt({fieldName, fieldValue}) => scalarCondition(~fieldName, ~fieldValue, ~op="<")
  | In({fieldName, fieldValue}) => {
      let queryField = getQueryFieldOrThrow(fieldName)
      `"${queryField.pgDbFieldName}" = ANY(${serializeParamOrThrow(
          ~queryField,
          ~fieldName,
          ~fieldValue=fieldValue->(Utils.magic: array<unknown> => unknown),
          ~isArray=true,
        )})`
    }
  | And({filters: []}) =>
    throw(
      Persistence.StorageError({
        message: `Failed loading "${table.tableName}" from storage. The "and" filter must contain at least one nested filter.`,
        reason: Utils.Error.make(`Empty "and" filter`),
      }),
    )
  | And({filters}) =>
    `(${filters
      ->Array.map(filter => makeFilterCondition(~filter, ~table, ~params))
      ->Array.join(" AND ")})`
  }
}

// The chain-id predicate a per-chain entity's row-level SQL needs, already
// including the leading AND. Empty for cross-chain entities and for internal
// tables, which have no such column.
//
// The chain id is written into the SQL rather than bound, because the table is
// partitioned by it — see `makeFilterCondition` for why a partition key has to
// be a constant.
let makeChainIdCondition = (~table: Table.table, ~chainId: option<ChainId.t>) =>
  switch (table->Table.getChainIdField, chainId) {
  | (Some(field), Some(chainId)) =>
    ` AND "${field->Table.getPgDbFieldName}" = ${chainId->ChainId.toString}`
  | _ => ""
  }

let makeDeleteByIdQuery = (~pgSchema, ~tableName, ~chainIdCondition) => {
  `DELETE FROM "${pgSchema}"."${tableName}" WHERE id = $1${chainIdCondition};`
}

let makeDeleteByIdsQuery = (~pgSchema, ~tableName, ~idPgType, ~chainIdCondition) => {
  `DELETE FROM "${pgSchema}"."${tableName}" WHERE id = ANY($1::${idPgType}[])${chainIdCondition};`
}

let makeLoadAllQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}";`
}

let makeInsertUnnestSetQuery = (
  ~pgSchema,
  ~table: Table.table,
  ~itemSchema,
  ~isRawEvents,
  ~chainIdMode: ChainId.mode=Int32,
) => {
  let {quotedFieldNames, quotedNonPrimaryFieldNames, arrayFieldTypes} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema, ~chainIdMode)

  let primaryKeyFieldNames = Table.getPgPrimaryKeyFieldNames(table)

  `INSERT INTO "${pgSchema}"."${table.tableName}" (${quotedFieldNames->Array.joinUnsafe(", ")})
SELECT * FROM unnest(${arrayFieldTypes
    ->Array.mapWithIndex((arrayFieldType, idx) => {
      `$${(idx + 1)->Int.toString}::${arrayFieldType}`
    })
    ->Array.joinUnsafe(",")})` ++
  switch (isRawEvents, primaryKeyFieldNames) {
  | (true, _)
  | (_, []) => ``
  | (false, primaryKeyFieldNames) =>
    `ON CONFLICT(${primaryKeyFieldNames
      ->Array.map(fieldName => `"${fieldName}"`)
      ->Array.joinUnsafe(",")}) DO ` ++ (
      quotedNonPrimaryFieldNames->Utils.Array.isEmpty
        ? `NOTHING`
        : `UPDATE SET ${quotedNonPrimaryFieldNames
            ->Array.map(fieldName => {
              `${fieldName} = EXCLUDED.${fieldName}`
            })
            ->Array.joinUnsafe(",")}`
    )
  } ++ ";"
}

let makeInsertValuesSetQuery = (
  ~pgSchema,
  ~table: Table.table,
  ~itemSchema,
  ~itemsCount,
  ~chainIdMode: ChainId.mode=Int32,
) => {
  let {quotedFieldNames, quotedNonPrimaryFieldNames} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema, ~chainIdMode)

  let primaryKeyFieldNames = Table.getPgPrimaryKeyFieldNames(table)
  let fieldsCount = quotedFieldNames->Array.length

  // Create placeholder variables for the VALUES clause - using $1, $2, etc.
  let placeholders = ref("")
  for idx in 1 to itemsCount {
    if idx > 1 {
      placeholders := placeholders.contents ++ ","
    }
    placeholders := placeholders.contents ++ "("
    for fieldIdx in 0 to fieldsCount - 1 {
      if fieldIdx > 0 {
        placeholders := placeholders.contents ++ ","
      }
      placeholders := placeholders.contents ++ `$${(fieldIdx * itemsCount + idx)->Int.toString}`
    }
    placeholders := placeholders.contents ++ ")"
  }

  `INSERT INTO "${pgSchema}"."${table.tableName}" (${quotedFieldNames->Array.joinUnsafe(", ")})
VALUES${placeholders.contents}` ++
  switch primaryKeyFieldNames {
  | [] => ``
  | primaryKeyFieldNames =>
    `ON CONFLICT(${primaryKeyFieldNames
      ->Array.map(fieldName => `"${fieldName}"`)
      ->Array.joinUnsafe(",")}) DO ` ++ (
      quotedNonPrimaryFieldNames->Utils.Array.isEmpty
        ? `NOTHING`
        : `UPDATE SET ${quotedNonPrimaryFieldNames
            ->Array.map(fieldName => {
              `${fieldName} = EXCLUDED.${fieldName}`
            })
            ->Array.joinUnsafe(",")}`
    )
  } ++ ";"
}

// Constants for chunking
let maxItemsPerQuery = 500

let makeTableBatchSetQuery = (
  ~pgSchema,
  ~table: Table.table,
  ~itemSchema: S.t<'item>,
  ~chainIdMode: ChainId.mode=Int32,
) => {
  let {dbSchema, hasArrayField} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema, ~chainIdMode)

  // Should move this to a better place
  // We need it for the isRawEvents check in makeTableBatchSet
  // to always apply the unnest optimization.
  // This is needed, because even though it has JSON fields,
  // they are always guaranteed to be an object.
  // FIXME what about Fuel params?
  let isRawEvents = table.tableName === InternalTable.RawEvents.table.tableName

  // Currently history update table uses S.object with transformation for schema,
  // which is being lossed during conversion to dbSchema.
  // So use simple insert values for now.
  let isHistoryUpdate = table.tableName->String.startsWith(EntityHistory.historyTablePrefix)

  // Should experiment how much it'll affect performance
  // Although, it should be fine not to perform the validation check,
  // since the values are validated by type system.
  // As an alternative, we can only run Sury validation only when
  // db write fails to show a better user error.
  let typeValidation = false

  if (isRawEvents || !hasArrayField) && !isHistoryUpdate {
    {
      "query": makeInsertUnnestSetQuery(~pgSchema, ~table, ~itemSchema, ~isRawEvents, ~chainIdMode),
      "convertOrThrow": S.compile(
        S.unnest(dbSchema),
        ~input=Value,
        ~output=Unknown,
        ~mode=Sync,
        ~typeValidation,
      ),
      "isInsertValues": false,
    }
  } else {
    {
      "query": makeInsertValuesSetQuery(
        ~pgSchema,
        ~table,
        ~itemSchema,
        ~itemsCount=maxItemsPerQuery,
        ~chainIdMode,
      ),
      "convertOrThrow": S.compile(
        S.unnest(itemSchema)->S.preprocess(_ => {
          serializer: Utils.Array.flatten->(
            Utils.magic: (array<array<'a>> => array<'a>) => unknown => unknown
          ),
        }),
        ~input=Value,
        ~output=Unknown,
        ~mode=Sync,
        ~typeValidation,
      ),
      "isInsertValues": true,
    }
  }
}

let chunkArray = (arr: array<'a>, ~chunkSize) => {
  let chunks = []
  let i = ref(0)
  while i.contents < arr->Array.length {
    let chunk = arr->Array.slice(~start=i.contents, ~end=i.contents + chunkSize)
    chunks->Array.push(chunk)->ignore
    i := i.contents + chunkSize
  }
  chunks
}

// Strips NUL bytes, recursing into nested objects/arrays so a NUL buried
// inside a jsonb column (an event param object, a json entity field) is
// removed too — Postgres rejects it in both text (0x00) and jsonb (22P05).
let rec removeInvalidUtf8DeepInPlace = (value: unknown): unknown => {
  if value->typeof === #string {
    value
    ->(Utils.magic: unknown => string)
    ->Utils.String.replaceAll("\x00", "")
    ->(Utils.magic: string => unknown)
  } else if value->typeof === #object && value !== %raw(`null`) {
    let dict = value->(Utils.magic: unknown => dict<unknown>)
    dict->Utils.Dict.forEachWithKey((v, k) => dict->Dict.set(k, removeInvalidUtf8DeepInPlace(v)))
    value
  } else {
    value
  }
}

let removeInvalidUtf8InPlace = items =>
  items->Array.forEach(item =>
    removeInvalidUtf8DeepInPlace(item->(Utils.magic: 'a => unknown))->ignore
  )

let pgErrorMessageSchema = S.object(s => s.field("message", S.string))

exception PgEncodingError({table: Table.table})

// Classifies a write failure, parking it in `specificError` so the
// transaction can unwind and the outer handler can react. Both Postgres
// encoding failures we recognize are NUL-related — `0x00` in a text column
// and a NUL rejected by jsonb (22P05) — so they become a PgEncodingError
// that triggers an escape-and-retry of the offending table, where deep NUL
// stripping resolves them. We escape lazily on first failure to keep the
// happy path free of per-item sanitization. The aborted-transaction cascade
// is ignored so it never masks the original error.
let classifyWriteError = (~specificError: ref<option<exn>>, ~table: Table.table, ~exn) => {
  /* Note: Entity History doesn't return StorageError yet, and directly throws JsError */
  let normalizedExn = switch exn {
  | JsExn(_) => exn
  | Persistence.StorageError({reason: exn}) => exn
  | _ => exn
  }->JsExn.anyToExnInternal

  switch normalizedExn {
  | JsExn(error) =>
    switch error->S.parseOrThrow(pgErrorMessageSchema) {
    | `current transaction is aborted, commands ignored until end of transaction block` => ()
    | `invalid byte sequence for encoding "UTF8": 0x00`
    | `unsupported Unicode escape sequence` =>
      specificError.contents = Some(PgEncodingError({table: table}))
    | _ => specificError.contents = Some(exn->Utils.prettifyExn)
    | exception _ => ()
    }
  | S.Raised(_) => throw(normalizedExn) // But rethrow this one, since it's not a PG error
  | _ => ()
  }
}

// Batch set queries, cached per table. The query text bakes in the schema and
// the chain-id mode, so the cache belongs to the storage instance those came
// from — `make` creates one and threads it down. A process-wide cache would
// hand a second storage the first one's schema.
let makeSetQueryCache = () => Utils.WeakMap.make()

let setOrThrow = async (
  sql,
  ~items,
  ~table: Table.table,
  ~itemSchema,
  ~pgSchema,
  ~setQueryCache,
  ~chainIdMode: ChainId.mode=Int32,
) => {
  if items->Array.length === 0 {
    ()
  } else {
    // Get or create cached query for this table
    let data = switch setQueryCache->Utils.WeakMap.get(table) {
    | Some(cached) => cached
    | None => {
        let newQuery = makeTableBatchSetQuery(
          ~pgSchema,
          ~table,
          ~itemSchema=itemSchema->S.toUnknown,
          ~chainIdMode,
        )
        setQueryCache->Utils.WeakMap.set(table, newQuery)->ignore
        newQuery
      }
    }

    try {
      if data["isInsertValues"] {
        let chunks = chunkArray(items, ~chunkSize=maxItemsPerQuery)
        let responses = []
        chunks->Array.forEach(chunk => {
          let chunkSize = chunk->Array.length
          let isFullChunk = chunkSize === maxItemsPerQuery

          let params = data["convertOrThrow"](chunk->(Utils.magic: array<'item> => array<unknown>))
          // Use prepared query only for full batches where the cached query is reused.
          // Partial chunks generate unique SQL each time, so preparation has no benefit.
          let response = isFullChunk
            ? sql->Postgres.preparedUnsafe(data["query"], params)
            : sql->Postgres.unpreparedUnsafe(
                makeInsertValuesSetQuery(
                  ~pgSchema,
                  ~table,
                  ~itemSchema,
                  ~itemsCount=chunkSize,
                  ~chainIdMode,
                ),
                params,
              )
          responses->Array.push(response)->ignore
        })
        let _ = await Promise.all(responses)
      } else {
        // Use UNNEST approach for single query
        await sql->Postgres.preparedUnsafe(
          data["query"],
          data["convertOrThrow"](items->(Utils.magic: array<'item> => array<unknown>)),
        )
      }
    } catch {
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
    }
  }
}

type schemaTableName = {
  @as("table_name")
  tableName: string,
}

let makeSchemaTableNamesQuery = (~pgSchema) => {
  `SELECT table_name FROM information_schema.tables WHERE table_schema = '${pgSchema}';`
}

type schemaCacheTableInfo = {
  @as("table_name")
  tableName: string,
  @as("count")
  count: int,
}

type cacheRowCount = {
  @as("count")
  count: int,
}

// Matches both the cross-chain (`envio_effect_<name>`) and chain-scoped
// (`envio_<chainId>_effect_<name>`) cache-table formats. Kept in sync with
// Internal.EffectCache.
let makeEffectCacheTableNamesQuery = (~pgSchema) => {
  // The column guard requires the effect-cache shape (exactly an `id` + `output`
  // pair) so a user entity table that happens to match the name pattern is never
  // mistaken for an effect cache.
  `SELECT t.table_name
   FROM information_schema.tables t
   WHERE t.table_schema = '${pgSchema}'
   AND t.table_name ~ '^envio_([0-9]+_)?effect_.+'
   AND (
     SELECT array_agg(c.column_name::text ORDER BY c.column_name::text)
     FROM information_schema.columns c
     WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name
   ) = ARRAY['id', 'output'];`
}

let makeCacheRowCountQuery = (~pgSchema, ~tableName) => {
  // The table name comes from information_schema, so anything cache-shaped that
  // was created out-of-band in the schema reaches here. Splice both identifiers
  // as quoted identifiers, doubling embedded quotes, so a crafted name can't
  // break out into raw SQL.
  let quoteIdent = ident => `"${ident->String.replaceAll("\"", "\"\"")}"`
  `SELECT COUNT(*)::int AS count FROM ${quoteIdent(pgSchema)}.${quoteIdent(tableName)};`
}

type psqlExecState =
  Unknown | Pending(promise<result<string, string>>) | Resolved(result<string, string>)

let getConnectedPsqlExec = {
  // Should use the default port, since we're executing the command
  // from the postgres container's network.
  let pgDockerServicePort = 5432

  // For development: We run the indexer process locally,
  //   and there might not be psql installed on the user's machine.
  //   So we use docker exec to run psql inside the postgres container.
  // For production: We expect indexer to be running in a container,
  //   with psql installed. So we can call it directly.
  let psqlExecState = ref(Unknown)
  async (~pgUser, ~pgHost, ~pgDatabase, ~pgPort, ~containerName) => {
    switch psqlExecState.contents {
    | Unknown => {
        let promise = Promise.make((resolve, _reject) => {
          let binary = "psql"
          NodeJs.ChildProcess.exec(`${binary} --version`, (~error, ~stdout as _, ~stderr as _) => {
            switch error {
            | Value(_) => {
                let binary = `docker exec -i -u ${pgUser} ${containerName} psql`
                NodeJs.ChildProcess.exec(
                  `${binary} --version`,
                  (~error, ~stdout as _, ~stderr as _) => {
                    switch error {
                    | Value(_) =>
                      resolve(
                        Error(
                          `Please check if "psql" binary is installed or Docker container "${containerName}" is running.`,
                        ),
                      )
                    | Null =>
                      resolve(
                        Ok(
                          `${binary} -h ${pgHost} -p ${pgDockerServicePort->Int.toString} -U ${pgUser} -d ${pgDatabase}`,
                        ),
                      )
                    }
                  },
                )
              }
            | Null =>
              resolve(
                Ok(
                  `${binary} -h ${pgHost} -p ${pgPort->Int.toString} -U ${pgUser} -d ${pgDatabase}`,
                ),
              )
            }
          })
        })

        psqlExecState := Pending(promise)
        let result = await promise
        psqlExecState := Resolved(result)
        result
      }
    | Pending(promise) => await promise
    | Resolved(result) => result
    }
  }
}

let deleteByIdsOrThrow = async (
  sql,
  ~pgSchema,
  ~ids: array<EntityId.t>,
  ~table: Table.table,
  ~chainId: option<ChainId.t>=None,
) => {
  let chainIdCondition = makeChainIdCondition(~table, ~chainId)
  // A JSON array of the serialized ids. For a single id the query binds it as
  // `$1` directly (the array is the positional-params array); for many it binds
  // the whole array to `$1` behind an `ANY(...)`.
  let idsJson = table->Table.encodeIdsToJson(ids)
  switch await (
    switch ids {
    | [_] =>
      sql->Postgres.preparedUnsafe(
        makeDeleteByIdQuery(~pgSchema, ~tableName=table.tableName, ~chainIdCondition),
        idsJson->(Utils.magic: JSON.t => array<unknown>)->Obj.magic,
      )
    | _ =>
      sql->Postgres.preparedUnsafe(
        makeDeleteByIdsQuery(
          ~pgSchema,
          ~tableName=table.tableName,
          ~idPgType=table->Table.getIdPgFieldType(~pgSchema),
          ~chainIdCondition,
        ),
        [idsJson->(Utils.magic: JSON.t => unknown)]->Obj.magic,
      )
    }
  ) {
  | exception exn =>
    throw(
      Persistence.StorageError({
        message: `Failed deleting "${table.tableName}" from storage by ids`,
        reason: exn,
      }),
    )
  | _ => ()
  }
}

let makeInsertDeleteUpdatesQuery = (
  ~entityConfig: Internal.entityConfig,
  ~pgSchema,
  ~chainId: option<ChainId.t>,
) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )

  // Get all field names for the INSERT statement
  let allHistoryFieldNames = entityConfig.table.fields->Array.filterMap(fieldOrDerived =>
    switch fieldOrDerived {
    | Field(field) => field->Table.getPgDbFieldName->Some
    | DerivedFrom(_) => None
    }
  )
  allHistoryFieldNames->Array.push(EntityHistory.checkpointIdFieldName)->ignore
  allHistoryFieldNames->Array.push(EntityHistory.changeFieldName)->ignore

  let allHistoryFieldNamesStr =
    allHistoryFieldNames->Array.map(name => `"${name}"`)->Array.joinUnsafe(", ")

  // Build the SELECT part: id from unnest, envio_checkpoint_id from unnest, 'DELETE' for action, NULL for all other fields
  // The chain-id column is part of the history primary key, so a DELETE row
  // carries the scope's chain — bound once as $3 — rather than the NULL every
  // other data field gets.
  let chainIdColumn = switch (entityConfig.table->Table.getChainIdField, chainId) {
  | (Some(field), Some(_)) => field->Table.getPgDbFieldName
  | _ => ""
  }
  let selectParts = allHistoryFieldNames->Array.map(fieldName => {
    switch fieldName {
    | field if field == Table.idFieldName => `u.${Table.idFieldName}`
    | field if field == EntityHistory.checkpointIdFieldName =>
      `u.${EntityHistory.checkpointIdFieldName}`
    | field if field == EntityHistory.changeFieldName =>
      `'${(EntityHistory.RowAction.DELETE :> string)}'`
    | field if chainIdColumn !== "" && field == chainIdColumn => "$3"
    | _ => "NULL"
    }
  })
  let selectPartsStr = selectParts->Array.joinUnsafe(", ")

  // Get the PostgreSQL type for the checkpoint ID field
  let checkpointIdPgType = Table.getPgFieldType(
    ~fieldType=EntityHistory.checkpointIdFieldType,
    ~pgSchema,
    ~isArray=false,
    ~isNumericArrayAsText=false,
    ~isNullable=false,
  )

  let idPgType = entityConfig.table->Table.getIdPgFieldType(~pgSchema)

  `INSERT INTO "${pgSchema}"."${historyTableName}" (${allHistoryFieldNamesStr})
SELECT ${selectPartsStr}
FROM UNNEST($1::${idPgType}[], $2::${checkpointIdPgType}[]) AS u(${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName})`
}

let executeSet = (
  sql: Postgres.sql,
  ~items: array<'a>,
  ~dbFunction: (Postgres.sql, array<'a>) => promise<unit>,
) => {
  if items->Array.length > 0 {
    sql->dbFunction(items)
  } else {
    Promise.resolve()
  }
}

let rec writeBatch = async (
  sql,
  ~batch: Batch.t,
  ~pgSchema,
  ~rollback: option<Persistence.rollback>,
  ~isInReorgThreshold,
  ~config: Config.t,
  ~allEntities: array<Internal.entityConfig>,
  ~setEffectCacheOrThrow,
  ~setQueryCache,
  ~updatedEffectsCache,
  ~updatedEntities: array<Persistence.updatedEntity>,
  ~registeredAddresses: array<AddressRows.staged>,
  ~sinkPromise: option<promise<option<exn>>>,
  ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
  ~escapeTables=?,
) => {
  try {
    let chainIdMode = config.chainIdMode
    let shouldSaveHistory = config->Config.shouldSaveHistory(~isInReorgThreshold)

    let specificError = ref(None)

    let rawEvents = if config.enableRawEvents {
      // A single on-chain log fans out to one item per matching registration;
      // `raw_events` records the log itself, so dedupe by its coordinate
      // (chain, block, logIndex) to keep one row per log.
      let seenLogCoordinates = Utils.Set.make()
      let rows = batch.items->Array.filterMap(item =>
        switch item {
        | Internal.Event(_) =>
          let eventItem = item->Internal.castUnsafeEventItem
          let coordinate = `${eventItem.chainId->ChainId.toString}-${eventItem.blockNumber->Int.toString}-${eventItem.logIndex->Int.toString}`
          if seenLogCoordinates->Utils.Set.has(coordinate) {
            None
          } else {
            seenLogCoordinates->Utils.Set.add(coordinate)->ignore
            Some(config.ecosystem.toRawEvent(item->Internal.castUnsafeEventItem))
          }
        | Internal.Block(_) => None
        }
      )
      switch escapeTables {
      | Some(tables) if tables->Utils.Set.has(InternalTable.RawEvents.table) =>
        rows->removeInvalidUtf8InPlace
      | _ => ()
      }
      rows
    } else {
      []
    }

    let setRawEvents = async sql => {
      try {
        await sql->executeSet(~dbFunction=(sql, items) => {
          sql->setOrThrow(
            ~items,
            ~table=InternalTable.RawEvents.table,
            ~itemSchema=InternalTable.RawEvents.schema,
            ~pgSchema,
            ~chainIdMode,
            ~setQueryCache,
          )
        }, ~items=rawEvents)
      } catch {
      | exn => classifyWriteError(~specificError, ~table=InternalTable.RawEvents.table, ~exn)
      }
    }

    let setEntities = updatedEntities->Array.map(({entityConfig, scope, changes}) => {
      let entitiesToSet = []
      let idsToDelete = []

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

      // Bound as $3 by the history-delete query, after its two unnest arrays.
      // Empty for cross-chain entities, whose SQL has no such param.
      let chainIdParams = switch (entityConfig.table->Table.getChainIdField, scopeChainId) {
      | (Some(_), Some(chainId)) => [chainId->(Utils.magic: ChainId.t => unknown)]
      | _ => []
      }

      // The rollback-diff change is written to the entity table only, never the
      // history table; when present it is an id's oldest change.
      let diffCheckpointId = rollback->Option.map(r => r.diffCheckpointId)

      // History batches, populated only when saving history.
      let batchSetUpdates = []
      let batchDeleteEntityIds = []
      let batchDeleteCheckpointIds = []
      let idsWithDiff = Utils.Set.make()

      // Single pass over the change log: track each id's latest change (the last
      // one seen) and, when saving history, fan every non-diff change out to the
      // history-table batches.
      // Keyed/deduped in memory by the id's string key (toKey), while the
      // batches sent to SQL keep the real id values so they serialize with the
      // id column's type.
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
              batchDeleteEntityIds->Array.push(entityId)->ignore
              batchDeleteCheckpointIds->Array.push(checkpointId)->ignore
            | Set(_) => batchSetUpdates->Array.push(change)->ignore
            }
          }
        }
      })

      let backfillHistoryIds = Utils.Set.make()
      orderedIds->Array.forEach(entityId => {
        let entityKey = entityId->EntityId.toKey
        switch latestChangeById->Dict.getUnsafe(entityKey) {
        | Set({entity}) => entitiesToSet->Array.push(entity)
        | Delete({entityId}) => idsToDelete->Array.push(entityId)
        }

        // An id needs a history backfill iff none of its changes is the diff.
        if shouldSaveHistory && !(idsWithDiff->Utils.Set.has(entityKey)) {
          backfillHistoryIds->Utils.Set.add(entityId)->ignore
        }
      })

      let shouldRemoveInvalidUtf8 = switch escapeTables {
      | Some(tables) if tables->Utils.Set.has(entityConfig.table) => true
      | _ => false
      }

      async sql => {
        try {
          let promises = []

          if shouldSaveHistory {
            if backfillHistoryIds->Utils.Set.size !== 0 {
              // This must run before updating entity or entity history tables
              await EntityHistory.backfillHistory(
                sql,
                ~pgSchema,
                ~table=entityConfig.table,
                ~entityIndex=entityConfig.index,
                ~chainId=scopeChainId,
                ~ids=backfillHistoryIds->Utils.Set.toArray,
              )
            }

            if batchDeleteCheckpointIds->Utils.Array.notEmpty {
              promises->Array.push(
                sql
                ->Postgres.preparedUnsafe(
                  makeInsertDeleteUpdatesQuery(~entityConfig, ~pgSchema, ~chainId=scopeChainId),
                  [
                    entityConfig.table
                    ->Table.encodeIdsToJson(batchDeleteEntityIds)
                    ->(Utils.magic: JSON.t => unknown),
                    batchDeleteCheckpointIds
                    ->Utils.BigInt.arrayToStringArray
                    ->(Utils.magic: array<string> => unknown),
                  ]
                  ->Array.concat(chainIdParams)
                  ->Obj.magic,
                )
                ->Utils.Promise.ignoreValue,
              )
            }

            if batchSetUpdates->Utils.Array.notEmpty {
              if shouldRemoveInvalidUtf8 {
                let entities = batchSetUpdates->Array.map(batchSetUpdate => {
                  switch batchSetUpdate {
                  | Set({entity}) => entity
                  | _ => JsError.throwWithMessage("Expected Set action")
                  }
                })
                entities->removeInvalidUtf8InPlace
              }

              let entityHistory = getEntityHistory(~entityConfig)

              promises
              ->Array.push(
                sql->setOrThrow(
                  ~items=batchSetUpdates,
                  ~itemSchema=entityHistory.setChangeSchema,
                  ~table=entityHistory.table,
                  ~pgSchema,
                  ~chainIdMode,
                  ~setQueryCache,
                ),
              )
              ->ignore
            }
          }

          if entitiesToSet->Utils.Array.notEmpty {
            if shouldRemoveInvalidUtf8 {
              entitiesToSet->removeInvalidUtf8InPlace
            }
            promises->Array.push(
              sql->setOrThrow(
                ~items=entitiesToSet,
                ~table=entityConfig.table,
                ~itemSchema=entityConfig->getRowSchema,
                ~pgSchema,
                ~chainIdMode,
                ~setQueryCache,
              ),
            )
          }
          if idsToDelete->Utils.Array.notEmpty {
            promises->Array.push(
              sql->deleteByIdsOrThrow(
                ~pgSchema,
                ~ids=idsToDelete,
                ~table=entityConfig.table,
                ~chainId=scopeChainId,
              ),
            )
          }

          let _ = await promises->Promise.all
        } catch {
        // There's a race condition that sql->Postgres.beginSql
        // might throw PG error, earlier, than the handled error
        // from setOrThrow will be passed through.
        // This is needed for the utf8 encoding fix.
        //
        // Important: Don't rethrow here, since it'll result in an unhandled
        // rejected promise error. That's fine not to throw, since
        // sql->Postgres.beginSql will fail anyways.
        | exn => classifyWriteError(~specificError, ~table=entityConfig.table, ~exn)
        }
      }
    })

    //In the event of a rollback, rollback all meta tables based on the given
    //valid event identifier, where all rows created after this eventIdentifier should
    //be deleted
    let rollbackTables = switch rollback {
    | Some({
        targetCheckpointId: rollbackTargetCheckpointId,
        scope,
        rolledBackAddresses,
        progressedChains,
      }) =>
      Some(
        sql => {
          // Postgres owns history tables only for Postgres-backed entities;
          // ClickHouse-only entities have none to roll back.
          let promises =
            allEntities
            ->Array.filter(entityConfig => entityConfig.storage.postgres)
            ->Array.map(entityConfig => {
              sql->EntityHistory.rollback(
                ~pgSchema,
                ~entityName=entityConfig.name,
                ~entityIndex=entityConfig.index,
                ~chainIdColumn=entityConfig.table->Table.getPgChainIdColumn,
                ~scope,
                ~rollbackTargetCheckpointId,
              )
            })
          promises
          ->Array.push(
            sql->InternalTable.Checkpoints.rollback(~pgSchema, ~scope, ~rollbackTargetCheckpointId),
          )
          ->ignore

          // Runs before the batch's own progress write below, so a chain the
          // batch also progressed keeps the batch's later value.
          if progressedChains->Utils.Array.notEmpty {
            promises
            ->Array.push(
              sql->InternalTable.Chains.setProgressedChains(~pgSchema, ~progressedChains),
            )
            ->ignore
          }

          // Addresses are insert-only, so undoing their registrations is a
          // delete rather than a history replay. It runs before the batch's own
          // inserts in the same transaction, so a re-registered address lands
          // after its old row is gone.
          if rolledBackAddresses->Utils.Array.notEmpty {
            promises
            ->Array.push(
              sql->InternalTable.EnvioAddresses.delete(
                ~pgSchema,
                ~keys=rolledBackAddresses,
                ~chainIdMode,
              ),
            )
            ->ignore
          }
          Promise.all(promises)
        },
      )
    | None => None
    }

    try {
      let _ = await Promise.all2((
        sql->Postgres.beginSql(async sql => {
          //Rollback tables need to happen first in the traction
          switch rollbackTables {
          | Some(rollbackTables) =>
            let _ = await rollbackTables(sql)
          | None => ()
          }

          let setOperations = [
            sql =>
              sql->InternalTable.Chains.setProgressedChains(
                ~pgSchema,
                ~progressedChains=batch.progressedChainsById->Utils.Dict.mapValuesToArray((
                  chainAfterBatch
                ): InternalTable.Chains.progressedChain => {
                  chainId: chainAfterBatch.fetchState.chainId,
                  progressBlockNumber: chainAfterBatch.progressBlockNumber,
                  sourceBlockNumber: chainAfterBatch.sourceBlockNumber,
                  totalEventsProcessed: chainAfterBatch.totalEventsProcessed,
                }),
              ),
            setRawEvents,
          ]->Array.concat(setEntities)

          switch chainMetaData {
          | Some(chainsData) =>
            setOperations
            ->Array.push(sql =>
              sql->InternalTable.Chains.setMeta(~pgSchema, ~chainsData)->Utils.Promise.ignoreValue
            )
            ->ignore
          | None => ()
          }

          if registeredAddresses->Utils.Array.notEmpty {
            setOperations->Array.push(sql =>
              sql->InternalTable.EnvioAddresses.insert(
                ~pgSchema,
                ~rows=registeredAddresses->Array.map(staged => staged.row),
                ~chainIdMode,
              )
            )
          }

          if shouldSaveHistory {
            setOperations->Array.push(sql =>
              sql->InternalTable.Checkpoints.insert(
                ~pgSchema,
                ~checkpointIds=batch.checkpointIds,
                ~checkpointChainIds=batch.checkpointChainIds,
                ~checkpointBlockNumbers=batch.checkpointBlockNumbers,
                ~checkpointBlockHashes=batch.checkpointBlockHashes,
                ~checkpointEventsProcessed=batch.checkpointEventsProcessed,
                ~chainIdMode,
              )
            )
          }

          await setOperations
          ->Array.map(dbFunc => sql->dbFunc)
          ->Promise.all
          ->Utils.Promise.ignoreValue

          switch sinkPromise {
          | Some(sinkPromise) =>
            switch await sinkPromise {
            | Some(exn) => throw(exn)
            | None => ()
            }
          | None => ()
          }
        }),
        // Since effect cache currently doesn't support rollback,
        // we can run it outside of the transaction for simplicity.
        updatedEffectsCache
        ->Array.map((
          {table, itemSchema, items, shouldInitialize}: Persistence.updatedEffectCache,
        ) => {
          setEffectCacheOrThrow(~table, ~itemSchema, ~items, ~initialize=shouldInitialize)
        })
        ->Promise.all,
      ))

      // Just in case, if there's a not PG-specific error.
      switch specificError.contents {
      | Some(specificError) => throw(specificError)
      | None => ()
      }
    } catch {
    | exn =>
      throw(
        switch specificError.contents {
        | Some(specificError) => specificError
        | None => exn
        },
      )
    }
  } catch {
  | PgEncodingError({table}) =>
    let escapeTables = switch escapeTables {
    | Some(set) => set
    | None => Utils.Set.make()
    }
    let _ = escapeTables->Utils.Set.add(table)
    // Retry with specifying which tables to escape.
    await writeBatch(
      sql,
      ~escapeTables,
      ~batch,
      ~pgSchema,
      ~setQueryCache,
      ~rollback,
      ~isInReorgThreshold,
      ~config,
      ~setEffectCacheOrThrow,
      ~updatedEffectsCache,
      ~allEntities,
      ~updatedEntities,
      ~registeredAddresses,
      ~sinkPromise,
      ~chainMetaData,
    )
  }
}

// Returns the most recent history row at or before the rollback target for IDs changed after it.
// envio_change is included so ReScript can turn SET rows into restores and DELETE rows into removals.
// The columns that identify a history row: the id, plus the chain id for a
// per-chain entity.
let rollbackKeyColumns = (entityConfig: Internal.entityConfig) =>
  switch entityConfig.table->Table.getChainIdField {
  | Some(field) => [Table.idFieldName, field->Table.getPgDbFieldName]
  | None => [Table.idFieldName]
  }

let makeGetRollbackPreTargetRowsQuery = (
  ~entityConfig: Internal.entityConfig,
  ~pgSchema,
  ~scope: RollbackScope.t,
) => {
  let dataFieldNames = entityConfig.table.fields->Array.filterMap(fieldOrDerived =>
    switch fieldOrDerived {
    | Field(field) => field->Table.getPgDbFieldName->Some
    | DerivedFrom(_) => None
    }
  )

  let dataFieldsCommaSeparated =
    dataFieldNames->Array.map(name => `"${name}"`)->Array.joinUnsafe(", ")

  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )

  // A per-chain entity's rows are only comparable within a chain, so the row's
  // identity here is (id, chain id) rather than the id alone.
  let keyColumns = rollbackKeyColumns(entityConfig)
  let keyColumnsCommaSeparated = keyColumns->Array.map(c => `"${c}"`)->Array.joinUnsafe(", ")
  let keyMatch =
    keyColumns
    ->Array.map(c => `h."${c}" = "${historyTableName}"."${c}"`)
    ->Array.joinUnsafe(" AND ")

  `SELECT DISTINCT ON (${keyColumnsCommaSeparated}) ${dataFieldsCommaSeparated}, "${EntityHistory.changeFieldName}"
  FROM "${pgSchema}"."${historyTableName}"
  WHERE "${EntityHistory.checkpointIdFieldName}" <= $1${scope->RollbackScope.predicate(
      ~chainIdColumn=entityConfig.table->Table.getPgChainIdColumn,
    )}
    AND EXISTS (
      SELECT 1
      FROM "${pgSchema}"."${historyTableName}" h
      WHERE ${keyMatch}
        AND h."${EntityHistory.checkpointIdFieldName}" > $1
    )
  ORDER BY ${keyColumnsCommaSeparated}, "${EntityHistory.checkpointIdFieldName}" DESC`
}

// Returns entity IDs that were created after the rollback target and have no history before it.
// DELETE rows at or before the target are returned by the restore query and classified in ReScript.
let makeGetRollbackRemovedIdsQuery = (
  ~entityConfig: Internal.entityConfig,
  ~pgSchema,
  ~scope: RollbackScope.t,
) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )
  let keyColumns = rollbackKeyColumns(entityConfig)
  let keyMatch =
    keyColumns
    ->Array.map(c => `h."${c}" = "${historyTableName}"."${c}"`)
    ->Array.joinUnsafe(" AND ")

  `SELECT DISTINCT ${keyColumns->Array.map(c => `"${c}"`)->Array.joinUnsafe(", ")}
  FROM "${pgSchema}"."${historyTableName}"
  WHERE "${EntityHistory.checkpointIdFieldName}" > $1${scope->RollbackScope.predicate(
      ~chainIdColumn=entityConfig.table->Table.getPgChainIdColumn,
    )}
    AND NOT EXISTS (
      SELECT 1
      FROM "${pgSchema}"."${historyTableName}" h
      WHERE ${keyMatch}
        AND h."${EntityHistory.checkpointIdFieldName}" <= $1
    )`
}

// Memoized per table so the id is parsed with that entity's id schema (a
// numeric id comes back from Postgres as a number, not a string) and the
// schema's operations compile once rather than per rollback row.
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
  ~sql: Postgres.sql,
  ~pgHost,
  ~pgSchema,
  ~pgPort,
  ~pgUser,
  ~pgDatabase,
  ~pgPassword,
  ~isHasuraEnabled,
  ~chainIdMode: ChainId.mode=Int32,
  // Decides how wide an address key is, both when the config's addresses are
  // encoded at initialize and when stored rows are grouped on resume.
  ~ecosystem: Ecosystem.name,
  ~sink: option<Sink.t>=?,
  ~onInitialize=?,
  ~onNewTables=?,
): Persistence.storage => {
  // Must match PG_CONTAINER in packages/cli/src/docker_env.rs
  let containerName = "envio-postgres"
  let psqlExecOptions: NodeJs.ChildProcess.execOptions = {
    env: Dict.fromArray([("PGPASSWORD", pgPassword), ("PATH", %raw(`process.env.PATH`))]),
  }

  let cacheDirPath = NodeJs.Path.resolve([
    // Right at the project root
    ".envio",
    "cache",
  ])

  // The metric label, the `storage` field on this backend's logs, and the
  // storage record's own name are all the same string.
  let storageName = "postgres"

  let indexManager = IndexManager.make()
  let setQueryCache = makeSetQueryCache()

  let loadCatalogRows = (sql, ~indexName=?) =>
    sql
    ->Postgres.unsafe(IndexCatalog.makeQuery(~pgSchema, ~indexName?))
    ->Promise.thenResolve(rows => rows->S.parseOrThrow(IndexCatalog.rowsSchema))

  // The whole-schema snapshot, taken on a clean initialize and on every resume.
  // Individual indexes are re-read from the catalog as they are built, so this
  // is the only point where the full listing is needed.
  let refreshIndexCatalog = async () => {
    let rows = await sql->loadCatalogRows
    indexManager->IndexManager.reload(~rows)
  }

  let reloadIndexCatalog = async () => {
    let catalog = await refreshIndexCatalog()
    switch catalog->IndexCatalog.invalidNames {
    | [] => ()
    | invalidIndexNames =>
      Logging.warn({
        "storage": storageName,
        "msg": `Ignoring invalid PostgreSQL indexes in schema "${pgSchema}". They can't serve queries, so the indexer builds its own alongside them.`,
        "indexes": invalidIndexNames,
      })
    }
  }

  let isInitialized = async () => {
    let envioTables = await sql->Postgres.unsafe(
      `SELECT table_schema FROM information_schema.tables WHERE table_schema = '${pgSchema}' AND (table_name = '${// This is for indexer before envio@2.28
        "event_sync_state"}' OR table_name = '${InternalTable.Chains.table.tableName}');`,
    )
    envioTables->Utils.Array.notEmpty
  }

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

  // Each indexer counts the effect-cache tables in its own schema. The counts
  // are computed here per table rather than through a shared SQL helper so
  // indexers isolated by schema in one database never touch each other's state.
  let queryCacheTableInfo = async (): array<schemaCacheTableInfo> => {
    let tableNames: array<schemaTableName> = await sql->Postgres.unsafe(
      makeEffectCacheTableNamesQuery(~pgSchema),
    )
    await tableNames
    ->Array.map(async ({tableName}) => {
      let rows: array<cacheRowCount> = await sql->Postgres.unsafe(
        makeCacheRowCountQuery(~pgSchema, ~tableName),
      )
      ({tableName, count: (rows->Array.getUnsafe(0)).count}: schemaCacheTableInfo)
    })
    ->Promise.all
  }

  let restoreEffectCache = async (~withUpload) => {
    if withUpload {
      // Try to restore cache tables from the .envio/cache TSV files
      switch await scanCacheDir() {
      | [] => Logging.info("No cache found to upload.")
      | entries =>
        switch await getConnectedPsqlExec(~pgUser, ~pgHost, ~pgDatabase, ~pgPort, ~containerName) {
        | Ok(psqlExec) =>
          let _ = await entries
          ->Array.map(((table, inputFile)) => {
            sql
            ->Postgres.unsafe(makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false))
            ->Promise.then(() => {
              let command = `${psqlExec} -c 'COPY "${pgSchema}"."${table.tableName}" FROM STDIN WITH (FORMAT text, HEADER);' < ${inputFile}`

              Promise.make(
                (resolve, reject) => {
                  NodeJs.ChildProcess.execWithOptions(
                    command,
                    psqlExecOptions,
                    (~error, ~stdout, ~stderr as _) => {
                      switch error {
                      | Value(error) => reject(error)
                      | Null => resolve(stdout)
                      }
                    },
                  )
                },
              )
            })
          })
          ->Promise.all
          Logging.info("Successfully uploaded cache.")
        | Error(message) =>
          Logging.error(`Failed to upload cache, continuing without it. ${message}`)
        }
      }
    }

    let cacheTableInfo = await queryCacheTableInfo()

    if withUpload && cacheTableInfo->Utils.Array.notEmpty {
      // Integration with other tools like Hasura
      switch onNewTables {
      | Some(onNewTables) =>
        await onNewTables(
          ~tableNames=cacheTableInfo->Array.map(info => {
            info.tableName
          }),
        )
      | None => ()
      }
    }

    let cache = Dict.make()
    cacheTableInfo->Array.forEach(({tableName, count}) => {
      switch Internal.EffectCache.fromTableName(tableName) {
      | Some((effectName, scope)) =>
        cache->Dict.set(
          tableName,
          ({effectName, scope, tableName, count}: Persistence.effectCacheRecord),
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
    // Per-entity storage routing: PG owns tables only for entities that
    // opted into Postgres; the sink mirrors only those that opted into
    // ClickHouse.
    let pgEntities = entities->Array.filter((e: Internal.entityConfig) => e.storage.postgres)
    let chEntities = entities->Array.filter((e: Internal.entityConfig) => e.storage.clickhouse)

    let schemaTableNames: array<schemaTableName> = await sql->Postgres.unsafe(
      makeSchemaTableNamesQuery(~pgSchema),
    )

    // The initialization query will completely drop the schema and recreate it from scratch.
    // So we need to check if the schema is not used for anything else than envio.
    if (
      // Should pass with existing schema with no tables
      // This might happen when used with public schema
      // which is automatically created by postgres.
      schemaTableNames->Utils.Array.notEmpty &&
        // Otherwise should throw if there's a table, but no envio specific one
        // This means that the schema is used for something else than envio.
        !(
          schemaTableNames->Array.some(table =>
            table.tableName === InternalTable.Chains.table.tableName ||
              table.tableName === "event_sync_state"
          )
        )
    ) {
      JsError.throwWithMessage(
        `Cannot run Envio migrations on PostgreSQL schema "${pgSchema}" because it contains non-Envio tables. Running migrations would delete all data in this schema.\n\nTo resolve this:\n1. If you want to use this schema, first backup any important data, then drop it with: "pnpm envio local db-migrate down"\n2. Or specify a different schema name by setting the "ENVIO_PG_SCHEMA" environment variable\n3. Or manually drop the schema in your database if you're certain the data is not needed.`,
      )
    }

    // Call sink.initialize before executing PG queries
    switch sink {
    | Some(sink) => await sink.initialize(~entities=chEntities)
    | None => ()
    }

    let queries = makeInitializeTransaction(
      ~pgSchema,
      ~pgUser,
      ~entities=pgEntities,
      ~enums,
      ~chainConfigs,
      ~isEmptyPgSchema=schemaTableNames->Utils.Array.isEmpty,
      ~isHasuraEnabled,
      ~deferSchemaIndexes=true,
      ~chainIdMode,
    )
    // Execute all queries within a single transaction for integrity.
    // The envio_info row is written in the same transaction so a successful
    // initialize is atomic — no schema can come up without the matching row.
    let rowsByChain =
      chainConfigs->Array.map(chainConfig =>
        chainConfig->ChainState.configStorageRows(~ecosystem, ~contractMapping)
      )
    let configAddressRows = rowsByChain->Array.flat

    // The contract mapping and the config's addresses join the schema in the
    // same transaction as envio_info: a schema that comes up without them would
    // resume against ids nothing assigned.
    let _ = await sql->Postgres.beginSql(async sql => {
      // Promise.all might be not safe to use here,
      // but it's just how it worked before.
      let _ = await Promise.all(queries->Array.map(query => sql->Postgres.unsafe(query)))
      await InternalTable.EnvioInfo.write(sql, ~pgSchema, ~envioInfo)
      await InternalTable.EnvioContracts.insert(
        sql,
        ~pgSchema,
        ~contractNames=contractMapping->ContractMapping.names,
      )
      if configAddressRows->Utils.Array.notEmpty {
        await InternalTable.EnvioAddresses.insert(
          sql,
          ~pgSchema,
          ~rows=configAddressRows,
          ~chainIdMode,
        )
      }
    })

    let cache = await restoreEffectCache(~withUpload=true)

    await reloadIndexCatalog()

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
      envioInfo: Some(envioInfo),
      chains: chainConfigs->Array.mapWithIndex((
        chainConfig,
        idx,
      ): Persistence.initialChainState => {
        id: chainConfig.id,
        startBlock: chainConfig.startBlock,
        endBlock: chainConfig.endBlock,
        maxReorgDepth: chainConfig.maxReorgDepth,
        progressBlockNumber: -1,
        numEventsProcessed: 0.,
        firstEventBlockNumber: None,
        timestampCaughtUpToHeadOrEndblock: None,
        addressRows: rowsByChain->Array.getUnsafe(idx)->AddressRows.seedRowsOf,
        sourceBlockNumber: 0,
      }),
      checkpointId: InternalTable.Checkpoints.initialCheckpointId,
    }
  }

  let loadOrThrow = async (~filter: EntityFilter.t, ~table: Table.table) => {
    let params = []
    let condition = makeFilterCondition(~filter, ~table, ~params)
    switch await sql->Postgres.preparedUnsafe(
      makeLoadQuery(~pgSchema, ~tableName=table.tableName, ~condition),
      params->Obj.magic,
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
    let rec collect = (filter: EntityFilter.t) =>
      switch filter {
      | Eq({fieldName}) | Gt({fieldName}) | Lt({fieldName}) | In({fieldName}) =>
        switch queryFields->Utils.Dict.dangerouslyGetNonOption(fieldName) {
        | Some({pgDbFieldName}) =>
          if !(seen->Utils.Set.has(pgDbFieldName)) {
            seen->Utils.Set.add(pgDbFieldName)->ignore
            columns->Array.push(pgDbFieldName)->ignore
          }
        | None => ()
        }
      | And({filters}) => filters->Array.forEach(collect)
      }
    filters->Array.forEach(collect)
    columns
  }

  // Runs a prepared build's DDL and reads the index back from pg_catalog before
  // it counts as existing. `sql` is the transaction's handle when there is one,
  // so a failed verification rolls the DDL back with it.
  let runAndVerify = async (sql, prepared: IndexManager.prepared) => {
    // Sequential rather than Promise.all: inside a transaction they share one
    // connection, and a rebuild's DROP has to land before its CREATE.
    for idx in 0 to prepared.queries->Array.length - 1 {
      let _ = await sql->Postgres.unsafe(prepared.queries->Array.getUnsafe(idx))
    }
    let rows = await sql->loadCatalogRows(~indexName=prepared.name)
    prepared->IndexManager.verifyOrThrow(~rows, ~pgSchema)
  }

  // A build outside a transaction can commit its DDL and still fail — the
  // read-back is a second round trip. Re-reading the index puts the catalog
  // back in step, so the next attempt plans against what the database holds
  // instead of retrying a create that can only raise "already exists".
  //
  // If this read fails too, the next attempt does waste a create before landing
  // here again — bounded, and it recovers as soon as the database answers.
  let resyncIndex = async name =>
    switch await sql->loadCatalogRows(~indexName=name) {
    | rows => indexManager->IndexManager.resync(~name, ~rows)
    | exception exn =>
      Logging.debug({
        "storage": storageName,
        "msg": `Could not re-read the index "${name}" after a failed build. The next attempt reads it again.`,
        "err": exn->Utils.prettifyExn,
      })
    }

  let ensureQueryIndexes = async (~table: Table.table, ~filters: array<EntityFilter.t>) => {
    let columns = filterColumns(~table, ~filters)
    let _ = await columns
    ->Array.map(column => {
      let definition = IndexDefinition.single(~tableName=table.tableName, ~column)
      indexManager
      ->IndexManager.ensure(~definition, ~coverage=LeadingColumns, ~build=async () => {
        // Resolved before logging so a rebuild is reported as one, and an
        // unrelated index holding the name fails before any DDL runs.
        switch indexManager->IndexManager.prepare(
          ~definition,
          ~coverage=LeadingColumns,
          ~pgSchema,
        ) {
        | None => ()
        | Some(prepared) =>
          let verb = prepared.isRebuild ? "Rebuilding unusable index" : "Creating index"
          // Logged from inside the build so it reports the one request that
          // actually creates the index, not the ones waiting on it.
          Logging.info({
            "storage": storageName,
            "msg": `${verb} "${prepared.name}" to serve a getWhere query on "${table.tableName}". Writes to the table are paused until it completes. ${slowOnLargeDatabaseNotice}`,
          })
          let timeRef = Performance.now()
          let entry = await sql->runAndVerify(prepared)
          indexManager->IndexManager.record(entry)
          Logging.info({
            "storage": storageName,
            "msg": `Index "${prepared.name}" is ready after ${timeRef->formatSeconds}s. Resuming indexing.`,
          })
        }
      })
      // A failed build records nothing, so the next getWhere retries. Meanwhile
      // the query still runs — just without the index.
      ->Promise.catch(async exn => {
        Logging.warn({
          "storage": storageName,
          "msg": `Failed to create an index on "${table.tableName}"("${column}") for a getWhere query. The query runs without it.`,
          "err": exn->Utils.prettifyExn,
        })
        await resyncIndex(definition->IndexDefinition.name)
      })
    })
    ->Promise.all
  }

  // Goes through `IndexManager.ensure`, unlike `finalizeBackfill` below: that
  // one runs with processing paused, while this runs on a resumed indexer that
  // is already ready, so handlers may be issuing getWhere queries alongside it
  // and the per-table queues are what keep the two from colliding. Nothing here
  // writes `ready_at` — the chains already carry theirs.
  let ensureSchemaIndexes = async (~entities: array<Internal.entityConfig>) => {
    let schemaIndexes = getSchemaIndexes(
      ~entities=entities->Array.filter((e: Internal.entityConfig) => e.storage.postgres),
    )

    let _ = await schemaIndexes
    ->Array.map(definition =>
      indexManager
      ->IndexManager.ensure(~definition, ~coverage=Exact, ~build=async () => {
        switch indexManager->IndexManager.prepare(~definition, ~coverage=Exact, ~pgSchema) {
        | None => ()
        | Some(prepared) =>
          let verb = prepared.isRebuild ? "Rebuilding unusable index" : "Creating missing index"
          Logging.info({
            "storage": storageName,
            "msg": `${verb} "${prepared.name}" the schema promises but the database no longer has. Writes to the table are paused until it completes. ${slowOnLargeDatabaseNotice}`,
          })
          let timeRef = Performance.now()
          let entry = await sql->runAndVerify(prepared)
          indexManager->IndexManager.record(entry)
          Logging.info({
            "storage": storageName,
            "msg": `Index "${prepared.name}" is ready after ${timeRef->formatSeconds}s.`,
          })
        }
      })
      ->Promise.catch(async exn => {
        Logging.warn({
          "storage": storageName,
          "msg": `Failed to restore the schema index "${definition->IndexDefinition.name}". Queries relying on it run unindexed until the next restart.`,
          "err": exn->Utils.prettifyExn,
        })
        await resyncIndex(definition->IndexDefinition.name)
      })
    )
    ->Promise.all
  }

  // Unlike `ensureQueryIndexes`, this doesn't go through `IndexManager.ensure`.
  // It's safe because the caller guarantees exclusivity — `FinalizeBackfill.run`
  // is reached from the processing loop with processing already paused, so no
  // handler can be running a getWhere.
  //
  // Each index is built on its own rather than in one transaction with
  // `ready_at`: a build that dies half way through a large schema would
  // otherwise roll back every index before it and make the retry start over.
  let finalizeBackfill = async (
    ~entities: array<Internal.entityConfig>,
    ~chainIds: array<ChainId.t>,
    ~readyAt: Date.t,
  ) => {
    let schemaIndexes = getSchemaIndexes(
      ~entities=entities->Array.filter((e: Internal.entityConfig) => e.storage.postgres),
    )

    // Resolved up front so a name held by an unrelated index fails before any
    // DDL runs, rather than part way through the set.
    //
    // `Exact`, so the set built here is decided by the schema alone: matching a
    // declared index against a composite that happens to lead with the same
    // column would make a fresh database and an upgraded one end up holding
    // different tables.
    let missing =
      schemaIndexes->Array.filterMap(definition =>
        indexManager->IndexManager.prepare(~definition, ~coverage=Exact, ~pgSchema)
      )

    switch missing->Array.filter((prepared: IndexManager.prepared) => prepared.isRebuild) {
    | [] => ()
    | rebuilt =>
      Logging.warn({
        "storage": storageName,
        "msg": `PostgreSQL reports ${rebuilt
          ->Array.length
          ->Int.toString} of the indexer's own indexes as invalid, so they can't serve queries. Rebuilding them.`,
        "indexes": rebuilt->Array.map((prepared: IndexManager.prepared) => prepared.name),
      })
    }

    switch missing {
    | [] =>
      Logging.info({
        "storage": storageName,
        "msg": `All ${schemaIndexes
          ->Array.length
          ->Int.toString} schema indexes are already in place. Marking the indexer ready.`,
      })
    | _ =>
      Logging.info({
        "storage": storageName,
        "msg": `Creating the ${missing
          ->Array.length
          ->Int.toString} remaining schema indexes before the indexer reports ready. Writes are paused until they are committed. ${slowOnLargeDatabaseNotice}`,
        "indexes": missing->Array.map((prepared: IndexManager.prepared) => prepared.name),
      })
    }
    let timeRef = Performance.now()

    // Sequential, one committed index at a time: whatever is built before a
    // failure stays built and recorded, so the retry owes only the rest.
    for idx in 0 to missing->Array.length - 1 {
      let prepared = missing->Array.getUnsafe(idx)
      switch await sql->runAndVerify(prepared) {
      | entry => indexManager->IndexManager.record(entry)
      | exception exn =>
        // The DDL is outside a transaction, so a create that commits and then
        // fails its read-back leaves the index in place and unrecorded.
        // Re-reading it means the retry plans against the database rather than
        // replaying a create that can only raise "already exists".
        await resyncIndex(prepared.name)
        throw(exn)
      }
    }

    // Reached only once every definition is verified against pg_catalog, so a
    // crash either leaves `ready_at` null and the retry finds the indexes
    // already built, or commits readiness the schema backs.
    //
    // One transaction for the whole set: readiness is an indexer-wide fact, and
    // a crash part way through would otherwise leave some chains stamped and
    // some not, reporting the indexer as half ready.
    let setReadyAtQuery = InternalTable.Chains.makeSetReadyAtQuery(~pgSchema)
    let _ = await sql->Postgres.beginSql(async sql => {
      for idx in 0 to chainIds->Array.length - 1 {
        let _ = await sql->Postgres.preparedUnsafe(
          setReadyAtQuery,
          [
            readyAt->(Utils.magic: Date.t => unknown),
            chainIds->Array.getUnsafe(idx)->(Utils.magic: ChainId.t => unknown),
          ]->(Utils.magic: array<unknown> => unknown),
        )
      }
    })

    Logging.info({
      "storage": storageName,
      "msg": `Committed ${missing
        ->Array.length
        ->Int.toString} schema indexes and the ready timestamp in ${timeRef->formatSeconds}s.`,
    })
  }

  let setOrThrow = (
    type item,
    ~items: array<item>,
    ~table: Table.table,
    ~itemSchema: S.t<item>,
  ) => {
    setOrThrow(
      sql,
      ~items=items->(Utils.magic: array<item> => array<unknown>),
      ~table,
      ~itemSchema=itemSchema->S.toUnknown,
      ~pgSchema,
      ~setQueryCache,
      ~chainIdMode,
    )
  }

  let setEffectCacheOrThrow = async (
    ~table: Table.table,
    ~itemSchema,
    ~items: array<Internal.effectCacheItem>,
    ~initialize: bool,
  ) => {
    if initialize {
      let _ = await sql->Postgres.unsafe(
        makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false),
      )
      // Integration with other tools like Hasura
      switch onNewTables {
      | Some(onNewTables) => await onNewTables(~tableNames=[table.tableName])
      | None => ()
      }
    }

    await setOrThrow(~items, ~table, ~itemSchema)
  }

  let dumpEffectCache = async () => {
    try {
      let cacheTableInfo = (await queryCacheTableInfo())->Array.filter(i => i.count > 0)

      if cacheTableInfo->Utils.Array.notEmpty {
        // Create .envio/cache directory if it doesn't exist
        try {
          await NodeJs.Fs.Promises.access(cacheDirPath)
        } catch {
        | _ =>
          // Create directory if it doesn't exist
          await NodeJs.Fs.Promises.mkdir(~path=cacheDirPath, ~options={recursive: true})
        }

        // Command for testing. Run from project root:
        // docker exec -i -u postgres envio-{indexerName}-postgres psql -d envio-dev -c 'COPY "public"."envio_effect_getTokenMetadata" TO STDOUT (FORMAT text, HEADER);' > ../.envio/cache/getTokenMetadata.tsv

        switch await getConnectedPsqlExec(~pgUser, ~pgHost, ~pgDatabase, ~pgPort, ~containerName) {
        | Ok(psqlExec) => {
            Logging.info(
              `Dumping cache: ${cacheTableInfo
                ->Array.map(({tableName, count}) =>
                  tableName ++ " (" ++ count->Int.toString ++ " rows)"
                )
                ->Array.joinUnsafe(", ")}`,
            )

            let promises = cacheTableInfo->Array.map(async ({tableName}) => {
              switch Internal.EffectCache.fromTableName(tableName) {
              | Some((effectName, scope)) =>
                // Reverse mapping: chain-scoped caches dump into a per-chain
                // subdirectory, created here if needed.
                let outputPath = NodeJs.Path.join(
                  cacheDirPath,
                  Internal.EffectCache.toCachePath(~effectName, ~scope),
                )
                let _ = await NodeJs.Fs.Promises.mkdir(
                  ~path=NodeJs.Path.dirname(outputPath->NodeJs.Path.toString),
                  ~options={recursive: true},
                )
                let outputFile = outputPath->NodeJs.Path.toString

                let command = `${psqlExec} -c 'COPY "${pgSchema}"."${tableName}" TO STDOUT WITH (FORMAT text, HEADER);' > ${outputFile}`

                await Promise.make((resolve, reject) => {
                  NodeJs.ChildProcess.execWithOptions(
                    command,
                    psqlExecOptions,
                    (~error, ~stdout, ~stderr as _) => {
                      switch error {
                      | Value(error) => reject(error)
                      | Null => resolve(stdout)
                      }
                    },
                  )
                })
              | None => ""
              }
            })

            let _ = await promises->Promise.all
            Logging.info(`Successfully dumped cache to ${cacheDirPath->NodeJs.Path.toString}`)
          }
        | Error(message) => Logging.error(`Failed to dump cache. ${message}`)
        }
      }
    } catch {
    | exn => Logging.errorWithExn(exn->Utils.prettifyExn, `Failed to dump cache.`)
    }
  }

  let resumeInitialState = async (): Persistence.initialState => {
    let (cache, chains, checkpointIdResult, reorgCheckpoints, (envioInfo, contractMapping)) = await Promise.all5((
      restoreEffectCache(~withUpload=false),
      InternalTable.Chains.getInitialState(
        sql,
        ~pgSchema,
      )->Promise.thenResolve(rawInitialStates => {
        rawInitialStates->Array.map((rawInitialState): Persistence.initialChainState => {
          id: rawInitialState.id,
          startBlock: rawInitialState.startBlock,
          endBlock: rawInitialState.endBlock->Null.toOption,
          maxReorgDepth: rawInitialState.maxReorgDepth,
          firstEventBlockNumber: rawInitialState.firstEventBlockNumber->Null.toOption,
          timestampCaughtUpToHeadOrEndblock: rawInitialState.timestampCaughtUpToHeadOrEndblock->Null.toOption,
          numEventsProcessed: rawInitialState.numEventsProcessed,
          progressBlockNumber: rawInitialState.progressBlockNumber,
          addressRows: rawInitialState.addressRows,
          sourceBlockNumber: rawInitialState.sourceBlockNumber,
        })
      }),
      sql
      ->Postgres.unsafe(InternalTable.Checkpoints.makeCommitedCheckpointIdQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<{"id": string}>>),
      sql
      ->Postgres.unsafe(InternalTable.Checkpoints.makeGetReorgCheckpointsQuery(~pgSchema))
      ->(
        Utils.magic: promise<array<unknown>> => promise<
          array<{
            "id": string,
            "chain_id": int,
            "block_number": int,
            "block_hash": string,
          }>,
        >
      ),
      Promise.all2((
        InternalTable.EnvioInfo.read(sql, ~pgSchema),
        InternalTable.EnvioContracts.read(sql, ~pgSchema),
      ))->Promise.thenResolve(((info, names)) =>
        // Both tables join the schema in one transaction. A missing mapping
        // means an older envio wrote this schema, so treat the snapshot as
        // unreadable rather than decoding address rows against ids nothing assigned.
        switch (info, names) {
        | (Some(info), Some(names)) => (Some(info), ContractMapping.fromStoredNames(names))
        | _ => (None, ContractMapping.empty)
        }
      ),
    ))

    await reloadIndexCatalog()

    let checkpointId = (checkpointIdResult->Array.getUnsafe(0))["id"]->BigInt.fromStringOrThrow

    // Convert string checkpoint IDs from DB to bigint
    let reorgCheckpoints = Array.map(reorgCheckpoints, (raw): Internal.reorgCheckpoint => {
      checkpointId: raw["id"]->BigInt.fromStringOrThrow,
      chainId: raw["chain_id"]->ChainId.normalizeOrThrow,
      blockNumber: raw["block_number"],
      blockHash: raw["block_hash"],
    })

    // Resume sink if present - needed to rollback any reorg changes
    switch sink {
    | Some(sink) => await sink.resume(~checkpointId, ~chains)
    | None => ()
    }

    {
      cleanRun: false,
      reorgCheckpoints,
      cache,
      chains,
      checkpointId,
      contractMapping,
      envioInfo,
    }
  }

  let reset = async () => {
    let query = `DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;`
    await sql->Postgres.unsafe(query)->Utils.Promise.ignoreValue
  }

  let setChainMeta = chainsData =>
    InternalTable.Chains.setMeta(sql, ~pgSchema, ~chainsData)->Promise.thenResolve(_ =>
      %raw(`undefined`)
    )

  let pruneStaleCheckpoints = (~safeCheckpointId) =>
    InternalTable.Checkpoints.pruneStaleCheckpoints(sql, ~pgSchema, ~safeCheckpointId)

  let pruneStaleEntityHistory = (~entityName, ~entityIndex, ~chainIdColumn, ~safeCheckpointId) =>
    EntityHistory.pruneStaleEntityHistory(
      sql,
      ~pgSchema,
      ~entityName,
      ~entityIndex,
      ~chainIdColumn,
      ~safeCheckpointId,
    )

  let getRollbackTargetCheckpoint = (~reorgChainId, ~lastKnownValidBlockNumber) =>
    InternalTable.Checkpoints.getRollbackTargetCheckpoint(
      sql,
      ~pgSchema,
      ~reorgChainId,
      ~lastKnownValidBlockNumber,
    )

  let getRollbackProgressDiff = (~scope, ~rollbackTargetCheckpointId) =>
    InternalTable.Checkpoints.getRollbackProgressDiff(
      sql,
      ~pgSchema,
      ~scope,
      ~rollbackTargetCheckpointId,
    )

  let getRollbackData = async (
    ~entityConfig: Internal.entityConfig,
    ~scope,
    ~rollbackTargetCheckpointId,
  ) => {
    let params = scope->RollbackScope.params(~targetCheckpointId=rollbackTargetCheckpointId)
    let (removedIdRows, rollbackRows) = await Promise.all2((
      // Get IDs of entities that should be deleted (created after rollback target with no prior history)
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackRemovedIdsQuery(~entityConfig, ~pgSchema, ~scope),
        params,
      )
      ->(Utils.magic: promise<unknown> => promise<array<unknown>>),
      // Get the latest pre-target row, including its SET or DELETE action.
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackPreTargetRowsQuery(~entityConfig, ~pgSchema, ~scope),
        params,
      )
      ->(Utils.magic: promise<unknown> => promise<array<unknown>>),
    ))

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
      ->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema)
      ->(Utils.magic: array<unknown> => array<Internal.entity>),
    )
  }

  let writeBatchMethod = async (
    ~batch,
    ~rollback,
    ~isInReorgThreshold,
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

    // Initialize sink if configured
    let sinkPromise = switch sink {
    | Some(sink) => {
        let timerRef = Performance.now()
        Some(
          sink.writeBatch(~batch, ~updatedEntities=chUpdates)
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
      sql,
      ~batch,
      ~pgSchema,
      ~setQueryCache,
      ~rollback,
      ~isInReorgThreshold,
      ~config,
      ~allEntities,
      ~setEffectCacheOrThrow,
      ~updatedEffectsCache,
      ~updatedEntities=pgUpdates,
      ~registeredAddresses,
      ~sinkPromise,
      ~chainMetaData,
    )
    onWrite(~storage=storageName, ~timeSeconds=primaryTimerRef->Performance.secondsSince)
  }

  let close = () => sql->Postgres.endSql

  {
    name: storageName,
    isInitialized,
    initialize,
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
  ~sql=makeClient(),
  ~pgSchema=Env.Db.publicSchema,
  ~isHasuraEnabled=Env.Hasura.enabled,
) => {
  make(
    ~sql,
    ~pgSchema,
    ~pgHost=Env.Db.host,
    ~pgUser=Env.Db.user,
    ~pgPort=Env.Db.port,
    ~pgDatabase=Env.Db.database,
    ~pgPassword=Env.Db.password,
    ~chainIdMode=config.chainIdMode,
    ~ecosystem=config.ecosystem.name,
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
    ~onNewTables=?{
      if isHasuraEnabled {
        Some(
          (~tableNames) => {
            Hasura.trackTables(
              ~endpoint=Env.Hasura.graphqlEndpoint,
              ~auth={
                role: Env.Hasura.role,
                secret: Env.Hasura.secret,
              },
              ~pgSchema,
              ~tableConfigs=tableNames->Array.map(tableName => {
                Hasura.tableName,
                description: None,
                columnConfigs: dict{},
              }),
            )->Promise.catch(err => {
              Logging.errorWithExn(
                err->Utils.prettifyExn,
                `Error tracking new tables`,
              )->Promise.resolve
            })
          },
        )
      } else {
        None
      }
    },
    ~isHasuraEnabled,
  )
}

let makePersistenceFromConfig = (~config: Config.t, ~storage=makeStorageFromEnv(~config)) => {
  Persistence.make(~userEntities=config.userEntities, ~allEnums=config.allEnums, ~storage)
}
