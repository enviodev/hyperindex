type auth = {
  role: string,
  secret: string,
}

type validHasuraResponse = QuerySucceeded | AlreadyDone

let auth = (s: Rest.s) => {
  role: s.header("X-Hasura-Role", S.string),
  secret: s.header("X-Hasura-Admin-Secret", S.string),
}

let responses = [
  (s: Rest.Response.s) => {
    s.status(200)
    let _ = s.data(S.unknown)
    QuerySucceeded
  },
  s => {
    let _ = s.field("code", S.enum(["already-exists", "already-tracked"]))
    AlreadyDone
  },
]

let clearMetadataRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    let _ = s.field("type", S.literal("clear_metadata"))
    let _ = s.field(
      "args",
      S.literal(
        Object.make(),

        // Otherwise the entity in gql will be prefixed with the schema name (when it's not public)
      ),
    )
    s->auth
  },
  responses,
})

let reloadMetadataRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    let _ = s.field("type", S.literal("reload_metadata"))
    {
      "args": s.field("args", S.json(~validate=false)),
      "auth": s->auth,
    }
  },
  responses,
})

let trackTablesRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    let _ = s.field("type", S.literal("pg_track_tables"))
    {
      "args": s.field("args", S.json(~validate=false)),
      "auth": s->auth,
    }
  },
  responses,
})

let rawBodyRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    {
      "bodyString": s.rawBody(S.string),
      "auth": s->auth,
    }
  },
  responses,
})

let sendOperation = async (~endpoint, ~auth, ~operation: JSON.t) => {
  let maxRetries = 3
  let rec retry = async (~attempt) => {
    try {
      let _ = await rawBodyRoute->Rest.fetch(
        {
          "bodyString": operation->JSON.stringify,
          "auth": auth,
        },
        ~client=Rest.client(endpoint),
      )
    } catch {
    | exn =>
      if attempt < maxRetries {
        let backoffMs = Math.pow(2.0, ~exp=attempt->Int.toFloat)->Float.toInt * 1000
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=backoffMs)
        await retry(~attempt=attempt + 1)
      } else {
        Logging.warn({
          "msg": "Hasura configuration request failed. Indexing will still work - but you may have issues querying data via GraphQL.",
          "err": exn->Utils.prettifyExn,
        })
      }
    }
  }
  await retry(~attempt=0)
}

