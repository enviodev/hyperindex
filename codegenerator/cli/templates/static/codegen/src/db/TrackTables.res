%%raw(`globalThis.fetch = require('node-fetch')`)
open Fetch

let headers = {
  "Content-Type": "application/json",
  "X-Hasura-Role": Env.Hasura.role,
  "X-Hasura-Admin-Secret": Env.Hasura.secret,
}

type hasuraErrorResponse = {code: string, error: string, path: string}
let hasuraErrorResponseSchema = S.object(s => {
  code: s.field("code", S.string),
  error: s.field("error", S.string),
  path: s.field("path", S.string),
})

type validHasuraResponse = QuerySucceeded | AlreadyDone

let validateHasuraResponse = (~statusCode: int, ~responseJson: Js.Json.t): Belt.Result.t<
  validHasuraResponse,
  unit,
> =>
  if statusCode == 200 {
    Ok(QuerySucceeded)
  } else {
    switch responseJson->S.parseJsonOrThrow(hasuraErrorResponseSchema) {
    | decoded =>
      switch decoded.code {
      | "already-exists"
      | "already-tracked" =>
        Ok(AlreadyDone)
      | _ =>
        //If the code is not known return it as an error
        Error()
      }
    //If we couldn't decode just return it as an error
    | exception S.Raised(_e) => Error()
    }
  }

