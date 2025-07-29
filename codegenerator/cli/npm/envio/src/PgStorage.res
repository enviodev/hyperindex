let getCacheRowCountFnName = "get_cache_row_count"

let makeCreateIndexQuery = (~tableName, ~indexFields, ~pgSchema) => {
  let indexName = tableName ++ "_" ++ indexFields->Js.Array2.joinWith("_")
  let index = indexFields->Belt.Array.map(idx => `"${idx}"`)->Js.Array2.joinWith(", ")
  `CREATE INDEX IF NOT EXISTS "${indexName}" ON "${pgSchema}"."${tableName}"(${index});`
}

let makeCreateTableIndicesQuery = (table: Table.table, ~pgSchema) => {
  open Belt
  let tableName = table.tableName
  let createIndex = indexField =>
    makeCreateIndexQuery(~tableName, ~indexFields=[indexField], ~pgSchema)
  let createCompositeIndex = indexFields => {
    makeCreateIndexQuery(~tableName, ~indexFields, ~pgSchema)
  }

  let singleIndices = table->Table.getSingleIndices
  let compositeIndices = table->Table.getCompositeIndices

  singleIndices->Array.map(createIndex)->Js.Array2.joinWith("\n") ++
    compositeIndices->Array.map(createCompositeIndex)->Js.Array2.joinWith("\n")
}

let makeCreateTableQuery = (table: Table.table, ~pgSchema) => {
  open Belt
  let fieldsMapped =
    table
    ->Table.getFields
    ->Array.map(field => {
      let {fieldType, isNullable, isArray, defaultValue} = field
      let fieldName = field->Table.getDbFieldName

      {
        `"${fieldName}" ${switch fieldType {
          | Custom(name) if !(name->Js.String2.startsWith("NUMERIC(")) => `"${pgSchema}".${name}`
          | _ => (fieldType :> string)
          }}${isArray ? "[]" : ""}${switch defaultValue {
          | Some(defaultValue) => ` DEFAULT ${defaultValue}`
          | None => isNullable ? `` : ` NOT NULL`
          }}`
      }
    })
    ->Js.Array2.joinWith(", ")

  let primaryKeyFieldNames = table->Table.getPrimaryKeyFieldNames
  let primaryKey =
    primaryKeyFieldNames
    ->Array.map(field => `"${field}"`)
    ->Js.Array2.joinWith(", ")

  `CREATE TABLE IF NOT EXISTS "${pgSchema}"."${table.tableName}"(${fieldsMapped}${primaryKeyFieldNames->Array.length > 0
      ? `, PRIMARY KEY(${primaryKey})`
      : ""});`
}

