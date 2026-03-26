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
    let _ = s.field("args", S.literal(Js.Obj.empty()))
    s->auth
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

let sendOperation = async (~endpoint, ~auth, ~operation: Js.Json.t) => {
  let maxRetries = 3
  let rec retry = async (~attempt) => {
    try {
      let _ = await rawBodyRoute->Rest.fetch(
        {
          "bodyString": operation->Js.Json.stringify,
          "auth": auth,
        },
        ~client=Rest.client(endpoint),
      )
    } catch {
    | exn =>
      if attempt < maxRetries {
        let backoffMs = Js.Math.pow_float(~base=2.0, ~exp=attempt->Belt.Int.toFloat)->Belt.Float.toInt * 1000
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

let trackTables = async (
  ~endpoint,
  ~auth,
  ~pgSchema,
  ~tableNames: array<string>,
  ~customNames: option<Belt.Map.String.t<string>>=?,
) => {
  try {
    let result = await trackTablesRoute->Rest.fetch(
      {
        "auth": auth,
        "args": {
          // If set to false, any warnings will cause the API call to fail and no new tables to be tracked. Otherwise tables that fail to track will be raised as warnings. (default: true)
          "allow_warnings": false,
          "tables": tableNames->Js.Array2.map(tableName =>
            {
              "table": {
                "name": tableName,
                "schema": pgSchema,
              },
              "configuration": {
                // Otherwise the entity in gql will be prefixed with the schema name (when it's not public)
                "custom_name": switch customNames {
                | Some(map) =>
                  switch map->Belt.Map.String.get(tableName) {
                  | Some(name) => name
                  | None => tableName
                  }
                | None => tableName
                },
              },
            }
          ),
        }->(Utils.magic: 'a => Js.Json.t),
      },
      ~client=Rest.client(endpoint),
    )
    let msg = switch result {
    | QuerySucceeded => "Hasura finished tracking tables"
    | AlreadyDone => "Hasura tables already tracked"
    }
    Logging.trace({
      "msg": msg,
      "tableNames": tableNames,
    })
  } catch {
  | exn =>
    Logging.error({
      "msg": `There was an issue tracking tables in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableNames": tableNames,
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
          "filter": Js.Obj.empty(),
          "limit": responseLimit,
          "allow_aggregations": aggregateEntities->Js.Array2.includes(tableName),
        },
      },
    }->(Utils.magic: 'a => Js.Json.t),
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
) => {
  let derivedFromTo = isDerivedFrom ? `"id": "${relationalKey}"` : `"${relationalKey}_id" : "id"`

  await sendOperation(
    ~endpoint,
    ~auth,
    ~operation={
      "type": `pg_create_${relationshipType}_relationship`,
      "args": {
        "table": {
          "schema": pgSchema,
          "name": tableName,
        },
        "name": objectName,
        "source": "default",
        "using": {
          "manual_configuration": {
            "remote_table": {
              "schema": pgSchema,
              "name": mappedEntity,
            },
            "column_mapping": Js.Json.parseExn(`{${derivedFromTo}}`),
          },
        },
      },
    }->(Utils.magic: 'a => Js.Json.t),
  )
}

let trackFunction = async (~endpoint, ~auth, ~pgSchema, ~functionName: string) => {
  await sendOperation(
    ~endpoint,
    ~auth,
    ~operation={
      "type": "pg_track_function",
      "args": {
        "source": "default",
        "function": {
          "schema": pgSchema,
          "name": functionName,
        },
      },
    }->(Utils.magic: 'a => Js.Json.t),
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
  let exposedInternalTableNames = [
    InternalTable.RawEvents.table.tableName,
    InternalTable.Views.metaViewName,
    InternalTable.Views.chainMetadataViewName,
  ]
  let userTableNames = userEntities->Js.Array2.map(entity => entity.table.tableName)
  let tableNames = [exposedInternalTableNames, userTableNames]->Belt.Array.concatMany

  Logging.info("Tracking tables in Hasura")

  // For entities with @timeTravel, track the table as {Entity}_by_pk
  // so the function can take the {Entity} name
  let timeTravelEntries =
    userEntities
    ->Js.Array2.filter(entity => entity.enableTimeTravel)
    ->Js.Array2.map(entity => {
      let tableName = entity.table.tableName
      (tableName, tableName ++ "_by_pk")
    })
  let customNames = switch timeTravelEntries->Array.length > 0 {
  | true => Some(Belt.Map.String.fromArray(timeTravelEntries))
  | false => None
  }

  let _ = await clearHasuraMetadata(~endpoint, ~auth)

  await trackTables(~endpoint, ~auth, ~pgSchema, ~tableNames, ~customNames?)

  for i in 0 to tableNames->Js.Array2.length - 1 {
    let tableName = tableNames->Js.Array2.unsafe_get(i)
    await createSelectPermission(~endpoint, ~auth, ~tableName, ~pgSchema, ~responseLimit, ~aggregateEntities)
  }

  for i in 0 to userEntities->Js.Array2.length - 1 {
    let entityConfig = userEntities->Js.Array2.unsafe_get(i)
    let {tableName} = entityConfig.table

    //Set array relationships
    let derivedFromFields = entityConfig.table->Table.getDerivedFromFields
    for j in 0 to derivedFromFields->Js.Array2.length - 1 {
      let derivedFromField = derivedFromFields->Js.Array2.unsafe_get(j)
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
      )
    }

    //Set object relationships
    let linkedEntityFields = entityConfig.table->Table.getLinkedEntityFields
    for j in 0 to linkedEntityFields->Js.Array2.length - 1 {
      let (field, linkedEntityName) = linkedEntityFields->Js.Array2.unsafe_get(j)
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
      )
    }
  }

  // Track time travel functions for entities with @timeTravel
  for i in 0 to userEntities->Js.Array2.length - 1 {
    let entityConfig = userEntities->Js.Array2.unsafe_get(i)
    if entityConfig.enableTimeTravel {
      await trackFunction(~endpoint, ~auth, ~pgSchema, ~functionName=entityConfig.table.tableName)
    }
  }

  Logging.info("Hasura configuration completed")
}
