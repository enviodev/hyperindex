let getCacheRowCountFnName = "get_cache_row_count"

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

let makeCreateIndexQuery = (~tableName, ~indexFields, ~pgSchema) => {
  let indexName = tableName ++ "_" ++ indexFields->Array.joinUnsafe("_")

  // Case for indexer before envio@2.28
  let index = indexFields->Array.map(idx => `"${idx}"`)->Array.joinUnsafe(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${pgSchema}"."${tableName}"(${index});`
}

let directionToSql = (direction: Table.indexFieldDirection) =>
  switch direction {
  | Asc => ""
  | Desc => " DESC"
  }

let directionToIndexName = (direction: Table.indexFieldDirection) =>
  switch direction {
  | Asc => ""
  | Desc => "_desc"
  }

let makeCreateCompositeIndexQuery = (
  ~tableName,
  ~indexFields: array<Table.compositeIndexField>,
  ~pgSchema,
) => {
  let indexName =
    tableName ++
    "_" ++
    indexFields
    ->Array.map(f => f.fieldName ++ directionToIndexName(f.direction))
    ->Array.joinUnsafe("_")
  let index =
    indexFields
    ->Array.map(f => `"${f.fieldName}"${directionToSql(f.direction)}`)
    ->Array.joinUnsafe(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${pgSchema}"."${tableName}"(${index});`
}

let makeCreateTableIndicesQuery = (table: Table.table, ~pgSchema) => {
  let tableName = table.tableName
  let createIndex = indexField =>
    makeCreateIndexQuery(~tableName, ~indexFields=[indexField], ~pgSchema)
  let createCompositeIndex = indexFields => {
    makeCreateCompositeIndexQuery(~tableName, ~indexFields, ~pgSchema)
  }

  let singleIndices = table->Table.getSingleIndices
  let compositeIndices = table->Table.getCompositeIndices

  singleIndices->Array.map(createIndex)->Array.joinUnsafe("\n") ++
    compositeIndices->Array.map(createCompositeIndex)->Array.joinUnsafe("\n")
}

let makeCreateTableQuery = (table: Table.table, ~pgSchema, ~isNumericArrayAsText) => {
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getPgDbFieldName

      {
        `"${fieldName}" ${Table.getPgFieldType(
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
      : ""});`
}

// Per-chain (non cross-chain) entities have a chain id column which is not
// part of the entity schema — writes stamp the value onto entity copies, so
// inserts need a schema with the chainId field appended.
let getWriteSchema: Internal.entityConfig => S.t<
  Internal.entity,
> = Utils.WeakMap.memoize((entityConfig: Internal.entityConfig) =>
  if entityConfig.crossChain {
    entityConfig.schema
  } else {
    switch entityConfig.schema->S.classify {
    | Object({items}) =>
      S.schema(s => {
        let dict = Dict.make()
        items->Array.forEach(({location, schema}) => dict->Dict.set(location, s.matches(schema)))
        dict->Dict.set("chainId", s.matches(S.int->S.toUnknown))
        dict
      })->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.entity>)
    | _ =>
      JsError.throwWithMessage(
        `Failed creating write schema for entity "${entityConfig.name}". Expected an object schema.`,
      )
    }
  }
)

let withChainId = (entity: Internal.entity, ~chainId: int): Internal.entity => {
  let copy = entity->(Utils.magic: Internal.entity => dict<unknown>)->Dict.copy
  copy->Dict.set("chainId", chainId->(Utils.magic: int => unknown))
  copy->(Utils.magic: dict<unknown> => Internal.entity)
}

// Maps each checkpoint id to the chain it belongs to (the same data the
// envio_checkpoints table stores), so the chain id never has to be threaded
// through the in-memory layer — it's recovered from each change's checkpoint.
let makeChainIdByCheckpointId = (batch: Batch.t) => {
  let map = Dict.make()
  for idx in 0 to batch.checkpointIds->Array.length - 1 {
    map->Dict.set(
      batch.checkpointIds->Array.getUnsafe(idx)->BigInt.toString,
      batch.checkpointChainIds->Array.getUnsafe(idx),
    )
  }
  map
}

// The chain_id db column for per-chain entities (None for cross-chain).
let chainIdColumn = (entityConfig: Internal.entityConfig) =>
  switch entityConfig.table->Table.getFieldByName("chainId") {
  | Some(Field(field)) if !entityConfig.crossChain => Some(field->Table.getPgDbFieldName)
  | _ => None
  }

// Stamps the chain id onto Set changes of per-chain entities. The chain comes
// from the per-chain partition the group was flushed from, so it covers
// rollback-restored changes (whose synthetic checkpoint isn't in the batch) too.
let stampPerChainIds = (~updatedEntities: array<Persistence.updatedEntity>): array<
  Persistence.updatedEntity,
> => {
  updatedEntities->Array.map((update: Persistence.updatedEntity) =>
    switch update.chainId {
    | None => update
    | Some(chainId) => {
        ...update,
        changes: update.changes->Array.map(change =>
          switch change {
          | Set({entityId, entity, checkpointId}) =>
            Change.Set({entityId, checkpointId, entity: entity->withChainId(~chainId)})
          | Delete(_) => change
          }
        ),
      }
    }
  )
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
          // The per-chain chain id column is part of the entity's identity, so it
          // stays a non-nullable part of the history pk: (id, chain_id,
          // checkpoint). This keeps the checkpoint-0 backfill baseline distinct
          // per chain when the same id exists on multiple chains.
          | _ if field.isPrimaryKey => {...field, isIndex: false}->Table.Field->Some
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
      //ignore composite indices
      let table = Table.mkTable(
        historyTableName,
        ~fields=dataFields->Array.concat([checkpointIdField, actionField]),
      )

      // The write schema so per-chain entities record the chain id in history
      // rows — rollback restore reads it back from there.
      let setChangeSchema = EntityHistory.makeSetUpdateSchema(getWriteSchema(entityConfig))

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

let makeInitializeTransaction = (
  ~pgSchema,
  ~pgUser,
  ~isHasuraEnabled,
  ~chainConfigs=[],
  ~entities=[],
  ~enums=[],
  ~isEmptyPgSchema=false,
) => {
  let generalTables = [
    InternalTable.Chains.table,
    InternalTable.EnvioInfo.table,
    InternalTable.Checkpoints.table,
    InternalTable.RawEvents.table,
  ]

  let allTables = generalTables->Array.copy
  let allEntityTables = []
  entities->Array.forEach((entityConfig: Internal.entityConfig) => {
    allEntityTables->Array.push(entityConfig.table)->ignore
    allTables->Array.push(entityConfig.table)->ignore
    allTables->Array.push(getEntityHistory(~entityConfig).table)->ignore
  })
  let derivedSchema = Schema.make(allEntityTables)

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
  allTables->Array.forEach((table: Table.table) => {
    query :=
      query.contents ++
      "\n" ++
      makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=isHasuraEnabled)
  })

  // Then batch all indices (better performance when tables exist)
  allTables->Array.forEach((table: Table.table) => {
    let indices = makeCreateTableIndicesQuery(table, ~pgSchema)
    if indices !== "" {
      query := query.contents ++ "\n" ++ indices
    }
  })

  // Add derived indices
  entities->Array.forEach((entity: Internal.entityConfig) => {
    entity.table
    ->Table.getDerivedFromFields
    ->Array.forEach(derivedFromField => {
      let indexField =
        derivedSchema->Schema.getDerivedFromPgFieldName(derivedFromField)->Utils.unwrapResultExn
      query :=
        query.contents ++
        "\n" ++
        makeCreateIndexQuery(
          ~tableName=derivedFromField.derivedFromEntity,
          ~indexFields=[indexField],
          ~pgSchema,
        )
    })
  })

  // Create views for Hasura integration
  query := query.contents ++ "\n" ++ InternalTable.Views.makeMetaViewQuery(~pgSchema)
  query := query.contents ++ "\n" ++ InternalTable.Views.makeChainMetadataViewQuery(~pgSchema)

  // Populate initial chain data
  switch InternalTable.Chains.makeInitialValuesQuery(~pgSchema, ~chainConfigs) {
  | Some(initialChainsValuesQuery) => query := query.contents ++ "\n" ++ initialChainsValuesQuery
  | None => ()
  }

  [
    query.contents,
    `CREATE OR REPLACE FUNCTION ${getCacheRowCountFnName}(table_name text) 
RETURNS integer AS $$
DECLARE
  result integer;
BEGIN
  EXECUTE format('SELECT COUNT(*) FROM "${pgSchema}".%I', table_name) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;`,
  ]
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

let makeDeleteByIdQuery = (~pgSchema, ~tableName) => {
  `DELETE FROM "${pgSchema}"."${tableName}" WHERE id = $1;`
}

// Scopes the delete to one chain for per-chain entities, so deleting an id on
// one chain leaves the same id on other chains untouched.
let makeDeleteByIdsAndChainQuery = (~pgSchema, ~tableName, ~chainIdColumn) => {
  `DELETE FROM "${pgSchema}"."${tableName}" WHERE id = ANY($1::text[]) AND "${chainIdColumn}" = $2;`
}

let makeDeleteByIdsQuery = (~pgSchema, ~tableName) => {
  `DELETE FROM "${pgSchema}"."${tableName}" WHERE id = ANY($1::text[]);`
}

let makeLoadAllQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}";`
}

let makeInsertUnnestSetQuery = (~pgSchema, ~table: Table.table, ~itemSchema, ~isRawEvents) => {
  let {quotedFieldNames, quotedNonPrimaryFieldNames, arrayFieldTypes} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema)

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

let makeInsertValuesSetQuery = (~pgSchema, ~table: Table.table, ~itemSchema, ~itemsCount) => {
  let {quotedFieldNames, quotedNonPrimaryFieldNames} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema)

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

let makeTableBatchSetQuery = (~pgSchema, ~table: Table.table, ~itemSchema: S.t<'item>) => {
  let {dbSchema, hasArrayField} = table->Table.toSqlParams(~schema=itemSchema, ~pgSchema)

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
      "query": makeInsertUnnestSetQuery(~pgSchema, ~table, ~itemSchema, ~isRawEvents),
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

// WeakMap for caching table batch set queries
let setQueryCache = Utils.WeakMap.make()
let setOrThrow = async (sql, ~items, ~table: Table.table, ~itemSchema, ~pgSchema) => {
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
                makeInsertValuesSetQuery(~pgSchema, ~table, ~itemSchema, ~itemsCount=chunkSize),
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

let cacheTablePrefixLength = Internal.cacheTablePrefix->String.length

type schemaCacheTableInfo = {
  @as("table_name")
  tableName: string,
  @as("count")
  count: int,
}

let makeSchemaCacheTableInfoQuery = (~pgSchema) => {
  `SELECT 
    t.table_name,
    ${getCacheRowCountFnName}(t.table_name) as count
   FROM information_schema.tables t
   WHERE t.table_schema = '${pgSchema}' 
   AND t.table_name LIKE '${Internal.cacheTablePrefix}%';`
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

let deleteByIdsOrThrow = async (sql, ~pgSchema, ~ids, ~table: Table.table, ~chainId=?) => {
  let chainIdColumn = switch table->Table.getFieldByName("chainId") {
  | Some(Field(field)) => Some(field->Table.getPgDbFieldName)
  | _ => None
  }
  switch await (
    switch (chainId, chainIdColumn) {
    // Per-chain entity: scope the delete to this chain.
    | (Some(chainId), Some(chainIdColumn)) =>
      sql->Postgres.preparedUnsafe(
        makeDeleteByIdsAndChainQuery(~pgSchema, ~tableName=table.tableName, ~chainIdColumn),
        (ids, chainId)->Obj.magic,
      )
    | _ =>
      switch ids {
      | [_] =>
        sql->Postgres.preparedUnsafe(
          makeDeleteByIdQuery(~pgSchema, ~tableName=table.tableName),
          ids->Obj.magic,
        )
      | _ =>
        sql->Postgres.preparedUnsafe(
          makeDeleteByIdsQuery(~pgSchema, ~tableName=table.tableName),
          [ids]->Obj.magic,
        )
      }
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

let makeInsertDeleteUpdatesQuery = (~entityConfig: Internal.entityConfig, ~pgSchema) => {
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

  // Per-chain entities carry a non-nullable chain id in the history pk, so the
  // delete-update rows take it from unnest (derived from each delete's
  // checkpoint) rather than NULL.
  let chainIdCol = chainIdColumn(entityConfig)

  // Build the SELECT part: id from unnest, envio_checkpoint_id from unnest,
  // chain_id from unnest (per-chain), 'DELETE' for action, NULL for all other fields
  let selectParts = allHistoryFieldNames->Array.map(fieldName => {
    switch fieldName {
    | field if field == Table.idFieldName => `u.${Table.idFieldName}`
    | field if field == EntityHistory.checkpointIdFieldName =>
      `u.${EntityHistory.checkpointIdFieldName}`
    | field if field == EntityHistory.changeFieldName =>
      `'${(EntityHistory.RowAction.DELETE :> string)}'`
    | field if Some(field) == chainIdCol => `u.chain_id`
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

  let unnest = switch chainIdCol {
  | Some(_) =>
    `UNNEST($1::text[], $2::${checkpointIdPgType}[], $3::int[]) AS u(${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName}, chain_id)`
  | None =>
    `UNNEST($1::text[], $2::${checkpointIdPgType}[]) AS u(${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName})`
  }

  `INSERT INTO "${pgSchema}"."${historyTableName}" (${allHistoryFieldNamesStr})
SELECT ${selectPartsStr}
FROM ${unnest}`
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
  ~updatedEffectsCache,
  ~updatedEntities: array<Persistence.updatedEntity>,
  ~sinkPromise: option<promise<option<exn>>>,
  ~chainMetaData: option<dict<InternalTable.Chains.metaFields>>,
  ~escapeTables=?,
) => {
  try {
    let shouldSaveHistory = config->Config.shouldSaveHistory(~isInReorgThreshold)

    let specificError = ref(None)

    let rawEvents = if config.enableRawEvents {
      let rows = batch.items->Array.filterMap(item =>
        switch item {
        | Internal.Event(_) => Some(config.ecosystem.toRawEvent(item->Internal.castUnsafeEventItem))
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
          )
        }, ~items=rawEvents)
      } catch {
      | exn => classifyWriteError(~specificError, ~table=InternalTable.RawEvents.table, ~exn)
      }
    }

    let chainIdByCheckpointId = makeChainIdByCheckpointId(batch)

    let setEntities = updatedEntities->Array.map(({
      entityConfig,
      changes,
      chainId: groupChainId,
    }) => {
      let entitiesToSet = []
      let idsToDelete = []

      // The rollback-diff change is written to the entity table only, never the
      // history table; when present it is an id's oldest change.
      let diffCheckpointId = rollback->Option.map(r => r.diffCheckpointId)

      // History batches, populated only when saving history.
      let batchSetUpdates = []
      let batchDeleteEntityIds = []
      let batchDeleteCheckpointIds = []
      let batchDeleteChainIds = []
      let idsWithDiff = Utils.Set.make()

      // Single pass over the change log: track each id's latest change (the last
      // one seen) and, when saving history, fan every non-diff change out to the
      // history-table batches.
      let latestChangeById = Dict.make()
      let orderedIds = []
      changes->Array.forEach(change => {
        let entityId = change->Change.getEntityId
        if latestChangeById->Utils.Dict.dangerouslyGetNonOption(entityId)->Option.isNone {
          orderedIds->Array.push(entityId)
        }
        latestChangeById->Dict.set(entityId, change)
        if shouldSaveHistory {
          if Some(change->Change.getCheckpointId) === diffCheckpointId {
            idsWithDiff->Utils.Set.add(entityId)->ignore
          } else {
            switch change {
            | Delete({entityId, checkpointId}) =>
              batchDeleteEntityIds->Array.push(entityId)->ignore
              batchDeleteCheckpointIds->Array.push(checkpointId)->ignore
              batchDeleteChainIds
              ->Array.push(chainIdByCheckpointId->Dict.get(checkpointId->BigInt.toString))
              ->ignore
            | Set(_) => batchSetUpdates->Array.push(change)->ignore
            }
          }
        }
      })

      let backfillHistoryIds = Utils.Set.make()
      orderedIds->Array.forEach(entityId => {
        switch latestChangeById->Dict.getUnsafe(entityId) {
        | Set({entity}) => entitiesToSet->Array.push(entity)
        | Delete({entityId}) => idsToDelete->Array.push(entityId)
        }

        // An id needs a history backfill iff none of its changes is the diff.
        if shouldSaveHistory && !(idsWithDiff->Utils.Set.has(entityId)) {
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
                ~entityName=entityConfig.name,
                ~entityIndex=entityConfig.index,
                ~chainIdColumn=chainIdColumn(entityConfig),
                ~ids=backfillHistoryIds->Utils.Set.toArray,
              )
            }

            if batchDeleteCheckpointIds->Utils.Array.notEmpty {
              // Per-chain entities pass the per-delete chain id (derived from the
              // checkpoint) so history delete rows carry it; cross-chain ones
              // bind only id + checkpoint.
              let params = switch chainIdColumn(entityConfig) {
              | Some(_) =>
                (
                  batchDeleteEntityIds,
                  batchDeleteCheckpointIds->Utils.BigInt.arrayToStringArray,
                  batchDeleteChainIds->Array.map(c => c->Option.getOr(0)),
                )->Obj.magic
              | None =>
                (
                  batchDeleteEntityIds,
                  batchDeleteCheckpointIds->Utils.BigInt.arrayToStringArray,
                )->Obj.magic
              }
              promises->Array.push(
                sql
                ->Postgres.preparedUnsafe(
                  makeInsertDeleteUpdatesQuery(~entityConfig, ~pgSchema),
                  params,
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
                ~itemSchema=getWriteSchema(entityConfig),
                ~pgSchema,
              ),
            )
          }
          if idsToDelete->Utils.Array.notEmpty {
            promises->Array.push(
              sql->deleteByIdsOrThrow(
                ~pgSchema,
                ~ids=idsToDelete,
                ~table=entityConfig.table,
                ~chainId=?groupChainId,
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
    | Some({targetCheckpointId: rollbackTargetCheckpointId}) =>
      Some(
        sql => {
          let promises = allEntities->Array.map(entityConfig => {
            sql->EntityHistory.rollback(
              ~pgSchema,
              ~entityName=entityConfig.name,
              ~entityIndex=entityConfig.index,
              ~rollbackTargetCheckpointId,
            )
          })
          promises
          ->Array.push(
            sql->InternalTable.Checkpoints.rollback(~pgSchema, ~rollbackTargetCheckpointId),
          )
          ->ignore
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

          if shouldSaveHistory {
            setOperations->Array.push(sql =>
              sql->InternalTable.Checkpoints.insert(
                ~pgSchema,
                ~checkpointIds=batch.checkpointIds,
                ~checkpointChainIds=batch.checkpointChainIds,
                ~checkpointBlockNumbers=batch.checkpointBlockNumbers,
                ~checkpointBlockHashes=batch.checkpointBlockHashes,
                ~checkpointEventsProcessed=batch.checkpointEventsProcessed,
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
        ->Array.map(({effect, items, shouldInitialize}: Persistence.updatedEffectCache) => {
          setEffectCacheOrThrow(~effect, ~items, ~initialize=shouldInitialize)
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
      ~rollback,
      ~isInReorgThreshold,
      ~config,
      ~setEffectCacheOrThrow,
      ~updatedEffectsCache,
      ~allEntities,
      ~updatedEntities,
      ~sinkPromise,
      ~chainMetaData,
    )
  }
}

// Returns the most recent entity state for IDs that need to be restored during rollback.
// For each ID modified after the rollback target, retrieves its latest state at or before the target.
let makeGetRollbackRestoredEntitiesQuery = (~entityConfig: Internal.entityConfig, ~pgSchema) => {
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

  // Per-chain entities are identified by (id, chain_id), so the latest state is
  // taken per pair rather than per id alone — both the distinct key and the
  // "modified after target" existence check are scoped by chain.
  let (distinctKey, chainMatch) = switch chainIdColumn(entityConfig) {
  | Some(column) => (
      `${Table.idFieldName}, "${column}"`,
      `      AND h."${column}" = "${historyTableName}"."${column}"\n`,
    )
  | None => (Table.idFieldName, "")
  }

  `SELECT DISTINCT ON (${distinctKey}) ${dataFieldsCommaSeparated}
FROM "${pgSchema}"."${historyTableName}"
WHERE "${EntityHistory.checkpointIdFieldName}" <= $1
  AND EXISTS (
    SELECT 1
    FROM "${pgSchema}"."${historyTableName}" h
    WHERE h.${Table.idFieldName} = "${historyTableName}".${Table.idFieldName}
${chainMatch}      AND h."${EntityHistory.checkpointIdFieldName}" > $1
  )
ORDER BY ${distinctKey}, "${EntityHistory.checkpointIdFieldName}" DESC`
}

// Returns entity IDs that were created after the rollback target and have no history before it.
// These entities should be deleted during rollback. Per-chain entities also
// return their chain id so the diff can route the deletion to the right chain.
let makeGetRollbackRemovedIdsQuery = (~entityConfig: Internal.entityConfig, ~pgSchema) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )
  let (selected, chainMatch) = switch chainIdColumn(entityConfig) {
  | Some(column) => (
      `${Table.idFieldName}, "${column}" as "chainId"`,
      `    AND h."${column}" = "${historyTableName}"."${column}"\n`,
    )
  | None => (Table.idFieldName, "")
  }
  `SELECT DISTINCT ${selected}
FROM "${pgSchema}"."${historyTableName}"
WHERE "${EntityHistory.checkpointIdFieldName}" > $1
AND NOT EXISTS (
  SELECT 1
  FROM "${pgSchema}"."${historyTableName}" h
  WHERE h.${Table.idFieldName} = "${historyTableName}".${Table.idFieldName}
${chainMatch}    AND h."${EntityHistory.checkpointIdFieldName}" <= $1
)`
}

let make = (
  ~sql: Postgres.sql,
  ~pgHost,
  ~pgSchema,
  ~pgPort,
  ~pgUser,
  ~pgDatabase,
  ~pgPassword,
  ~isHasuraEnabled,
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

  let isInitialized = async () => {
    let envioTables = await sql->Postgres.unsafe(
      `SELECT table_schema FROM information_schema.tables WHERE table_schema = '${pgSchema}' AND (table_name = '${// This is for indexer before envio@2.28
        "event_sync_state"}' OR table_name = '${InternalTable.Chains.table.tableName}');`,
    )
    envioTables->Utils.Array.notEmpty
  }

  let restoreEffectCache = async (~withUpload) => {
    if withUpload {
      // Try to restore cache tables from binary files
      let nothingToUploadErrorMessage = "Nothing to upload."

      switch await Promise.all2((
        NodeJs.Fs.Promises.readdir(cacheDirPath)
        ->Promise.thenResolve(e => Ok(e))
        ->Promise.catch(_ => Promise.resolve(Error(nothingToUploadErrorMessage))),
        getConnectedPsqlExec(~pgUser, ~pgHost, ~pgDatabase, ~pgPort, ~containerName),
      )) {
      | (Ok(entries), Ok(psqlExec)) => {
          let cacheFiles = entries->Array.filter(entry => {
            entry->String.endsWith(".tsv")
          })

          let _ = await cacheFiles
          ->Array.map(entry => {
            let effectName = entry->String.slice(~start=0, ~end=-4)
            let table = Internal.makeCacheTable(~effectName)

            sql
            ->Postgres.unsafe(makeCreateTableQuery(table, ~pgSchema, ~isNumericArrayAsText=false))
            ->Promise.then(() => {
              let inputFile = NodeJs.Path.join(cacheDirPath, entry)->NodeJs.Path.toString

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
        }
      | (Error(message), _)
      | (_, Error(message)) =>
        if message === nothingToUploadErrorMessage {
          Logging.info("No cache found to upload.")
        } else {
          Logging.error(`Failed to upload cache, continuing without it. ${message}`)
        }
      }
    }

    let cacheTableInfo: array<schemaCacheTableInfo> = await sql->Postgres.unsafe(
      makeSchemaCacheTableInfoQuery(~pgSchema),
    )

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
      let effectName = tableName->String.slice(~start=cacheTablePrefixLength)
      cache->Dict.set(effectName, ({effectName, count}: Persistence.effectCacheRecord))
    })
    cache
  }

  let initialize = async (
    ~chainConfigs=[],
    ~entities=[],
    ~enums=[],
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
    | Some(sink) => await sink.initialize(~chainConfigs, ~entities=chEntities, ~enums)
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
    )
    // Execute all queries within a single transaction for integrity.
    // The envio_info row is written in the same transaction so a successful
    // initialize is atomic — no schema can come up without the matching row.
    let _ = await sql->Postgres.beginSql(async sql => {
      // Promise.all might be not safe to use here,
      // but it's just how it worked before.
      let _ = await Promise.all(queries->Array.map(query => sql->Postgres.unsafe(query)))
      await InternalTable.EnvioInfo.write(sql, ~pgSchema, ~envioInfo)
    })

    // Populate config addresses into envio_addresses with registration_block/log = -1
    let ids = []
    let addrChainIds = []
    let addrContractNames = []
    chainConfigs->Array.forEach(chain => {
      chain.contracts->Array.forEach(contract => {
        contract.addresses->Array.forEach(
          address => {
            ids->Array.push(Config.EnvioAddresses.makeId(~chainId=chain.id, ~address))->ignore
            addrChainIds->Array.push(chain.id)->ignore
            addrContractNames->Array.push(contract.name)->ignore
          },
        )
      })
    })
    if ids->Array.length > 0 {
      await sql->Postgres.unpreparedUnsafe(
        `INSERT INTO "${pgSchema}"."${Config.EnvioAddresses.table.tableName}" ("id", "chain_id", "registration_block", "registration_log_index", "contract_name")
SELECT id, chain_id, -1, -1, contract_name FROM unnest($1::text[],$2::int[],$3::text[]) AS t(id, chain_id, contract_name);`,
        (ids, addrChainIds, addrContractNames)->(Utils.magic: _ => unknown),
      )
    }

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
      // Just-written row; resume's compat check would no-op on a clean run,
      // but keep the field consistent with the resume path's shape.
      envioInfo: Some(envioInfo),
      chains: chainConfigs->Array.map((chainConfig): Persistence.initialChainState => {
        id: chainConfig.id,
        startBlock: chainConfig.startBlock,
        endBlock: chainConfig.endBlock,
        maxReorgDepth: chainConfig.maxReorgDepth,
        progressBlockNumber: -1,
        numEventsProcessed: 0.,
        firstEventBlockNumber: None,
        timestampCaughtUpToHeadOrEndblock: None,
        indexingAddresses: ChainState.configAddresses(chainConfig),
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
      try rows->S.parseOrThrow(table->Table.pgRowsSchema) catch {
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
    )
  }

  let setEffectCacheOrThrow = async (
    ~effect: Internal.effect,
    ~items: array<Internal.effectCacheItem>,
    ~initialize: bool,
  ) => {
    let {table, itemSchema} = effect.storageMeta

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
      let cacheTableInfo: array<schemaCacheTableInfo> =
        (await sql->Postgres.unsafe(makeSchemaCacheTableInfoQuery(~pgSchema)))->Array.filter(i =>
          i.count > 0
        )

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
              let cacheName = tableName->String.slice(~start=cacheTablePrefixLength)
              let outputFile =
                NodeJs.Path.join(cacheDirPath, cacheName ++ ".tsv")->NodeJs.Path.toString

              let command = `${psqlExec} -c 'COPY "${pgSchema}"."${tableName}" TO STDOUT WITH (FORMAT text, HEADER);' > ${outputFile}`

              Promise.make((resolve, reject) => {
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
    let (cache, chains, checkpointIdResult, reorgCheckpoints, envioInfo) = await Promise.all5((
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
          indexingAddresses: rawInitialState.indexingAddresses,
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
      InternalTable.EnvioInfo.read(sql, ~pgSchema),
    ))

    let checkpointId = (checkpointIdResult->Array.getUnsafe(0))["id"]->BigInt.fromStringOrThrow

    // Convert string checkpoint IDs from DB to bigint
    let reorgCheckpoints = Array.map(reorgCheckpoints, (raw): Internal.reorgCheckpoint => {
      checkpointId: raw["id"]->BigInt.fromStringOrThrow,
      chainId: raw["chain_id"],
      blockNumber: raw["block_number"],
      blockHash: raw["block_hash"],
    })

    // Resume sink if present - needed to rollback any reorg changes
    switch sink {
    | Some(sink) => await sink.resume(~checkpointId)
    | None => ()
    }

    {
      cleanRun: false,
      reorgCheckpoints,
      cache,
      chains,
      checkpointId,
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

  let pruneStaleEntityHistory = (~entityConfig: Internal.entityConfig, ~safeCheckpointId) =>
    EntityHistory.pruneStaleEntityHistory(
      sql,
      ~pgSchema,
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
      ~chainIdColumn=chainIdColumn(entityConfig),
      ~safeCheckpointId,
    )

  let getRollbackTargetCheckpoint = (~reorgChainId, ~lastKnownValidBlockNumber) =>
    InternalTable.Checkpoints.getRollbackTargetCheckpoint(
      sql,
      ~pgSchema,
      ~reorgChainId,
      ~lastKnownValidBlockNumber,
    )

  let getRollbackProgressDiff = (~rollbackTargetCheckpointId) =>
    InternalTable.Checkpoints.getRollbackProgressDiff(sql, ~pgSchema, ~rollbackTargetCheckpointId)

  let getRollbackData = async (
    ~entityConfig: Internal.entityConfig,
    ~rollbackTargetCheckpointId,
  ) => {
    await Promise.all2((
      // Get IDs of entities that should be deleted (created after rollback target with no prior history)
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackRemovedIdsQuery(~entityConfig, ~pgSchema),
        [rollbackTargetCheckpointId->BigInt.toString]->(Utils.magic: array<string> => unknown),
      )
      ->(Utils.magic: promise<unknown> => promise<array<{"id": string, "chainId": option<int>}>>),
      // Get entities that should be restored to their state at or before rollback target
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackRestoredEntitiesQuery(~entityConfig, ~pgSchema),
        [rollbackTargetCheckpointId->BigInt.toString]->(Utils.magic: array<string> => unknown),
      )
      ->(Utils.magic: promise<unknown> => promise<array<unknown>>),
    ))
  }

  let writeBatchMethod = async (
    ~batch,
    ~rollback,
    ~isInReorgThreshold,
    ~config,
    ~allEntities,
    ~updatedEffectsCache,
    ~updatedEntities,
    ~chainMetaData,
  ) => {
    // Before the storage split, so the ClickHouse sink gets stamped
    // entities as well.
    let updatedEntities = stampPerChainIds(~updatedEntities)

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
            Prometheus.StorageWrite.increment(
              ~storage=sink.name,
              ~timeSeconds=timerRef->Performance.secondsSince,
            )
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
      ~rollback,
      ~isInReorgThreshold,
      ~config,
      ~allEntities,
      ~setEffectCacheOrThrow,
      ~updatedEffectsCache,
      ~updatedEntities=pgUpdates,
      ~sinkPromise,
      ~chainMetaData,
    )
    Prometheus.StorageWrite.increment(
      ~storage="postgres",
      ~timeSeconds=primaryTimerRef->Performance.secondsSince,
    )
  }

  let close = () => sql->Postgres.endSql

  {
    name: "postgres",
    isInitialized,
    initialize,
    resumeInitialState,
    loadOrThrow,
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
              ~schema=Schema.make(config.allEntities->Array.map(e => e.table)),
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
