let getCacheRowCountFnName = "get_cache_row_count"

// Only needed for some old tests
// Remove @genType in the future
@genType
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
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")

  // Case for indexer before envio@2.28
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
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
    ->Js.Array2.joinWith("_")
  let index =
    indexFields
    ->Belt.Array.map(f => `"${f.fieldName}"${directionToSql(f.direction)}`)
    ->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${pgSchema}"."${tableName}"(${index});`
}

let makeCreateTableIndicesQuery = (table: Table.table, ~pgSchema) => {
  open Belt
  let tableName = table.tableName
  let createIndex = indexField =>
    makeCreateIndexQuery(~tableName, ~indexFields=[indexField], ~pgSchema)
  let createCompositeIndex = indexFields => {
    makeCreateCompositeIndexQuery(~tableName, ~indexFields, ~pgSchema)
  }

  let singleIndices = table->Table.getSingleIndices
  let compositeIndices = table->Table.getCompositeIndices

  singleIndices->Array.map(createIndex)->Js.Array2.joinWith("\n") ++
    compositeIndices->Array.map(createCompositeIndex)->Js.Array2.joinWith("\n")
}

let makeCreateTableQuery = (table: Table.table, ~pgSchema, ~isNumericArrayAsText) => {
  open Belt
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getDbFieldName

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
    ->Js.Array2.joinWith(", ")

  let primaryKeyFieldNames = table->Table.getPrimaryKeyFieldNames
  let primaryKey = primaryKeyFieldNames->Array.map(field => `"${field}"`)->Js.Array2.joinWith(", ")

  `CREATE TABLE IF NOT EXISTS "${pgSchema}"."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""});`
}

let getEntityHistory = (~entityConfig: Internal.entityConfig): EntityHistory.pgEntityHistory<
  'entity,
