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

let createSelectPermissionRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    let _ = s.field("type", S.literal("pg_create_select_permission"))
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

let clearHasuraMetadata = async (~endpoint, ~auth) => {
  try {
    let result = await clearMetadataRoute->Rest.fetch(auth, ~client=Rest.client(endpoint))
    let msg = switch result {
    | QuerySucceeded => "Metadata Cleared"
    | AlreadyDone => "Metadata Already Cleared"
    }
    Logging.trace(msg)
  } catch {
  | exn =>
    Logging.error({
      "msg": `EE806: There was an issue clearing metadata in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "err": exn->Internal.prettifyExn,
    })
  }
}

let trackTables = async (~endpoint, ~auth, ~pgSchema, ~tableNames: array<string>) => {
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
                "custom_name": tableName,
              },
            }
          ),
        }->(Utils.magic: 'a => Js.Json.t),
      },
      ~client=Rest.client(endpoint),
    )
    let msg = switch result {
    | QuerySucceeded => "Tables Tracked"
    | AlreadyDone => "Table Already Tracked"
    }
    Logging.trace({
      "msg": msg,
      "tableNames": tableNames,
    })
  } catch {
  | exn =>
    Logging.error({
      "msg": `EE807: There was an issue tracking tables in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableNames": tableNames,
      "err": exn->Internal.prettifyExn,
    })
  }
}

let createSelectPermissions = async (
  ~auth,
  ~endpoint,
  ~tableName: string,
  ~pgSchema,
  ~responseLimit,
  ~aggregateEntities,
) => {
  try {
    let result = await createSelectPermissionRoute->Rest.fetch(
      {
        "auth": auth,
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
        }->(Utils.magic: 'a => Js.Json.t),
      },
      ~client=Rest.client(endpoint),
    )
    let msg = switch result {
    | QuerySucceeded => "Hasura select permissions created"
    | AlreadyDone => "Hasura select permissions already created"
    }
    Logging.trace({
      "msg": msg,
      "tableName": tableName,
    })
  } catch {
  | exn =>
    Logging.error({
      "msg": `EE808: There was an issue setting up view permissions for the ${tableName} table in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableName": tableName,
      "err": exn->Internal.prettifyExn,
    })
  }
}

let createEntityRelationship = async (
  ~pgSchema,
  ~endpoint,
  ~auth,
  ~tableName: string,
  ~relationshipType: string,
  ~relationalKey: string,
  ~objectName: string,
  ~mappedEntity: string,
  ~isDerivedFrom: bool,
) => {
  let derivedFromTo = isDerivedFrom ? `"id": "${relationalKey}"` : `"${relationalKey}_id" : "id"`

  let bodyString = `{"type": "pg_create_${relationshipType}_relationship","args": {"table": {"schema": "${pgSchema}", "name": "${tableName}"},"name": "${objectName}","source": "default","using": {"manual_configuration": {"remote_table": {"schema": "${pgSchema}", "name": "${mappedEntity}"},"column_mapping": {${derivedFromTo}}}}}}`

  try {
    let result = await rawBodyRoute->Rest.fetch(
      {
        "auth": auth,
        "bodyString": bodyString,
      },
      ~client=Rest.client(endpoint),
    )
    let msg = switch result {
    | QuerySucceeded => `Hasura ${relationshipType} relationship created`
    | AlreadyDone => `Hasura ${relationshipType} relationship already created`
    }
    Logging.trace({
      "msg": msg,
      "tableName": tableName,
    })
  } catch {
  | exn =>
    Logging.error({
      "msg": `EE808: There was an issue setting up ${relationshipType} relationship for the ${tableName} table in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableName": tableName,
      "err": exn->Internal.prettifyExn,
    })
  }
}

let trackDatabase = async (
  ~endpoint,
  ~auth,
  ~pgSchema,
  ~allStaticTables,
  ~allEntityTables,
  ~aggregateEntities,
  ~responseLimit,
  ~schema,
) => {
  Logging.info("Tracking tables in Hasura")

  let _ = await clearHasuraMetadata(~endpoint, ~auth)
  let tableNames =
    [allStaticTables, allEntityTables]
    ->Belt.Array.concatMany
    ->Js.Array2.map(({tableName}: Table.table) => tableName)

  await trackTables(~endpoint, ~auth, ~pgSchema, ~tableNames)

  let _ =
    await tableNames
    ->Js.Array2.map(tableName =>
      createSelectPermissions(
        ~endpoint,
        ~auth,
        ~tableName,
        ~pgSchema,
        ~responseLimit,
        ~aggregateEntities,
      )
    )
    ->Js.Array2.concatMany(
      allEntityTables->Js.Array2.map(table => {
        let {tableName} = table
        [
          //Set array relationships
          table
          ->Table.getDerivedFromFields
          ->Js.Array2.map(derivedFromField => {
            //determines the actual name of the underlying relational field (if it's an entity mapping then suffixes _id for eg.)
            let relationalFieldName =
              schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn

            createEntityRelationship(
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
          }),
          //Set object relationships
          table
          ->Table.getLinkedEntityFields
          ->Js.Array2.map(((field, linkedEntityName)) => {
            createEntityRelationship(
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
          }),
        ]->Utils.Array.flatten
      }),
    )
    ->Promise.all
}
