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
    `DROP SCHEMA IF EXISTS "${pgSchema}" CASCADE;
CREATE SCHEMA "${pgSchema}";
GRANT ALL ON SCHEMA "${pgSchema}" TO "${pgUser}";
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
    table->Table.toSqlParams(~schema=itemSchema)

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
  let {quotedFieldNames, quotedNonPrimaryFieldNames} = table->Table.toSqlParams(~schema=itemSchema)

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
  let {dbSchema, hasArrayField} = table->Table.toSqlParams(~schema=itemSchema)
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
          reason: exn,
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

let cacheTablePrefix = "envio_cache_"
let cacheTablePrefixLength = cacheTablePrefix->String.length

let make = (~sql: Postgres.sql, ~pgSchema, ~pgUser): Persistence.storage => {
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

    let queries = makeInitializeTransaction(~pgSchema, ~pgUser, ~generalTables, ~entities, ~enums)
    // Execute all queries within a single transaction for integrity
    let _ = await sql->Postgres.beginSql(sql => {
      queries->Js.Array2.map(query => sql->Postgres.unsafe(query))
    })

    // Try to restore cache tables from binary files
    let cacheDir = NodeJs.Path.resolve(["..", ".envio", "cache"])

    let entries = await NodeJs.Fs.Promises.readdir(cacheDir)
    let cacheFiles = entries->Js.Array2.filter(entry => {
      entry->Js.String2.endsWith(".bin")
    })

    let psqlExec = switch NodeJs.Process.process.env->Js.Dict.get("ENVIO_PSQL_EXEC") {
    | Some(exec) => exec
    | None => "docker-compose exec -T -u postgres envio-postgres psql"
    }

    let _ =
      await cacheFiles
      ->Js.Array2.map(entry => {
        let cacheName = entry->Js.String2.slice(~from=0, ~to_=-4) // Remove .bin extension
        let table = Table.mkTable(
          cacheTablePrefix ++ cacheName,
          ~fields=[
            Table.mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey=true),
            Table.mkField("value", JsonB, ~fieldSchema=S.json(~validate=false)),
          ],
          ~compositeIndices=[],
        )

        sql
        ->Postgres.unsafe(makeCreateTableQuery(table, ~pgSchema))
        ->Promise.then(() => {
          let tableName = cacheTablePrefix ++ cacheName
          let inputFile = NodeJs.Path.join(cacheDir, entry)->NodeJs.Path.toString

          // We use -d envio-dev to specify the database name
          // -c specifies the command to run
          // -T disables pseudo-tty allocation
          // We use COPY ... FROM STDIN (FORMAT binary) to restore the table from binary format
          let command = `${psqlExec} -d envio-dev -c 'COPY "${pgSchema}"."${tableName}" FROM STDIN (FORMAT binary);' < ${inputFile}`
          NodeJs.ChildProcess.exec(command, {})
        })
      })
      ->Promise.all
  }

  let loadCaches = async () => {
    let schemaTableNames: array<schemaTableName> =
      await sql->Postgres.unsafe(makeSchemaTableNamesQuery(~pgSchema))
    schemaTableNames->Belt.Array.keepMapU(schemaTableName => {
      if schemaTableName.tableName->Js.String2.startsWith(cacheTablePrefix) {
        Some(
          (
            {
              // Remove the prefix from the table name
              name: schemaTableName.tableName->Js.String2.sliceToEnd(~from=cacheTablePrefixLength),
              size: 0,
            }: Persistence.cache
          ),
        )
      } else {
        None
      }
    })
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

  let setCacheOrThrow = async (
    type item,
    ~name: string,
    ~keys: array<string>,
    ~values: array<item>,
    ~valueSchema: S.t<item>,
    ~initialize: bool,
  ) => {
    let table = Table.mkTable(
      cacheTablePrefix ++ name,
      ~fields=[
        Table.mkField("id", Text, ~fieldSchema=S.string, ~isPrimaryKey=true),
        Table.mkField("value", JsonB, ~fieldSchema=valueSchema),
      ],
      ~compositeIndices=[],
    )

    if initialize {
      await sql->Postgres.unsafe(makeCreateTableQuery(table, ~pgSchema))
    }

    let items = []
    for idx in 0 to values->Array.length - 1 {
      items
      ->Js.Array2.push({
        "id": keys[idx],
        "value": values[idx],
      })
      ->ignore
    }

    await setOrThrow(
      ~items,
      ~table,
      ~itemSchema=S.schema(s =>
        {
          "id": s.matches(S.string),
          "value": s.matches(valueSchema),
        }
      ),
    )
  }

  let dumpCache = async (cacheNames: array<string>) => {
    // Create .envio/cache directory if it doesn't exist
    let cacheDir = NodeJs.Path.resolve(["..", ".envio", "cache"])
    try {
      await NodeJs.Fs.Promises.access(cacheDir)
    } catch {
    | _ =>
      // Create directory if it doesn't exist
      await NodeJs.Fs.Promises.mkdir(~path=cacheDir, ~options={recursive: true})
    }

    // For development: We run the indexer project locally,
    //   and there might not be psql installed on the user's machine.
    //   So we use docker-compose to run psql existing in the postgres container.
    // For production: We expect indexer to be running in a container,
    //   with psql installed. So we can call it directly.
    let psqlExec = switch NodeJs.Process.process.env->Js.Dict.get("ENVIO_PSQL_EXEC") {
    | Some(exec) => exec
    | None => "docker-compose exec -T -u postgres envio-postgres psql"
    }

    let _ =
      await cacheNames
      ->Js.Array2.map(cacheName => {
        let tableName = cacheTablePrefix ++ cacheName
        let outputFile = NodeJs.Path.join(cacheDir, cacheName ++ ".bin")->NodeJs.Path.toString

        // We use -d envio-dev to specify the database name
        // -c specifies the command to run
        // -T disables pseudo-tty allocation
        // We use COPY ... TO STDOUT (FORMAT binary) to dump the table in binary format
        let command = `${psqlExec} -d envio-dev -c 'COPY "${pgSchema}"."${tableName}" TO STDOUT (FORMAT binary);' > ${outputFile}`
        NodeJs.ChildProcess.exec(command, {})
      })
      ->Promise.all
  }

  {
    isInitialized,
    initialize,
    loadByFieldOrThrow,
    loadCaches,
    loadByIdsOrThrow,
    setOrThrow,
    setCacheOrThrow,
    dumpCache,
  }
}