let makeInitializeTransaction = (
  ~pgSchema,
  ~pgUser,
  ~generalTables=[],
  ~entities=[],
  ~enums=[],
  ~isEmptyPgSchema=false,
) => {
  let allTables = generalTables->Array.copy
  let allEntityTables = []
  entities->Js.Array2.forEach((entity: Internal.entityConfig) => {
    allEntityTables->Js.Array2.push(entity.table)->ignore
    allTables->Js.Array2.push(entity.table)->ignore
    allTables->Js.Array2.push(entity.entityHistory.table)->ignore
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
  enums->Js.Array2.forEach((enumConfig: Internal.enumConfig<Internal.enum>) => {
    // Create base enum creation query once
    let enumCreateQuery = `CREATE TYPE "${pgSchema}".${enumConfig.name} AS ENUM(${enumConfig.variants
      ->Js.Array2.map(v => `'${v->(Utils.magic: Internal.enum => string)}'`)
      ->Js.Array2.joinWith(", ")});`

    query := query.contents ++ "\n" ++ enumCreateQuery
  })

  // Batch all table creation first (optimal for PostgreSQL)
  allTables->Js.Array2.forEach((table: Table.table) => {
    query := query.contents ++ "\n" ++ makeCreateTableQuery(table, ~pgSchema)
  })

  // Then batch all indices (better performance when tables exist)
  allTables->Js.Array2.forEach((table: Table.table) => {
    let indices = makeCreateTableIndicesQuery(table, ~pgSchema)
    if indices !== "" {
      query := query.contents ++ "\n" ++ indices
    }
  })

  let functionsQuery = ref("")

  // Add derived indices
  entities->Js.Array2.forEach((entity: Internal.entityConfig) => {
    functionsQuery := functionsQuery.contents ++ "\n" ++ entity.entityHistory.createInsertFnQuery

    entity.table
    ->Table.getDerivedFromFields
    ->Js.Array2.forEach(derivedFromField => {
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

  // Add cache row count function
  functionsQuery :=
    functionsQuery.contents ++
    "\n" ++
    `CREATE OR REPLACE FUNCTION ${getCacheRowCountFnName}(table_name text) 
RETURNS integer AS $$
DECLARE
  result integer;
BEGIN
  EXECUTE format('SELECT COUNT(*) FROM "${pgSchema}".%I', table_name) INTO result;
  RETURN result;
END;
$$ LANGUAGE plpgsql;`

  [query.contents]->Js.Array2.concat(
    functionsQuery.contents !== "" ? [functionsQuery.contents] : [],
  )
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

let makeInsertUnnestSetQuery = (~pgSchema, ~table: Table.table, ~itemSchema, ~isRawEvents) => {
  let {quotedFieldNames, quotedNonPrimaryFieldNames, arrayFieldTypes} =
    table->Table.toSqlParams(~schema=itemSchema, ~pgSchema)

  let primaryKeyFieldNames = Table.getPrimaryKeyFieldNames(table)

  `INSERT INTO "${pgSchema}"."${table.tableName}" (${quotedFieldNames->Js.Array2.joinWith(", ")})
SELECT * FROM unnest(${arrayFieldTypes
    ->Js.Array2.mapi((arrayFieldType, idx) => {
      `$${(idx + 1)->Js.Int.toString}::${arrayFieldType}`
    })
    ->Js.Array2.joinWith(",")})` ++
  switch (isRawEvents, primaryKeyFieldNames) {
  | (true, _)
  | (_, []) => ``
  | (false, primaryKeyFieldNames) =>
    `ON CONFLICT(${primaryKeyFieldNames
      ->Js.Array2.map(fieldName => `"${fieldName}"`)
      ->Js.Array2.joinWith(",")}) DO ` ++ (
      quotedNonPrimaryFieldNames->Utils.Array.isEmpty
        ? `NOTHING`
        : `UPDATE SET ${quotedNonPrimaryFieldNames
            ->Js.Array2.map(fieldName => {
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
      placeholders := placeholders.contents ++ `$${(fieldIdx * itemsCount + idx)->Js.Int.toString}`
    }
    placeholders := placeholders.contents ++ ")"
  }

  `INSERT INTO "${pgSchema}"."${table.tableName}" (${quotedFieldNames->Js.Array2.joinWith(", ")})
VALUES${placeholders.contents}` ++
  switch primaryKeyFieldNames {
  | [] => ``
  | primaryKeyFieldNames =>
    `ON CONFLICT(${primaryKeyFieldNames
      ->Js.Array2.map(fieldName => `"${fieldName}"`)
      ->Js.Array2.joinWith(",")}) DO ` ++ (
      quotedNonPrimaryFieldNames->Utils.Array.isEmpty
        ? `NOTHING`
        : `UPDATE SET ${quotedNonPrimaryFieldNames
            ->Js.Array2.map(fieldName => {
              `${fieldName} = EXCLUDED.${fieldName}`
            })
            ->Js.Array2.joinWith(",")}`
    )
  } ++ ";"
}

// Should move this to a better place
// We need it for the isRawEvents check in makeTableBatchSet
// to always apply the unnest optimization.
// This is needed, because even though it has JSON fields,
// they are always guaranteed to be an object.
// FIXME what about Fuel params?
let rawEventsTableName = "raw_events"
let eventSyncStateTableName = "event_sync_state"

// Constants for chunking
let maxItemsPerQuery = 500

let makeTableBatchSetQuery = (~pgSchema, ~table: Table.table, ~itemSchema: S.t<'item>) => {
  let {dbSchema, hasArrayField} = table->Table.toSqlParams(~schema=itemSchema, ~pgSchema)
  let isRawEvents = table.tableName === rawEventsTableName

  // Should experiment how much it'll affect performance
  // Although, it should be fine not to perform the validation check,
  // since the values are validated by type system.
  // As an alternative, we can only run Sury validation only when
  // db write fails to show a better user error.
  let typeValidation = false

  if isRawEvents || !hasArrayField {
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
          serializer: Utils.Array.flatten->Utils.magic,
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
    let chunk = arr->Js.Array2.slice(~start=i.contents, ~end_=i.contents + chunkSize)
    chunks->Js.Array2.push(chunk)->ignore
    i := i.contents + chunkSize
  }
  chunks
}

let removeInvalidUtf8InPlace = entities =>
  entities->Js.Array2.forEach(item => {
    let dict = item->(Utils.magic: 'a => dict<unknown>)
    dict->Utils.Dict.forEachWithKey((key, value) => {
      if value->Js.typeof === "string" {
        let value = value->(Utils.magic: unknown => string)
        // We mutate here, since we don't care
        // about the original value with \x00 anyways.
        //
        // This is unsafe, but we rely that it'll use
        // the mutated reference on retry.
        // TODO: Test it properly after we start using
        // in-memory PGLite for indexer test framework.
        dict->Js.Dict.set(
          key,
          value
          ->Utils.String.replaceAll("\x00", "")
          ->(Utils.magic: string => unknown),
        )
      }
    })
  })

let pgEncodingErrorSchema = S.object(s =>
  s.tag("message", `invalid byte sequence for encoding "UTF8": 0x00`)
)

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
        chunks->Js.Array2.forEach(chunk => {
          let chunkSize = chunk->Array.length
          let isFullChunk = chunkSize === maxItemsPerQuery

          let response = sql->Postgres.preparedUnsafe(
            // Either use the sql query for full chunks from cache
            // or create a new one for partial chunks on the fly.
            isFullChunk
              ? data["query"]
              : makeInsertValuesSetQuery(~pgSchema, ~table, ~itemSchema, ~itemsCount=chunkSize),
            data["convertOrThrow"](chunk->(Utils.magic: array<'item> => array<unknown>)),
          )
          responses->Js.Array2.push(response)->ignore
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
      raise(
        Persistence.StorageError({
          message: `Failed to convert items for table "${table.tableName}"`,
          reason: exn,
        }),
      )
    | exn =>
      raise(
        Persistence.StorageError({
          message: `Failed to insert items into table "${table.tableName}"`,
          reason: exn->Internal.prettifyExn,
        }),
      )
    }
  }
}

let setEntityHistoryOrThrow = (
  sql,
  ~entityHistory: EntityHistory.t<'entity>,
  ~rows: array<EntityHistory.historyRow<'entity>>,
  ~shouldCopyCurrentEntity=?,
  ~shouldRemoveInvalidUtf8=false,
) => {
  rows
  ->Belt.Array.map(historyRow => {
    let row = historyRow->S.reverseConvertToJsonOrThrow(entityHistory.schema)
    if shouldRemoveInvalidUtf8 {
      [row]->removeInvalidUtf8InPlace
    }
    entityHistory.insertFn(
      sql,
      row,
      ~shouldCopyCurrentEntity=switch shouldCopyCurrentEntity {
      | Some(v) => v
      | None => {
          let containsRollbackDiffChange =
            historyRow.containsRollbackDiffChange->Belt.Option.getWithDefault(false)
          !containsRollbackDiffChange
        }
      },
    )
  })
  ->Promise.all
  ->(Utils.magic: promise<array<unit>> => promise<unit>)
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
        let promise = Promise.make((resolve, _reject) => {
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
                          `${binary} -h ${pgHost} -p ${pgDockerServicePort->Js.Int.toString} -U ${pgUser} -d ${pgDatabase}`,
                        ),
                      )
                    }
                  },
                )
              }
            | Null =>
              resolve(
                Ok(
                  `${binary} -h ${pgHost} -p ${pgPort->Js.Int.toString} -U ${pgUser} -d ${pgDatabase}`,
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

let make = (
  ~sql: Postgres.sql,
  ~pgHost,
  ~pgSchema,
  ~pgPort,
  ~pgUser,
  ~pgDatabase,
  ~pgPassword,
  ~onInitialize=?,
  ~onNewTables=?,
): Persistence.storage => {
  let psqlExecOptions: NodeJs.ChildProcess.execOptions = {
    env: Js.Dict.fromArray([("PGPASSWORD", pgPassword), ("PATH", %raw(`process.env.PATH`))]),
  }

  let cacheDirPath = NodeJs.Path.resolve([
    // Right outside of the generated directory
    "..",
    ".envio",
    "cache",
  ])

  let isInitialized = async () => {
    let envioTables =
      await sql->Postgres.unsafe(
        `SELECT table_schema FROM information_schema.tables WHERE table_schema = '${pgSchema}' AND table_name = '${eventSyncStateTableName}';`,
      )
    envioTables->Utils.Array.notEmpty
  }

  let initialize = async (~entities=[], ~generalTables=[], ~enums=[]) => {
    let schemaTableNames: array<schemaTableName> =
      await sql->Postgres.unsafe(makeSchemaTableNamesQuery(~pgSchema))

    // The initialization query will completely drop the schema and recreate it from scratch.
    // So we need to check if the schema is not used for anything else than envio.
    if (
      // Should pass with existing schema with no tables
      // This might happen when used with public schema
      // which is automatically created by postgres.
      schemaTableNames->Utils.Array.notEmpty &&
        // Otherwise should throw if there's a table, but no envio specific one
        // This means that the schema is used for something else than envio.
        !(schemaTableNames->Js.Array2.some(table => table.tableName === eventSyncStateTableName))
    ) {
      Js.Exn.raiseError(
        `Cannot run Envio migrations on PostgreSQL schema "${pgSchema}" because it contains non-Envio tables. Running migrations would delete all data in this schema.\n\nTo resolve this:\n1. If you want to use this schema, first backup any important data, then drop it with: "pnpm envio local db-migrate down"\n2. Or specify a different schema name by setting the "ENVIO_PG_PUBLIC_SCHEMA" environment variable\n3. Or manually drop the schema in your database if you're certain the data is not needed.`,
      )
    }

    let queries = makeInitializeTransaction(
      ~pgSchema,
      ~pgUser,
      ~generalTables,
      ~entities,
      ~enums,
      ~isEmptyPgSchema=schemaTableNames->Utils.Array.isEmpty,
    )
    // Execute all queries within a single transaction for integrity
    let _ = await sql->Postgres.beginSql(sql => {
      queries->Js.Array2.map(query => sql->Postgres.unsafe(query))
    })

    // Integration with other tools like Hasura
    switch onInitialize {
    | Some(onInitialize) => await onInitialize()
    | None => ()
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
      raise(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by ids`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(rowsSchema) catch {
      | exn =>
        raise(
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
      raise(
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
      raise(
        Persistence.StorageError({
          message: `Failed loading "${table.tableName}" from storage by field "${fieldName}"`,
          reason: exn,
        }),
      )
    | rows =>
      try rows->S.parseOrThrow(rowsSchema) catch {
      | exn =>
        raise(
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
      ~itemSchema=itemSchema->S.toUnknown,
      ~pgSchema,
    )
  }

  let setEffectCacheOrThrow = async (
    ~effect: Internal.effect,
    ~items: array<Internal.effectCacheItem>,
    ~initialize: bool,
  ) => {
    let {table, itemSchema} = switch effect.cache {
    | Some(cacheMeta) => cacheMeta
    | None =>
      Js.Exn.raiseError(
        `Failed to set effect cache for "${effect.name}". Effect has no cache enabled.`,
      )
    }

    if initialize {
      let _ = await sql->Postgres.unsafe(makeCreateTableQuery(table, ~pgSchema))
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
        (await sql
        ->Postgres.unsafe(makeSchemaCacheTableInfoQuery(~pgSchema)))
        ->Js.Array2.filter(i => i.count > 0)

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
                ->Js.Array2.map(({tableName, count}) =>
                  tableName ++ " (" ++ count->Belt.Int.toString ++ " rows)"
                )
                ->Js.Array2.joinWith(", ")}`,
            )

            let promises = cacheTableInfo->Js.Array2.map(async ({tableName}) => {
              let cacheName = tableName->Js.String2.sliceToEnd(~from=cacheTablePrefixLength)
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
    | exn => Logging.errorWithExn(exn->Internal.prettifyExn, `Failed to dump cache.`)
    }
  }

  let restoreEffectCache = async (~withUpload) => {
    if withUpload {
      // Try to restore cache tables from binary files
      let nothingToUploadErrorMessage = "Nothing to upload."

      switch await Promise.all2((
        NodeJs.Fs.Promises.readdir(cacheDirPath)
        ->Promise.thenResolve(e => Ok(e))
        ->Promise.catch(_ => Promise.resolve(Error(nothingToUploadErrorMessage))),
        getConnectedPsqlExec(~pgUser, ~pgHost, ~pgDatabase, ~pgPort),
      )) {
      | (Ok(entries), Ok(psqlExec)) => {
          let cacheFiles = entries->Js.Array2.filter(entry => {
            entry->Js.String2.endsWith(".tsv")
          })

          let _ =
            await cacheFiles
            ->Js.Array2.map(entry => {
              let effectName = entry->Js.String2.slice(~from=0, ~to_=-4) // Remove .tsv extension
              let table = Internal.makeCacheTable(~effectName)

              sql
              ->Postgres.unsafe(makeCreateTableQuery(table, ~pgSchema))
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

    let cacheTableInfo: array<schemaCacheTableInfo> =
      await sql->Postgres.unsafe(makeSchemaCacheTableInfoQuery(~pgSchema))

    if withUpload && cacheTableInfo->Utils.Array.notEmpty {
      // Integration with other tools like Hasura
      switch onNewTables {
      | Some(onNewTables) =>
        await onNewTables(
          ~tableNames=cacheTableInfo->Js.Array2.map(info => {
            info.tableName
          }),
        )
      | None => ()
      }
    }

    cacheTableInfo->Js.Array2.map((info): Persistence.effectCacheRecord => {
      {
        effectName: info.tableName->Js.String2.sliceToEnd(~from=cacheTablePrefixLength),
        count: info.count,
      }
    })
  }

  {
    isInitialized,
    initialize,
    loadByFieldOrThrow,
    loadByIdsOrThrow,
    setOrThrow,
    setEffectCacheOrThrow,
    dumpEffectCache,
    restoreEffectCache,
  }
}
