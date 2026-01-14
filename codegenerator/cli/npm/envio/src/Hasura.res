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

let bulkKeepGoingRoute = Rest.route(() => {
  method: Post,
  path: "",
  input: s => {
    let _ = s.field("type", S.literal("bulk_keep_going"))
    {
      "args": s.field("args", S.json(~validate=false)),
      "auth": s->auth,
    }
  },
  responses: [
    (s: Rest.Response.s) => {
      s.status(200)
      s.data(S.json(~validate=false))
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
  args: Js.Json.t,
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
        "filter": Js.Obj.empty(),
        "limit": responseLimit,
        "allow_aggregations": aggregateEntities->Js.Array2.includes(tableName),
      },
    }->(Utils.magic: 'a => Js.Json.t),
  }
}

let createTableCustomizationOperation = (
  ~pgSchema,
  ~tableName: string,
  ~tableDescription: option<string>,
  ~columnDescriptions: array<(string, string)>,
): bulkOperation => {
  // Build column_config object with comments for each column that has a description
  let columnConfig = Js.Dict.empty()
  columnDescriptions->Js.Array2.forEach(((columnName, description)) => {
    columnConfig->Js.Dict.set(columnName, {"comment": description}->Obj.magic)
  })

  let tableComment = tableDescription->Belt.Option.getWithDefault("")

  {
    \"type": "pg_set_table_customization",
    args: {
      "table": {
        "schema": pgSchema,
        "name": tableName,
      },
      "source": "default",
      "configuration": {
        "custom_name": tableName,
        "comment": tableComment,
        "column_config": columnConfig,
      },
    }->Obj.magic,
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
          "column_mapping": Js.Json.parseExn(`{${derivedFromTo}}`),
        },
      },
    }->(Utils.magic: 'a => Js.Json.t),
  }
}

let executeBulkKeepGoing = async (~endpoint, ~auth, ~operations: array<bulkOperation>) => {
  if operations->Js.Array2.length === 0 {
    Logging.trace("No hasura bulk configuration operations to execute")
  } else {
    try {
      let result = await bulkKeepGoingRoute->Rest.fetch(
        {
          "auth": auth,
          "args": operations->(Utils.magic: 'a => Js.Json.t),
        },
        ~client=Rest.client(endpoint),
      )

      let errors = try {
        result->S.parseJsonOrThrow(bulkKeepGoingErrorsSchema)
      } catch {
      | S.Raised(error) => [error->S.Error.message]
      | exn => [exn->Utils.prettifyExn->Utils.magic]
      }

      switch errors {
      | [] =>
        Logging.trace({
          "msg": "Hasura configuration completed",
          "operations": operations->Js.Array2.length,
        })
      | _ =>
        Logging.warn({
          "msg": "Hasura configuration completed with errors. Indexing will still work - but you may have issues querying data via GraphQL.",
          "errors": errors,
          "operations": operations->Js.Array2.length,
        })
      }
    } catch {
    | exn =>
      Logging.error({
        "msg": `EE809: There was an issue executing bulk operations in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
        "operations": operations->Js.Array2.length,
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
  let userTableNames = userEntities->Js.Array2.map(entity => entity.table.tableName)
  let tableNames = [exposedInternalTableNames, userTableNames]->Belt.Array.concatMany

  Logging.info("Tracking tables in Hasura")

  let _ = await clearHasuraMetadata(~endpoint, ~auth)

  await trackTables(~endpoint, ~auth, ~pgSchema, ~tableNames)

  // Collect all operations for bulk execution
  let allOperations = []

  // Add select permission operations
  tableNames->Js.Array2.forEach(tableName => {
    allOperations
    ->Js.Array2.push(
      createSelectPermissionOperation(~tableName, ~pgSchema, ~responseLimit, ~aggregateEntities),
    )
    ->ignore
  })

  // Add relationship operations
  userEntities->Js.Array2.forEach(entityConfig => {
    let {tableName} = entityConfig.table

    //Set array relationships
    entityConfig.table
    ->Table.getDerivedFromFields
    ->Js.Array2.forEach(derivedFromField => {
      //determines the actual name of the underlying relational field (if it's an entity mapping then suffixes _id for eg.)
      let relationalFieldName =
        schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn

      allOperations
      ->Js.Array2.push(
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

    //Set object relationships
    entityConfig.table
    ->Table.getLinkedEntityFields
    ->Js.Array2.forEach(((field, linkedEntityName)) => {
      allOperations
      ->Js.Array2.push(
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

    // Add table customization for comments/descriptions
    let columnDescriptions =
      entityConfig.table.fields
      ->Belt.Array.keepMap(fieldOrDerived =>
        switch fieldOrDerived {
        | Table.Field(field) =>
          switch field.description {
          | Some(desc) =>
            let dbFieldName = field->Table.getDbFieldName
            Some((dbFieldName, desc))
          | None => None
          }
        | Table.DerivedFrom(_) => None
        }
      )

    // Only add customization if there's a table description or any column descriptions
    if entityConfig.description->Belt.Option.isSome || columnDescriptions->Js.Array2.length > 0 {
      allOperations
      ->Js.Array2.push(
        createTableCustomizationOperation(
          ~pgSchema,
          ~tableName,
          ~tableDescription=entityConfig.description,
          ~columnDescriptions,
        ),
      )
      ->ignore
    }
  })

  await executeBulkKeepGoing(~endpoint, ~auth, ~operations=allOperations)
}