let clearHasuraMetadata = async () => {
  let body = {
    "type": "clear_metadata",
    "args": Js.Obj.empty(),
  }

  let response = await fetch(
    Env.Hasura.graphqlEndpoint,
    {
      method: #POST,
      body: body->Js.Json.stringifyAny->Belt.Option.getExn->Body.string,
      headers: Headers.fromObject(headers),
    },
  )

  let responseJson = await response->Response.json
  let statusCode = response->Response.status

  switch validateHasuraResponse(~statusCode, ~responseJson) {
  | Error(_) =>
    Logging.error({
      "msg": `EE806: There was an issue clearing metadata in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  | Ok(case) =>
    let msg = switch case {
    | QuerySucceeded => "Metadata Cleared"
    | AlreadyDone => "Metadata Already Cleared"
    }
    Logging.trace({
      "msg": msg,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  }
}

let trackTables = async (~tableNames: array<string>) => {
  let body = {
    "type": "pg_track_tables",
    "args": {
      // If set to false, any warnings will cause the API call to fail and no new tables to be tracked. Otherwise tables that fail to track will be raised as warnings. (default: true)
      "allow_warnings": false,
      "tables": tableNames->Js.Array2.map(tableName =>
        {
          "table": {
            "name": tableName,
            "schema": Env.Db.publicSchema,
          }
          "configuration": {
            // Otherwise the entity in gql will be prefixed with the schema name (when it's not public)
            "custom_name": tableName
          }
        }
      ),
    },
  }

  let response = await fetch(
    Env.Hasura.graphqlEndpoint,
    {
      method: #POST,
      body: body->Js.Json.stringifyAny->Belt.Option.getExn->Body.string,
      headers: Headers.fromObject(headers),
    },
  )

  let responseJson = await response->Response.json
  let statusCode = response->Response.status

  switch validateHasuraResponse(~statusCode, ~responseJson) {
  | Error(_) =>
    Logging.error({
      "msg": `EE807: There was an issue tracking tables in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableNames": tableNames,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  | Ok(case) =>
    let msg = switch case {
    | QuerySucceeded => "Tables Tracked"
    | AlreadyDone => "Table Already Tracked"
    }
    Logging.trace({
      "msg": msg,
      "tableNames": tableNames,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  }
}

let createSelectPermissions = async (~tableName: string) => {
  let body = {
    "type": "pg_create_select_permission",
    "args": {
      "table": {
        "schema": Env.Db.publicSchema,
        "name": tableName,
      },
      "role": "public",
      "source": "default",
      "permission": {
        "columns": "*",
        "filter": Js.Obj.empty(),
        "limit": Env.Hasura.responseLimit,
      },
    },
  }

  let response = await fetch(
    Env.Hasura.graphqlEndpoint,
    {
      method: #POST,
      body: body->Js.Json.stringifyAny->Belt.Option.getExn->Body.string,
      headers: Headers.fromObject(headers),
    },
  )

  let responseJson = await response->Response.json
  let statusCode = response->Response.status

  switch validateHasuraResponse(~statusCode, ~responseJson) {
  | Error(_) =>
    Logging.error({
      "msg": `EE808: There was an issue setting up view permissions for the ${tableName} table in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableName": tableName,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  | Ok(case) =>
    let msg = switch case {
    | QuerySucceeded => "Hasura select permissions created"
    | AlreadyDone => "Hasura select permissions already created"
    }
    Logging.trace({
      "msg": msg,
      "tableName": tableName,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  }
}

let createEntityRelationship = async (
  ~tableName: string,
  ~relationshipType: string,
  ~relationalKey: string,
  ~objectName: string,
  ~mappedEntity: string,
  ~isDerivedFrom: bool,
) => {
  let derivedFromTo = isDerivedFrom ? `"id": "${relationalKey}"` : `"${relationalKey}_id" : "id"`

  let bodyString = `{"type": "pg_create_${relationshipType}_relationship","args": {"table": {"schema": "${Env.Db.publicSchema}", "name": "${tableName}"},"name": "${objectName}","source": "default","using": {"manual_configuration": {"remote_table": {"schema": "${Env.Db.publicSchema}", "name": "${mappedEntity}"},"column_mapping": {${derivedFromTo}}}}}}`

  let response = await fetch(
    Env.Hasura.graphqlEndpoint,
    {
      method: #POST,
      body: bodyString->Body.string,
      headers: Headers.fromObject(headers),
    },
  )

  let responseJson = await response->Response.json
  let statusCode = response->Response.status

  switch validateHasuraResponse(~statusCode, ~responseJson) {
  | Error(_) =>
    Logging.error({
      "msg": `EE808: There was an issue setting up view permissions for the ${tableName} table in hasura - indexing may still work - but you may have issues querying the data in hasura.`,
      "tableName": tableName,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  | Ok(case) =>
    let msg = switch case {
    | QuerySucceeded => "Hasura derived field permissions created"
    | AlreadyDone => "Hasura derived field permissions already created"
    }
    Logging.trace({
      "msg": msg,
      "tableName": tableName,
      "requestStatusCode": statusCode,
      "requestResponseJson": responseJson,
    })
  }
}

let trackAllTables = async () => {
  Logging.info("Tracking tables in Hasura")

  let _ = await clearHasuraMetadata()
  let tableNames =
    [Db.allStaticTables, Db.allEntityTables]
    ->Belt.Array.concatMany
    ->Js.Array2.map(({tableName}) => tableName)
  await trackTables(~tableNames)
  await tableNames->Utils.Array.awaitEach(async tableName => {
    await createSelectPermissions(~tableName)
  })

  await Db.allEntityTables->Utils.Array.awaitEach(async table => {
    let {tableName} = table
    //Set array relationships
    await table
    ->Table.getDerivedFromFields
    ->Utils.Array.awaitEach(async derivedFromField => {
      //determines the actual name of the underlying relational field (if it's an entity mapping then suffixes _id for eg.)
      let relationalFieldName =
        Db.schema->Schema.getDerivedFromFieldName(derivedFromField)->Utils.unwrapResultExn

      await createEntityRelationship(
        ~tableName,
        ~relationshipType="array",
        ~isDerivedFrom=true,
        ~objectName=derivedFromField.fieldName,
        ~relationalKey=relationalFieldName,
        ~mappedEntity=derivedFromField.derivedFromEntity,
      )
    })

    //Set object relationships
    await table
    ->Table.getLinkedEntityFields
    ->Utils.Array.awaitEach(async ((field, linkedEntityName)) => {
      await createEntityRelationship(
        ~tableName,
        ~relationshipType="object",
        ~isDerivedFrom=false,
        ~objectName=field.fieldName,
        ~relationalKey=field.fieldName,
        ~mappedEntity=linkedEntityName,
      )
    })
  })
}