let clearHasuraMetadata = async (~endpoint, ~auth) => {
  try {
    let result = await clearMetadataRoute->Rest.fetch(auth, ~client=Rest.client(endpoint))
    let msg = switch result {
    | QuerySucceeded => "Hasura metadata cleared"
    | AlreadyDone => "Hasura metadata already cleared"
    }
    Logging.trace(msg)
  } catch {
  | exn =>
    Logging.error({
      "msg": `There was an issue clearing metadata in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "err": exn->Utils.prettifyExn,
    })
  }
}

let reloadHasuraMetadata = async (~endpoint, ~auth) => {
  try {
    let result = await reloadMetadataRoute->Rest.fetch(
      {
        "auth": auth,
        "args": {
          "reload_sources": ["default"],
        }->(Utils.magic: 'a => JSON.t),
      },
      ~client=Rest.client(endpoint),
    )
    let msg = switch result {
    | QuerySucceeded => "Hasura metadata reloaded"
    | AlreadyDone => "Hasura metadata reload acknowledged"
    }
    Logging.trace(msg)
  } catch {
  | exn =>
    Logging.error({
      "msg": `There was an issue reloading hasura metadata - table tracking may race with schema creation.`,
      "err": exn->Utils.prettifyExn,
    })
  }
}

type trackTableConfig = {
  tableName: string,
  description: option<string>,
  columnDescriptions: dict<string>,
}

let trackTables = async (~endpoint, ~auth, ~pgSchema, ~tableConfigs: array<trackTableConfig>) => {
  try {
    let result = await trackTablesRoute->Rest.fetch(
      {
        "auth": auth,
        "args": {
          // If set to false, any warnings will cause the API call to fail and no new tables to be tracked. Otherwise tables that fail to track will be raised as warnings. (default: true)
          "allow_warnings": false,
          "tables": tableConfigs->Array.map(({tableName, description, columnDescriptions}) => {
            let configuration = dict{
              "custom_name": tableName->(Utils.magic: string => JSON.t),
            }
            switch description {
            | Some(d) => configuration->Dict.set("comment", d->(Utils.magic: string => JSON.t))
            | None => ()
            }
            let columnConfigEntries = columnDescriptions->Dict.toArray
            if columnConfigEntries->Array.length > 0 {
              let columnConfig = dict{}
              columnConfigEntries->Array.forEach(((column, comment)) =>
                columnConfig->Dict.set(column, {"comment": comment}->(Utils.magic: {..} => JSON.t))
              )
              configuration->Dict.set(
                "column_config",
                columnConfig->(Utils.magic: dict<JSON.t> => JSON.t),
              )
            }
            {
              "table": {
                "name": tableName,
                "schema": pgSchema,
              },
              "configuration": configuration,
            }
          }),
        }->(Utils.magic: 'a => JSON.t),
      },
      ~client=Rest.client(endpoint),
    )
    let msg = switch result {
    | QuerySucceeded => "Hasura finished tracking tables"
    | AlreadyDone => "Hasura tables already tracked"
    }
    Logging.trace({
      "msg": msg,
      "tableNames": tableConfigs->Array.map(c => c.tableName),
    })
  } catch {
  | exn =>
    Logging.error({
      "msg": `There was an issue tracking tables in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableNames": tableConfigs->Array.map(c => c.tableName),
      "err": exn->Utils.prettifyExn,
    })
  }
}

