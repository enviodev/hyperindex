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

        //Set array relationships

        //determines the actual name of the underlying relational field (if it's an entity mapping then suffixes _id for eg.)

        //Set object relationships
      ),
    )
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
      "args": s.field("args", S.json),
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
      "args": s.field("args", S.json),
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

let bulkKeepGoingRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    let _ = s.field("type", S.literal("bulk_keep_going"))
    {
      "args": s.field("args", S.json),
      "auth": s->auth,
    }
  },
  responses: [
    (s: Rest.Response.s) => {
      s.status(200)
      s.data(S.json)
    },
  ],
})
let bulkKeepGoingErrorsSchema = S.array(
  S.union([
    S.object(s => {
      s.tag("message", "success")
      None
    }),
    S.object(s => {
      Some(s.field("error", S.string))
    }),
  ]),
)->S.transform(_ => {
  parser: a => Belt.Array.keepMapU(a, a => a),
})

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
      "msg": `EE806: There was an issue clearing metadata in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "err": exn->Utils.prettifyExn,
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
          "tables": tableNames->Array.map(tableName =>
            {
              "table": {
                "name": tableName,
                "schema": pgSchema,
              },
              "configuration": {
                "custom_name": tableName,
              },
            }
          ),
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
      "tableNames": tableNames,
    })
  } catch {
  | exn =>
    Logging.error({
      "msg": `EE807: There was an issue tracking tables in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableNames": tableNames,
      "err": exn->Utils.prettifyExn,
    })
  }
}

type bulkOperation = {
  \"type": string,
  args: JSON.t,
}

let createSelectPermissionOperation = (
  ~tableName: string,
  ~pgSchema,
  ~responseLimit,
  ~aggregateEntities,
): bulkOperation => {
  {
    \"type": "pg_create_select_permission",
    args: {
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
    }->(Utils.magic: 'a => JSON.t),
  }
}

let createEntityRelationshipOperation = (
  ~pgSchema,
  ~tableName: string,
  ~relationshipType: string,
  ~relationalKey: string,
  ~objectName: string,
  ~mappedEntity: string,
  ~isDerivedFrom: bool,
): bulkOperation => {
  let derivedFromTo = isDerivedFrom ? `"id": "${relationalKey}"` : `"${relationalKey}_id" : "id"`

  {
    \"type": `pg_create_${relationshipType}_relationship`,
    args: {
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
          "column_mapping": JSON.parseOrThrow(`{${derivedFromTo}}`),
        },
      },
    }->(Utils.magic: 'a => JSON.t),
  }
}

let executeBulkKeepGoing = async (~endpoint, ~auth, ~operations: array<bulkOperation>) => {
  if operations->Array.length === 0 {
    Logging.trace("No hasura bulk configuration operations to execute")
  } else {
    try {
      let result = await bulkKeepGoingRoute->Rest.fetch(
        {
          "auth": auth,
          "args": operations->(Utils.magic: 'a => JSON.t),
        },
        ~client=Rest.client(endpoint),
      )

      let errors = try {
        result->S.parseJsonOrThrow(bulkKeepGoingErrorsSchema)
      } catch {
      | S.Error(error) => [error.message]
      | exn => [exn->Utils.prettifyExn->Utils.magic]
      }

      switch errors {
      | [] =>
        Logging.trace({
          "msg": "Hasura configuration completed",
          "operations": operations->Array.length,
        })
      | _ =>
        Logging.warn({
          "msg": "Hasura configuration completed with errors. Indexing will still work - but you may have issues querying data via GraphQL.",
          "errors": errors,
          "operations": operations->Array.length,
        })
      }
    } catch {
    | exn =>
      Logging.error({
        "msg": `EE809: There was an issue executing bulk operations in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
        "operations": operations->Array.length,
        "err": exn->Utils.prettifyExn,
      })
    }
  }
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
  let userTableNames = userEntities->Array.map(entity => entity.table.tableName)
  let tableNames = [exposedInternalTableNames, userTableNames]->Belt.Array.concatMany

  Logging.info("Tracking tables in Hasura")

  let _ = await clearHasuraMetadata(~endpoint, ~auth)

  await trackTables(~endpoint, ~auth, ~pgSchema, ~tableNames)

  // Collect all operations for bulk execution
  let allOperations = []

  // Add select permission operations
  tableNames->Array.forEach(tableName => {
    allOperations
    ->Array.push(
      createSelectPermissionOperation(~tableName, ~pgSchema, ~responseLimit, ~aggregateEntities),
    )
    ->ignore
  })

  // Add relationship operations
  userEntities->Array.forEach(entityConfig => {
    let {tableName} = entityConfig.table

    entityConfig.table
    ->Table.getDerivedFromFields
    ->Array.forEach(derivedFromField => {
      let relationalFieldName =
        schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn

      allOperations
      ->Array.push(
        createEntityRelationshipOperation(
          ~pgSchema,
          ~tableName,
          ~relationshipType="array",
          ~isDerivedFrom=true,
          ~objectName=derivedFromField.fieldName,
          ~relationalKey=relationalFieldName,
          ~mappedEntity=derivedFromField.derivedFromEntity,
        ),
      )
      ->ignore
    })

    entityConfig.table
    ->Table.getLinkedEntityFields
    ->Array.forEach(((field, linkedEntityName)) => {
      allOperations
      ->Array.push(
        createEntityRelationshipOperation(
          ~pgSchema,
          ~tableName,
          ~relationshipType="object",
          ~isDerivedFrom=false,
          ~objectName=field.fieldName,
          ~relationalKey=field.fieldName,
          ~mappedEntity=linkedEntityName,
        ),
      )
      ->ignore
    })
  })

  await executeBulkKeepGoing(~endpoint, ~auth, ~operations=allOperations)
}