> => {
  switch entityConfig.pgEntityHistoryCache {
  | Some(cache) => cache
  | None =>
    let cache = {
      let id = "id"

      let dataFields = entityConfig.table.fields->Belt.Array.keepMap(field =>
        switch field {
        | Field(field) =>
          switch field.fieldName {
          //id is not nullable and should be part of the pk
          | "id" => {...field, fieldName: id, isPrimaryKey: true}->Table.Field->Some
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
        ~fields=dataFields->Belt.Array.concat([checkpointIdField, actionField]),
      )

      let setChangeSchema = EntityHistory.makeSetUpdateSchema(entityConfig.schema)

      {
        EntityHistory.table,
        setChangeSchema,
        setChangeSchemaRows: S.array(setChangeSchema),
      }
    }

    entityConfig.pgEntityHistoryCache = Some(cache)
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
    InternalTable.PersistedState.table,
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
      // so we reuse the existing schema when it's empty
      // (but only for public, since it's usually always exists)
        ? ""
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
      ->Js.Array2.joinWith(", ")});`

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
        derivedSchema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn
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

let makeLoadByIdQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE id = $1 LIMIT 1;`
}

let makeLoadByFieldQuery = (~pgSchema, ~tableName, ~fieldName, ~operator) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE "${fieldName}" ${operator} $1;`
}

let makeLoadByIdsQuery = (~pgSchema, ~tableName) => {
  `SELECT * FROM "${pgSchema}"."${tableName}" WHERE id = ANY($1::text[]);`
}

let makeDeleteByIdQuery = (~pgSchema, ~tableName) => {
  `DELETE FROM "${pgSchema}"."${tableName}" WHERE id = $1;`
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

  let primaryKeyFieldNames = Table.getPrimaryKeyFieldNames(table)

  `INSERT INTO "${pgSchema}"."${table.tableName}" (${quotedFieldNames->Js.Array2.joinWith(", ")})
SELECT * FROM unnest(${arrayFieldTypes
    ->Array.mapWithIndex((arrayFieldType, idx) => {
      `$${(idx + 1)->Int.toString}::${arrayFieldType}`
    })
    ->Js.Array2.joinWith(",")})` ++
  switch (isRawEvents, primaryKeyFieldNames) {
  | (true, _)
  | (_, []) => ``
  | (false, primaryKeyFieldNames) =>
    `ON CONFLICT(${primaryKeyFieldNames
      ->Array.map(fieldName => `"${fieldName}"`)
      ->Js.Array2.joinWith(",")}) DO ` ++ (
      quotedNonPrimaryFieldNames->Utils.Array.isEmpty
        ? `NOTHING`
        : `UPDATE SET ${quotedNonPrimaryFieldNames
            ->Array.map(fieldName => {
              `${fieldName} = EXCLUDED.${fieldName}`
            })
            ->Js.Array2.joinWith(",")}`
    )
  } ++ ";"
}

let makeInsertValuesSetQuery = (~pgSchema, ~table: Table.table, ~itemSchema, ~itemsCount) => {
  let {quotedFieldNames, quotedNonPrimaryFieldNames} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema)

  let primaryKeyFieldNames = Table.getPrimaryKeyFieldNames(table)
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

  `INSERT INTO "${pgSchema}"."${table.tableName}" (${quotedFieldNames->Js.Array2.joinWith(", ")})
VALUES${placeholders.contents}` ++
  switch primaryKeyFieldNames {
  | [] => ``
  | primaryKeyFieldNames =>
    `ON CONFLICT(${primaryKeyFieldNames
      ->Array.map(fieldName => `"${fieldName}"`)
      ->Js.Array2.joinWith(",")}) DO ` ++ (
      quotedNonPrimaryFieldNames->Utils.Array.isEmpty
        ? `NOTHING`
        : `UPDATE SET ${quotedNonPrimaryFieldNames
            ->Array.map(fieldName => {
              `${fieldName} = EXCLUDED.${fieldName}`
            })
            ->Js.Array2.joinWith(",")}`
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
      "convertOrThrow": // S.preprocess was removed in sury. Compose unnest + flatten manually:
      // unnest serializes entity values to columnar arrays, then flatten combines them.

      {
        let unnestConvert = S.compile(
          S.unnest(itemSchema),
          ~input=Value,
          ~output=Unknown,
          ~mode=Sync,
          ~typeValidation,
        )
        v =>
          unnestConvert(v)
          ->(Utils.magic: unknown => array<array<unknown>>)
          ->Utils.Array.flatten
          ->(Utils.magic: array<unknown> => unknown)
      },
      "isInsertValues": true,
    }
  }
}

let chunkArray = (arr: array<'a>, ~chunkSize) => {
  let chunks = []
  let i = ref(0)
  while i.contents < arr->Array.length {
    let chunk = arr->Js.Array2.slice(~start=i.contents, ~end_=i.contents + chunkSize)
    chunks->Array.push(chunk)->ignore
    i := i.contents + chunkSize
  }
  chunks
}

let removeInvalidUtf8InPlace = entities =>
  entities->Array.forEach(item => {
    let dict = item->(Utils.magic: 'a => dict<unknown>)
    dict->Utils.Dict.forEachWithKey((value, key) => {
      if value->Js.typeof === "string" {
        let value = value->(Utils.magic: unknown => string)

        dict->Dict.set(
          key,
          value
          ->Utils.String.replaceAll("\x00", "")
          ->(Utils.magic: string => unknown),
        )
      }
    })
  })

let pgErrorMessageSchema = S.object(s => s.field("message", S.string))

exception PgEncodingError({table: Table.table})

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
          ~itemSchema=itemSchema->S.castToUnknown,
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

          let response =
            sql->Postgres.preparedUnsafe(
              isFullChunk
                ? data["query"]
                : makeInsertValuesSetQuery(~pgSchema, ~table, ~itemSchema, ~itemsCount=chunkSize),
              data["convertOrThrow"](chunk->(Utils.magic: array<'item> => array<unknown>)),
            )
          responses->Array.push(response)->ignore
        })
        let _ = await Promise_.all(responses)
      } else {
        // Use UNNEST approach for single query
        await sql->Postgres.preparedUnsafe(
          data["query"],
          data["convertOrThrow"](items->(Utils.magic: array<'item> => array<unknown>)),
        )
      }
    } catch {
    | S.Error(_) as exn =>
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
  let pgDockerServiceName = "envio-postgres"
  // Should use the default port, since we're executing the command
  // from the postgres container's network.
  let pgDockerServicePort = 5432

  // For development: We run the indexer process locally,
  //   and there might not be psql installed on the user's machine.
  //   So we use docker-compose to run psql existing in the postgres container.
  // For production: We expect indexer to be running in a container,
  //   with psql installed. So we can call it directly.
  let psqlExecState = ref(Unknown)
  async (~pgUser, ~pgHost, ~pgDatabase, ~pgPort) => {
    switch psqlExecState.contents {
    | Unknown => {
        let promise = Promise_.make((resolve, _reject) => {
          let binary = "psql"
          NodeJs.ChildProcess.exec(`${binary} --version`, (~error, ~stdout as _, ~stderr as _) => {
            switch error {
            | Value(_) => {
                let binary = `docker-compose exec -T -u ${pgUser} ${pgDockerServiceName} psql`
                NodeJs.ChildProcess.exec(
                  `${binary} --version`,
                  (~error, ~stdout as _, ~stderr as _) => {
                    switch error {
                    | Value(_) =>
                      resolve(
                        Error(`Please check if "psql" binary is installed or docker-compose is running for the local indexer.`),
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

let deleteByIdsOrThrow = async (sql, ~pgSchema, ~ids, ~table: Table.table) => {
  switch await (
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
  let allHistoryFieldNames = entityConfig.table.fields->Belt.Array.keepMap(fieldOrDerived =>
    switch fieldOrDerived {
    | Field(field) => field->Table.getDbFieldName->Some
    | DerivedFrom(_) => None
    }
  )
  allHistoryFieldNames->Array.push(EntityHistory.checkpointIdFieldName)->ignore
  allHistoryFieldNames->Array.push(EntityHistory.changeFieldName)->ignore

  let allHistoryFieldNamesStr =
    allHistoryFieldNames->Belt.Array.map(name => `"${name}"`)->Js.Array2.joinWith(", ")

  // Build the SELECT part: id from unnest, envio_checkpoint_id from unnest, 'DELETE' for action, NULL for all other fields
  let selectParts = allHistoryFieldNames->Belt.Array.map(fieldName => {
    switch fieldName {
    | field if field == Table.idFieldName => `u.${Table.idFieldName}`
    | field if field == EntityHistory.checkpointIdFieldName =>
      `u.${EntityHistory.checkpointIdFieldName}`
    | field if field == EntityHistory.changeFieldName =>
      `'${(EntityHistory.RowAction.DELETE :> string)}'`
    | _ => "NULL"
    }
  })
  let selectPartsStr = selectParts->Js.Array2.joinWith(", ")

  // Get the PostgreSQL type for the checkpoint ID field
  let checkpointIdPgType = Table.getPgFieldType(
    ~fieldType=EntityHistory.checkpointIdFieldType,
    ~pgSchema,
    ~isArray=false,
    ~isNumericArrayAsText=false,
    ~isNullable=false,
  )

  `INSERT INTO "${pgSchema}"."${historyTableName}" (${allHistoryFieldNamesStr})
SELECT ${selectPartsStr}
FROM UNNEST($1::text[], $2::${checkpointIdPgType}[]) AS u(${Table.idFieldName}, ${EntityHistory.checkpointIdFieldName})`
}

let executeSet = (
  sql: Postgres.sql,
  ~items: array<'a>,
  ~dbFunction: (Postgres.sql, array<'a>) => promise<unit>,
) => {
  if items->Array.length > 0 {
    sql->dbFunction(items)
  } else {
    Promise_.resolve()
  }
}

let rec writeBatch = async (
  sql,
  ~batch: Batch.t,
  ~rawEvents,
  ~pgSchema,
  ~rollbackTargetCheckpointId,
  ~isInReorgThreshold,
  ~config: Config.t,
  ~allEntities: array<Internal.entityConfig>,
  ~setEffectCacheOrThrow,
  ~updatedEffectsCache,
  ~updatedEntities: array<Persistence.updatedEntity>,
  ~sinkPromise: option<promise<option<exn>>>,
  ~escapeTables=?,
) => {
  try {
    let shouldSaveHistory = config->Config.shouldSaveHistory(~isInReorgThreshold)

    let specificError = ref(None)

    let setRawEvents = executeSet(
      _,
      ~dbFunction=(sql, items) => {
        sql->setOrThrow(
          ~items,
          ~table=InternalTable.RawEvents.table,
          ~itemSchema=InternalTable.RawEvents.schema,
          ~pgSchema,
        )
      },
      ~items=rawEvents,
    )

    let setEntities = updatedEntities->Belt.Array.map(({entityConfig, updates}) => {
      let entitiesToSet = []
      let idsToDelete = []

      updates->Array.forEach(row => {
        switch row {
        | {latestChange: Set({entity})} => entitiesToSet->Belt.Array.push(entity)
        | {latestChange: Delete({entityId})} => idsToDelete->Belt.Array.push(entityId)
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
            let backfillHistoryIds = Utils.Set.make()
            let batchSetUpdates = []
            // Use unnest approach
            let batchDeleteCheckpointIds = []
            let batchDeleteEntityIds = []

            updates->Array.forEach(update => {
              switch update {
              | {history, containsRollbackDiffChange} =>
                history->Array.forEach(
                  (change: Change.t<'a>) => {
                    if !containsRollbackDiffChange {
                      backfillHistoryIds->Utils.Set.add(change->Change.getEntityId)->ignore
                    }
                    switch change {
                    | Delete({entityId}) => {
                        batchDeleteEntityIds->Belt.Array.push(entityId)->ignore
                        batchDeleteCheckpointIds
                        ->Belt.Array.push(change->Change.getCheckpointId)
                        ->ignore
                      }
                    | Set(_) => batchSetUpdates->Array.push(change)->ignore
                    }
                  },
                )
              }
            })

            if backfillHistoryIds->Utils.Set.size !== 0 {
              // This must run before updating entity or entity history tables
              await EntityHistory.backfillHistory(
                sql,
                ~pgSchema,
                ~entityName=entityConfig.name,
                ~entityIndex=entityConfig.index,
                ~ids=backfillHistoryIds->Utils.Set.toArray,
              )
            }

            if batchDeleteCheckpointIds->Utils.Array.notEmpty {
              promises->Belt.Array.push(
                sql
                ->Postgres.preparedUnsafe(
                  makeInsertDeleteUpdatesQuery(~entityConfig, ~pgSchema),
                  (batchDeleteEntityIds, batchDeleteCheckpointIds)->Obj.magic,
                )
                ->Promise_.ignoreValue,
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
            promises->Belt.Array.push(
              sql->setOrThrow(
                ~items=entitiesToSet,
                ~table=entityConfig.table,
                ~itemSchema=entityConfig.schema,
                ~pgSchema,
              ),
            )
          }
          if idsToDelete->Utils.Array.notEmpty {
            promises->Belt.Array.push(
              sql->deleteByIdsOrThrow(~pgSchema, ~ids=idsToDelete, ~table=entityConfig.table),
            )
          }

          let _ = await promises->Promise_.all
        } catch {
        // There's a race condition that sql->Postgres.beginSql
        // might throw PG error, earlier, than the handled error
        // from setOrThrow will be passed through.
        // This is needed for the utf8 encoding fix.
        | exn => {
            /* Note: Entity History doesn't return StorageError yet, and directly throws JsExn */
            let normalizedExn = switch exn {
            | JsExn(_) => exn
            | Persistence.StorageError({reason: exn}) => exn
            | _ => exn
            }->JsExn.anyToExnInternal

            switch normalizedExn {
            | JsExn(error) =>
              // Workaround for https://github.com/enviodev/hyperindex/issues/446
              // We do escaping only when we actually got an error writing for the first time.
              // This is not perfect, but an optimization to avoid escaping for every single item.

              switch error->S.parseOrThrow(pgErrorMessageSchema) {
              | `current transaction is aborted, commands ignored until end of transaction block` => ()
              | `invalid byte sequence for encoding "UTF8": 0x00` =>
                // Since the transaction is aborted at this point,
                // we can't simply retry the function with escaped items,
                // so propagate the error, to restart the whole batch write.
                // Also, pass the failing table, to escape only its items.
                // TODO: Ideally all this should be done in the file,
                // so it'll be easier to work on PG specific logic.
                specificError.contents = Some(PgEncodingError({table: entityConfig.table}))
              | _ => specificError.contents = Some(exn->Utils.prettifyExn)
              | exception _ => ()
              }
            | S.Error(_) => throw(normalizedExn) // But rethrow this one, since it's not a PG error
            | _ => ()
            }

            // Improtant: Don't rethrow here, since it'll result in
            // an unhandled rejected promise error.
            // That's fine not to throw, since sql->Postgres.beginSql
            // will fail anyways.
          }
        }
      }
    })

    //In the event of a rollback, rollback all meta tables based on the given
    //valid event identifier, where all rows created after this eventIdentifier should
    //be deleted
    let rollbackTables = switch rollbackTargetCheckpointId {
    | Some(rollbackTargetCheckpointId) =>
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
          Promise_.all(promises)
        },
      )
    | None => None
    }

    try {
      let _ = await Promise_.all2((
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
          ]->Belt.Array.concat(setEntities)

          if shouldSaveHistory {
            setOperations->Belt.Array.push(sql =>
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
          ->Belt.Array.map(dbFunc => sql->dbFunc)
          ->Promise_.all
          ->Promise_.ignoreValue

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
        ->Belt.Array.map(({effect, items, shouldInitialize}: Persistence.updatedEffectCache) => {
          setEffectCacheOrThrow(~effect, ~items, ~initialize=shouldInitialize)
        })
        ->Promise_.all,
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
      ~rawEvents,
      ~batch,
      ~pgSchema,
      ~rollbackTargetCheckpointId,
      ~isInReorgThreshold,
      ~config,
      ~setEffectCacheOrThrow,
      ~updatedEffectsCache,
      ~allEntities,
      ~updatedEntities,
      ~sinkPromise,
    )
  }
}

// Returns the most recent entity state for IDs that need to be restored during rollback.
// For each ID modified after the rollback target, retrieves its latest state at or before the target.
let makeGetRollbackRestoredEntitiesQuery = (~entityConfig: Internal.entityConfig, ~pgSchema) => {
  let dataFieldNames = entityConfig.table.fields->Belt.Array.keepMap(fieldOrDerived =>
    switch fieldOrDerived {
    | Field(field) => field->Table.getDbFieldName->Some
    | DerivedFrom(_) => None
    }
  )

  let dataFieldsCommaSeparated =
    dataFieldNames->Belt.Array.map(name => `"${name}"`)->Js.Array2.joinWith(", ")

  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )

  `SELECT DISTINCT ON (${Table.idFieldName}) ${dataFieldsCommaSeparated}
FROM "${pgSchema}"."${historyTableName}"
WHERE "${EntityHistory.checkpointIdFieldName}" <= $1
  AND EXISTS (
    SELECT 1
    FROM "${pgSchema}"."${historyTableName}" h
    WHERE h.${Table.idFieldName} = "${historyTableName}".${Table.idFieldName}
      AND h."${EntityHistory.checkpointIdFieldName}" > $1
  )
ORDER BY ${Table.idFieldName}, "${EntityHistory.checkpointIdFieldName}" DESC`
}

// Returns entity IDs that were created after the rollback target and have no history before it.
// These entities should be deleted during rollback.
let makeGetRollbackRemovedIdsQuery = (~entityConfig: Internal.entityConfig, ~pgSchema) => {
  let historyTableName = EntityHistory.historyTableName(
    ~entityName=entityConfig.name,
    ~entityIndex=entityConfig.index,
  )
  `SELECT DISTINCT ${Table.idFieldName}
FROM "${pgSchema}"."${historyTableName}"
WHERE "${EntityHistory.checkpointIdFieldName}" > $1
AND NOT EXISTS (
  SELECT 1
  FROM "${pgSchema}"."${historyTableName}" h
  WHERE h.${Table.idFieldName} = "${historyTableName}".${Table.idFieldName}
    AND h."${EntityHistory.checkpointIdFieldName}" <= $1
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

      switch await Promise_.all2((
        NodeJs.Fs.Promises.readdir(cacheDirPath)
        ->Promise_.thenResolve(e => Ok(e))
        ->Promise_.catch(_ => Promise_.resolve(Error(nothingToUploadErrorMessage))),
        getConnectedPsqlExec(~pgUser, ~pgHost, ~pgDatabase, ~pgPort),
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
            ->Promise_.then(() => {
              let inputFile = NodeJs.Path.join(cacheDirPath, entry)->NodeJs.Path.toString

              let command = `${psqlExec} -c 'COPY "${pgSchema}"."${table.tableName}" FROM STDIN WITH (FORMAT text, HEADER);' < ${inputFile}`

              Promise_.make(
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
          ->Promise_.all

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

  let initialize = async (~chainConfigs=[], ~entities=[], ~enums=[]): Persistence.initialState => {
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
        `Cannot run Envio migrations on PostgreSQL schema "${pgSchema}" because it contains non-Envio tables. Running migrations would delete all data in this schema.\n\nTo resolve this:\n1. If you want to use this schema, first backup any important data, then drop it with: "pnpm envio local db-migrate down"\n2. Or specify a different schema name by setting the "ENVIO_PG_PUBLIC_SCHEMA" environment variable\n3. Or manually drop the schema in your database if you're certain the data is not needed.`,
      )
    }

    // Call sink.initialize before executing PG queries
    switch sink {
    | Some(sink) => await sink.initialize(~chainConfigs, ~entities, ~enums)
    | None => ()
    }

    let queries = makeInitializeTransaction(
      ~pgSchema,
      ~pgUser,
      ~entities,
      ~enums,
      ~chainConfigs,
      ~isEmptyPgSchema=schemaTableNames->Utils.Array.isEmpty,
      ~isHasuraEnabled,
    )
    // Execute all queries within a single transaction for integrity
    let _ = await sql->Postgres.beginSql(sql => {
      // Promise_.all might be not safe to use here,
      // but it's just how it worked before.
      Promise_.all(queries->Array.map(query => sql->Postgres.unsafe(query)))
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
      chains: chainConfigs->Array.map((chainConfig): Persistence.initialChainState => {
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

  let loadByIdsOrThrow = async (~ids, ~table: Table.table, ~rowsSchema) => {
    switch await (
      switch ids {
      | [_] =>
        sql->Postgres.preparedUnsafe(
          makeLoadByIdQuery(~pgSchema, ~tableName=table.tableName),
          ids->Obj.magic,
        )
      | _ =>
        sql->Postgres.preparedUnsafe(
          makeLoadByIdsQuery(~pgSchema, ~tableName=table.tableName),
          [ids]->Obj.magic,
        )
      }
    ) {
    | exception exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by ids`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(rowsSchema) catch {
      | exn =>
        throw(
          Persistence.StorageError({
            message: `Failed to parse "${table.tableName}" loaded from storage by ids`,
            reason: exn,
          }),
        )
      }
    }
  }

  let loadByFieldOrThrow = async (
    ~fieldName: string,
    ~fieldSchema,
    ~fieldValue,
    ~operator: Persistence.operator,
    ~table: Table.table,
    ~rowsSchema,
  ) => {
    let params = try [fieldValue->S.reverseConvertToJsonOrThrow(fieldSchema)]->Obj.magic catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by field "${fieldName}". Couldn't serialize provided value.`,
          reason: exn,
        }),
      )
    }
    switch await sql->Postgres.preparedUnsafe(
      makeLoadByFieldQuery(
        ~pgSchema,
        ~tableName=table.tableName,
        ~fieldName,
        ~operator=(operator :> string),
      ),
      params,
    ) {
    | exception exn =>
      throw(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by field "${fieldName}"`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(rowsSchema) catch {
      | exn =>
        throw(
          Persistence.StorageError({
            message: `Failed to parse "${table.tableName}" loaded from storage by ids`,
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
      ~itemSchema=itemSchema->S.castToUnknown,
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

        // Command for testing. Run from generated
        // docker-compose exec -T -u postgres envio-postgres psql -d envio-dev -c 'COPY "public"."envio_effect_getTokenMetadata" TO STDOUT (FORMAT text, HEADER);' > ../.envio/cache/getTokenMetadata.tsv

        switch await getConnectedPsqlExec(~pgUser, ~pgHost, ~pgDatabase, ~pgPort) {
        | Ok(psqlExec) => {
            Logging.info(
              `Dumping cache: ${cacheTableInfo
                ->Array.map(({tableName, count}) =>
                  tableName ++ " (" ++ count->Belt.Int.toString ++ " rows)"
                )
                ->Js.Array2.joinWith(", ")}`,
            )

            let promises = cacheTableInfo->Array.map(async ({tableName}) => {
              let cacheName = tableName->String.slice(~start=cacheTablePrefixLength)
              let outputFile =
                NodeJs.Path.join(cacheDirPath, cacheName ++ ".tsv")->NodeJs.Path.toString

              let command = `${psqlExec} -c 'COPY "${pgSchema}"."${tableName}" TO STDOUT WITH (FORMAT text, HEADER);' > ${outputFile}`

              Promise_.make((resolve, reject) => {
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

            let _ = await promises->Promise_.all
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
    let (cache, chains, checkpointIdResult, reorgCheckpoints) = await Promise_.all4((
      restoreEffectCache(~withUpload=false),
      InternalTable.Chains.getInitialState(
        sql,
        ~pgSchema,
      )->Promise_.thenResolve(rawInitialStates => {
        rawInitialStates->Belt.Array.map((rawInitialState): Persistence.initialChainState => {
          id: rawInitialState.id,
          startBlock: rawInitialState.startBlock,
          endBlock: rawInitialState.endBlock->Null.toOption,
          maxReorgDepth: rawInitialState.maxReorgDepth,
          firstEventBlockNumber: rawInitialState.firstEventBlockNumber->Null.toOption,
          timestampCaughtUpToHeadOrEndblock: rawInitialState.timestampCaughtUpToHeadOrEndblock->Null.toOption,
          numEventsProcessed: rawInitialState.numEventsProcessed,
          progressBlockNumber: rawInitialState.progressBlockNumber,
          dynamicContracts: rawInitialState.dynamicContracts,
          sourceBlockNumber: rawInitialState.sourceBlockNumber,
        })
      }),
      sql
      ->Postgres.unsafe(InternalTable.Checkpoints.makeCommitedCheckpointIdQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<{"id": float}>>),
      sql
      ->Postgres.unsafe(InternalTable.Checkpoints.makeGetReorgCheckpointsQuery(~pgSchema))
      ->(Utils.magic: promise<array<unknown>> => promise<array<Internal.reorgCheckpoint>>),
    ))

    let checkpointId = (checkpointIdResult->Belt.Array.getUnsafe(0))["id"]

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
    }
  }

  let executeUnsafe = query => sql->Postgres.unsafe(query)

  let setChainMeta = chainsData =>
    InternalTable.Chains.setMeta(sql, ~pgSchema, ~chainsData)->Promise_.thenResolve(_ =>
      %raw(`undefined`)
    )

  let pruneStaleCheckpoints = (~safeCheckpointId) =>
    InternalTable.Checkpoints.pruneStaleCheckpoints(sql, ~pgSchema, ~safeCheckpointId)

  let pruneStaleEntityHistory = (~entityName, ~entityIndex, ~safeCheckpointId) =>
    EntityHistory.pruneStaleEntityHistory(
      sql,
      ~pgSchema,
      ~entityName,
      ~entityIndex,
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
    await Promise_.all2((
      // Get IDs of entities that should be deleted (created after rollback target with no prior history)
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackRemovedIdsQuery(~entityConfig, ~pgSchema),
        [rollbackTargetCheckpointId]->Utils.magic,
      )
      ->(Utils.magic: promise<unknown> => promise<array<{"id": string}>>),
      // Get entities that should be restored to their state at or before rollback target
      sql
      ->Postgres.preparedUnsafe(
        makeGetRollbackRestoredEntitiesQuery(~entityConfig, ~pgSchema),
        [rollbackTargetCheckpointId]->Utils.magic,
      )
      ->(Utils.magic: promise<unknown> => promise<array<unknown>>),
    ))
  }

  let writeBatchMethod = async (
    ~batch,
    ~rawEvents,
    ~rollbackTargetCheckpointId,
    ~isInReorgThreshold,
    ~config,
    ~allEntities,
    ~updatedEffectsCache,
    ~updatedEntities,
  ) => {
    // Initialize sink if configured
    let sinkPromise = switch sink {
    | Some(sink) => {
        let timerRef = Hrtime.makeTimer()
        Some(
          sink.writeBatch(~batch, ~updatedEntities)
          ->Promise_.thenResolve(_ => {
            Prometheus.SinkWrite.increment(
              ~sinkName=sink.name,
              ~timeMillis=timerRef->Hrtime.timeSince->Hrtime.toMillis->Hrtime.intFromMillis,
            )
            None
          })
          // Otherwise it fails with unhandled exception
          ->Promise_.catchResolve(exn => Some(exn)),
        )
      }
    | None => None
    }

    await writeBatch(
      sql,
      ~batch,
      ~rawEvents,
      ~pgSchema,
      ~rollbackTargetCheckpointId,
      ~isInReorgThreshold,
      ~config,
      ~allEntities,
      ~setEffectCacheOrThrow,
      ~updatedEffectsCache,
      ~updatedEntities,
      ~sinkPromise,
    )
  }

  {
    isInitialized,
    initialize,
    resumeInitialState,
    loadByFieldOrThrow,
    loadByIdsOrThrow,
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
    writeBatch: writeBatchMethod,
  }
}