let createSelectPermission = async (
  ~endpoint,
  ~auth,
  ~tableName: string,
  ~pgSchema,
  ~responseLimit,
  ~aggregateEntities,
) => {
  await sendOperation(
    ~endpoint,
    ~auth,
    ~operation={
      "type": "pg_create_select_permission",
      "args": {
        "table": {
          "schema": pgSchema,
          "name": tableName,
        },
        "role": "public",
        "source": "default",
        "permission": {
          "columns": "*",
          "filter": Object.make(),
          "limit": responseLimit,
          "allow_aggregations": aggregateEntities->Array.includes(tableName),
        },
      },
    }->(Utils.magic: 'a => JSON.t),
  )
}

let createEntityRelationship = async (
  ~endpoint,
  ~auth,
  ~pgSchema,
  ~tableName: string,
  ~relationshipType: string,
  ~relationalKey: string,
  ~objectName: string,
  ~mappedEntity: string,
  ~isDerivedFrom: bool,
  ~comment: option<string>=?,
) => {
  let derivedFromTo = isDerivedFrom ? `"id": "${relationalKey}"` : `"${relationalKey}_id" : "id"`

  let tableJson = {
    "schema": pgSchema,
    "name": tableName,
  }->(Utils.magic: {..} => JSON.t)
  let usingJson = {
    "manual_configuration": {
      "remote_table": {
        "schema": pgSchema,
        "name": mappedEntity,
      },
      "column_mapping": JSON.parseOrThrow(`{${derivedFromTo}}`),
    },
  }->(Utils.magic: {..} => JSON.t)

  let args = dict{
    "table": tableJson,
    "name": objectName->(Utils.magic: string => JSON.t),
    "source": "default"->(Utils.magic: string => JSON.t),
    "using": usingJson,
  }
  switch comment {
  | Some(c) => args->Dict.set("comment", c->(Utils.magic: string => JSON.t))
  | None => ()
  }

  await sendOperation(
    ~endpoint,
    ~auth,
    ~operation={
      "type": `pg_create_${relationshipType}_relationship`,
      "args": args,
    }->(Utils.magic: 'a => JSON.t),
  )
}

let trackDatabase = async (
  ~endpoint,
  ~auth,
  ~pgSchema,
  ~userEntities: array<Internal.entityConfig>,
  ~aggregateEntities,
  ~responseLimit,
  ~schema,
) => {
  let exposedInternalTableConfigs = [
    {
      tableName: InternalTable.RawEvents.table.tableName,
      description: None,
      columnDescriptions: dict{},
    },
    {
      tableName: InternalTable.Views.metaViewName,
      description: None,
      columnDescriptions: dict{},
    },
    {
      tableName: InternalTable.Views.chainMetadataViewName,
      description: None,
      columnDescriptions: dict{},
    },
  ]
  let userTableConfigs = userEntities->Array.map(entity => {
    let columnDescriptions = dict{}
    entity.table.fields->Array.forEach(fieldOrDerived =>
      switch fieldOrDerived {
      | Table.Field(field) =>
        switch field.description {
        | Some(d) => columnDescriptions->Dict.set(field->Table.getDbFieldName, d)
        | None => ()
        }
      | Table.DerivedFrom(_) => ()
      }
    )
    {
      tableName: entity.table.tableName,
      description: entity.table.description,
      columnDescriptions,
    }
  })
  let tableConfigs = [exposedInternalTableConfigs, userTableConfigs]->Array.flat
  let tableNames = tableConfigs->Array.map(c => c.tableName)

  Logging.info("Tracking tables in Hasura")

  let _ = await clearHasuraMetadata(~endpoint, ~auth)

  // Force Hasura to re-introspect the source schema before tracking, otherwise
  // freshly-created user tables may be invisible to pg_track_tables and the call
  // returns `metadata-warnings` (HTTP 400), leaving tracking permanently broken.
  await reloadHasuraMetadata(~endpoint, ~auth)

  await trackTables(~endpoint, ~auth, ~pgSchema, ~tableConfigs)

  for i in 0 to tableNames->Array.length - 1 {
    let tableName = tableNames->Array.getUnsafe(i)
    await createSelectPermission(
      ~endpoint,
      ~auth,
      ~tableName,
      ~pgSchema,
      ~responseLimit,
      ~aggregateEntities,
    )
  }

  for i in 0 to userEntities->Array.length - 1 {
    let entityConfig = userEntities->Array.getUnsafe(i)
    let {tableName} = entityConfig.table

    //Set array relationships
    let derivedFromFields = entityConfig.table->Table.getDerivedFromFields
    for j in 0 to derivedFromFields->Array.length - 1 {
      let derivedFromField = derivedFromFields->Array.getUnsafe(j)
      //determines the actual name of the underlying relational field (if it's an entity mapping then suffixes _id for eg.)
      let relationalFieldName =
        schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn

      await createEntityRelationship(
        ~endpoint,
        ~auth,
        ~pgSchema,
        ~tableName,
        ~relationshipType="array",
        ~isDerivedFrom=true,
        ~objectName=derivedFromField.fieldName,
        ~relationalKey=relationalFieldName,
        ~mappedEntity=derivedFromField.derivedFromEntity,
        ~comment=?derivedFromField.description,
      )
    }

    //Set object relationships
    let linkedEntityFields = entityConfig.table->Table.getLinkedEntityFields
    for j in 0 to linkedEntityFields->Array.length - 1 {
      let (field, linkedEntityName) = linkedEntityFields->Array.getUnsafe(j)
      await createEntityRelationship(
        ~endpoint,
        ~auth,
        ~pgSchema,
        ~tableName,
        ~relationshipType="object",
        ~isDerivedFrom=false,
        ~objectName=field.fieldName,
        ~relationalKey=field.fieldName,
        ~mappedEntity=linkedEntityName,
        ~comment=?field.description,
      )
    }
  }

  Logging.info("Hasura configuration completed")
}
