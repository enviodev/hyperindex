/*
Vendored from: https://github.com/DZakh/rescript-rest
Version: 1.0.1

IF EDITING THIS FILE, PLEASE LIST THE CHANGES BELOW

here

 */

@@uncurried

module Exn = {
  type error

  @new
  external makeError: string => error = "Error"

  let raiseAny = (any: 'any): 'a => any->Obj.magic->raise

  let raiseError: error => 'a = raiseAny
}

module Obj = {
  external magic: 'a => 'b = "%identity"
}

module Promise = {
  type t<+'a> = promise<'a>

  @send
  external thenResolve: (t<'a>, 'a => 'b) => t<'b> = "then"
}

module Option = {
  let unsafeSome: 'a => option<'a> = Obj.magic
  let unsafeUnwrap: option<'a> => 'a = Obj.magic
}

module Dict = {
  @inline
  let has = (dict, key) => {
    dict->Js.Dict.unsafeGet(key)->(Obj.magic: 'a => bool)
  }
}

@inline
let panic = message => Exn.raiseError(Exn.makeError(`[rescript-rest] ${message}`))

@val
external encodeURIComponent: string => string = "encodeURIComponent"

module ApiFetcher = {
  type args = {body: option<unknown>, headers: option<dict<unknown>>, method: string, path: string}
  type response = {data: unknown, status: int, headers: dict<unknown>}
  type t = args => promise<response>

  %%private(external fetch: (string, args) => promise<{..}> = "fetch")

  // Inspired by https://github.com/ts-rest/ts-rest/blob/7792ef7bdc352e84a4f5766c53f984a9d630c60e/libs/ts-rest/core/src/lib/client.ts#L102
  /**
  * Default fetch api implementation:
  *
  * Can be used as a reference for implementing your own fetcher,
  * or used in the "api" field of ClientArgs to allow you to hook
  * into the request to run custom logic
  */
  let default: t = async (args): response => {
    let result = await fetch(args.path, args)
    let contentType = result["headers"]["get"]("content-type")

    // Note: contentType might be null
    if (
      contentType->Obj.magic &&
      contentType->Js.String2.includes("application/") &&
      contentType->Js.String2.includes("json")
    ) {
      {
        status: result["status"],
        data: await result["json"](),
        headers: result["headers"],
      }
    } else if contentType->Obj.magic && contentType->Js.String2.includes("text/") {
      {
        status: result["status"],
        data: await result["text"](),
        headers: result["headers"],
      }
    } else {
      {
        status: result["status"],
        data: await result["blob"](),
        headers: result["headers"],
      }
    }
  }
}

module Response = {
  type numiricStatus = [
    | #100
    | #101
    | #102
    | #200
    | #201
    | #202
    | #203
    | #204
    | #205
    | #206
    | #207
    | #300
    | #301
    | #302
    | #303
    | #304
    | #305
    | #307
    | #308
    | #400
    | #401
    | #402
    | #403
    | #404
    | #405
    | #406
    | #407
    | #408
    | #409
    | #410
    | #411
    | #412
    | #413
    | #414
    | #415
    | #416
    | #417
    | #418
    | #419
    | #420
    | #421
    | #422
    | #423
    | #424
    | #428
    | #429
    | #431
    | #451
    | #500
    | #501
    | #502
    | #503
    | #504
    | #505
    | #507
    | #511
  ]
  type status = [
    | #"1XX"
    | #"2XX"
    | #"3XX"
    | #"4XX"
    | #"5XX"
    | numiricStatus
  ]

  type s = {
    status: int => unit,
    description: string => unit,
    data: 'value. S.t<'value> => 'value,
    field: 'value. (string, S.t<'value>) => 'value,
    header: 'value. (string, S.t<'value>) => 'value,
  }

  type t<'response> = {
    // When it's empty, treat response as a default
    status: option<int>,
    description: option<string>,
    dataSchema: S.t<unknown>,
    emptyData: bool,
    schema: S.t<'response>,
  }

  type builder<'response> = {
    // When it's empty, treat response as a default
    mutable status?: int,
    mutable description?: string,
    mutable dataSchema?: S.t<unknown>,
    mutable emptyData: bool,
    mutable schema?: S.t<'response>,
  }

  let register = (
    map: dict<t<'response>>,
    status: [< status | #default],
    builder: builder<'response>,
  ) => {
    let key = status->(Obj.magic: [< status | #default] => string)
    if map->Dict.has(key) {
      panic(`Response for the "${key}" status registered multiple times`)
    } else {
      map->Js.Dict.set(key, builder->(Obj.magic: builder<'response> => t<'response>))
    }
  }

  @inline
  let find = (map: dict<t<'response>>, responseStatus: int): option<t<'response>> => {
    (map
    ->Js.Dict.unsafeGet(responseStatus->(Obj.magic: int => string))
    ->(Obj.magic: t<'response> => bool) ||
    map
    ->Js.Dict.unsafeGet((responseStatus / 100)->(Obj.magic: int => string) ++ "XX")
    ->(Obj.magic: t<'response> => bool) ||
    map->Js.Dict.unsafeGet("default")->(Obj.magic: t<'response> => bool))
      ->(Obj.magic: bool => option<t<'response>>)
  }
}

type pathParam = {name: string}
@unboxed
type pathItem = Static(string) | Param(pathParam)

type auth = Bearer | Basic

type s = {
  field: 'value. (string, S.t<'value>) => 'value,
  body: 'value. S.t<'value> => 'value,
  rawBody: 'value. S.t<'value> => 'value,
  header: 'value. (string, S.t<'value>) => 'value,
  query: 'value. (string, S.t<'value>) => 'value,
  param: 'value. (string, S.t<'value>) => 'value,
  auth: auth => string,
}

type method =
  | @as("GET") Get
  | @as("POST") Post
  | @as("PUT") Put
  | @as("PATCH") Patch
  | @as("DELETE") Delete
  | @as("HEAD") Head
  | @as("OPTIONS") Options
  | @as("TRACE") Trace

type definition<'variables, 'response> = {
  method: method,
  path: string,
  variables: s => 'variables,
  responses: array<Response.s => 'response>,
  summary?: string,
  description?: string,
  deprecated?: bool,
}

type routeParams<'variables, 'response> = {
  definition: definition<'variables, 'response>,
  pathItems: array<pathItem>,
  variablesSchema: S.t<'variables>,
  responses: array<Response.t<'response>>,
  responsesMap: dict<Response.t<'response>>,
  isRawBody: bool,
}

type route<'variables, 'response> = unit => definition<'variables, 'response>

let rec parsePath = (path: string, ~pathItems, ~pathParams) => {
  if path !== "" {
    switch path->Js.String2.indexOf("{") {
    | -1 => pathItems->Js.Array2.push(Static(path))->ignore
    | paramStartIdx =>
      switch path->Js.String2.indexOf("}") {
      | -1 => panic("Path contains an unclosed parameter")
      | paramEndIdx =>
        if paramStartIdx > paramEndIdx {
          panic("Path parameter is not enclosed in curly braces")
        }
        let paramName = Js.String2.slice(path, ~from=paramStartIdx + 1, ~to_=paramEndIdx)
        if paramName === "" {
          panic("Path parameter name cannot be empty")
        }
        let param = {name: paramName}

        pathItems
        ->Js.Array2.push(Static(Js.String2.slice(path, ~from=0, ~to_=paramStartIdx)))
        ->ignore
        pathItems->Js.Array2.push(Param(param))->ignore
        pathParams->Js.Dict.set(paramName, param)->ignore

        parsePath(Js.String2.sliceToEnd(path, ~from=paramEndIdx + 1), ~pathItems, ~pathParams)
      }
    }
  }
}

let coerceSchema = schema => {
  schema->S.preprocess(s => {
    let tagged = switch s.schema->S.classify {
    | Option(optionalSchema) => optionalSchema->S.classify
    | tagged => tagged
    }
    switch tagged {
    | Literal(Boolean(_))
    | Bool => {
        parser: unknown =>
          switch unknown->Obj.magic {
          | "true" => true
          | "false" => false
          | _ => unknown->Obj.magic
          }->Obj.magic,
      }
    | Literal(Number(_))
    | Int
    | Float => {
        parser: unknown => {
          let float = %raw(`+unknown`)
          if Js.Float.isNaN(float) {
            unknown
          } else {
            float->Obj.magic
          }
        },
      }
    | String
    | Literal(String(_))
    | Union(_)
    | Never => {}
    | _ => {}
    }
  })
}

let stripInPlace = schema => (schema->S.classify->Obj.magic)["unknownKeys"] = S.Strip
let getSchemaField = (schema, fieldName): option<S.item> =>
  (schema->S.classify->Obj.magic)["fields"]->Js.Dict.unsafeGet(fieldName)

type typeValidation = (unknown, ~inputVar: string) => string
let removeTypeValidationInPlace = schema => (schema->Obj.magic)["f"] = ()
let setTypeValidationInPlace = (schema, typeValidation: typeValidation) =>
  (schema->Obj.magic)["f"] = typeValidation
let unsafeGetTypeValidationInPlace = (schema): typeValidation => (schema->Obj.magic)["f"]

let isNestedFlattenSupported = schema =>
  switch schema->S.classify {
  | Object({advanced: false}) =>
    switch schema
    ->S.reverse
    ->S.classify {
    | Object({advanced: false}) => true
    | _ => false
    }
  | _ => false
  }

let bearerAuthSchema = S.string->S.transform(s => {
  serializer: token => {
    `Bearer ${token}`
  },
  parser: string => {
    switch string->Js.String2.split(" ") {
    | ["Bearer", token] => token
    | _ => s.fail("Invalid Bearer token")
    }
  },
})

let basicAuthSchema = S.string->S.transform(s => {
  serializer: token => {
    `Basic ${token}`
  },
  parser: string => {
    switch string->Js.String2.split(" ") {
    | ["Basic", token] => token
    | _ => s.fail("Invalid Basic token")
    }
  },
})

let params = route => {
  switch (route->Obj.magic)["_rest"]->(
    Obj.magic: unknown => option<routeParams<'variables, 'response>>
  ) {
  | Some(params) => params
  | None => {
      let routeDefinition = (
        route->(Obj.magic: route<'variables, 'response> => route<unknown, unknown>)
      )()

      let pathItems = []
      let pathParams = Js.Dict.empty()
      parsePath(routeDefinition.path, ~pathItems, ~pathParams)

      // Don't use ref, since it creates an unnecessary object
      let isRawBody = %raw(`false`)

      let variablesSchema = S.object(s => {
        routeDefinition.variables({
          field: (fieldName, schema) => {
            s.nested("body").field(fieldName, schema)
          },
          body: schema => {
            if schema->isNestedFlattenSupported {
              s.nested("body").flatten(schema)
            } else {
              s.field("body", schema)
            }
          },
          rawBody: schema => {
            let isNonStringBased = switch schema->S.classify {
            | Literal(String(_))
            | String => false
            | _ => true
            }
            if isNonStringBased {
              panic("Only string-based schemas are allowed in rawBody")
            }
            let _ = %raw(`isRawBody = true`)
            s.field("body", schema)
          },
          header: (fieldName, schema) => {
            s.nested("headers").field(fieldName->Js.String2.toLowerCase, coerceSchema(schema))
          },
          query: (fieldName, schema) => {
            s.nested("query").field(fieldName, coerceSchema(schema))
          },
          param: (fieldName, schema) => {
            if !Dict.has(pathParams, fieldName) {
              panic(`Path parameter "${fieldName}" is not defined in the path`)
            }
            s.nested("params").field(fieldName, coerceSchema(schema))
          },
          auth: auth => {
            s.nested("headers").field(
              "authorization",
              switch auth {
              | Bearer => bearerAuthSchema
              | Basic => basicAuthSchema
              },
            )
          },
        })
      })

      {
        // The variables input is guaranteed to be an object, so we reset the rescript-schema type filter here
        variablesSchema->stripInPlace
        variablesSchema->removeTypeValidationInPlace
        switch variablesSchema->getSchemaField("headers") {
        | Some({schema}) =>
          schema->stripInPlace
          schema->removeTypeValidationInPlace
        | None => ()
        }
        switch variablesSchema->getSchemaField("params") {
        | Some({schema}) => schema->removeTypeValidationInPlace
        | None => ()
        }
        switch variablesSchema->getSchemaField("query") {
        | Some({schema}) => schema->removeTypeValidationInPlace
        | None => ()
        }
      }

      let responsesMap = Js.Dict.empty()
      let responses = []
      routeDefinition.responses->Js.Array2.forEach(r => {
        let builder: Response.builder<unknown> = {
          emptyData: true,
        }
        let schema = S.object(s => {
          let definition = r({
            status: status => {
              builder.status = Some(status)
              let status = status->(Obj.magic: int => Response.status)
              responsesMap->Response.register(status, builder)
              s.tag("status", status)
            },
            description: d => builder.description = Some(d),
            field: (fieldName, schema) => {
              builder.emptyData = false
              s.nested("data").field(fieldName, schema)
            },
            data: schema => {
              builder.emptyData = false
              if schema->isNestedFlattenSupported {
                s.nested("data").flatten(schema)
              } else {
                s.field("data", schema)
              }
            },
            header: (fieldName, schema) => {
              s.nested("headers").field(fieldName->Js.String2.toLowerCase, coerceSchema(schema))
            },
          })
          if builder.emptyData {
            s.tag("data", %raw(`null`))
          }
          definition
        })
        if builder.status === None {
          responsesMap->Response.register(#default, builder)
        }
        schema->stripInPlace
        schema->removeTypeValidationInPlace
        let dataSchema = (schema->getSchemaField("data")->Option.unsafeUnwrap).schema
        builder.dataSchema = dataSchema->Option.unsafeSome
        switch dataSchema->S.classify {
        | Literal(_) => {
            let dataTypeValidation = dataSchema->unsafeGetTypeValidationInPlace
            schema->setTypeValidationInPlace((b, ~inputVar) =>
              dataTypeValidation(b, ~inputVar=`${inputVar}.data`)
            )
          }
        | _ => ()
        }
        switch schema->getSchemaField("headers") {
        | Some({schema}) =>
          schema->stripInPlace
          schema->removeTypeValidationInPlace
        | None => ()
        }
        builder.schema = Option.unsafeSome(schema)
        responses
        ->Js.Array2.push(builder->(Obj.magic: Response.builder<unknown> => Response.t<unknown>))
        ->ignore
      })

      if responses->Js.Array2.length === 0 {
        panic("At least single response should be registered")
      }

      let params = {
        definition: routeDefinition,
        variablesSchema,
        responses,
        pathItems,
        responsesMap,
        isRawBody,
      }
      (route->Obj.magic)["_rest"] = params
      params->(Obj.magic: routeParams<unknown, unknown> => routeParams<'variables, 'response>)
    }
  }
}

external route: (unit => definition<'variables, 'response>) => route<'variables, 'response> =
  "%identity"

type client = {
  call: 'variables 'response. (route<'variables, 'response>, 'variables) => promise<'response>,
  baseUrl: string,
  fetcher: ApiFetcher.t,
  // By default, all query parameters are encoded as strings, however, you can use the jsonQuery option to encode query parameters as typed JSON values.
  jsonQuery: bool,
}

/**
 * A recursive function to convert an object/string/number/whatever into an array of key=value pairs
 *
 * This should be fully compatible with the "qs" library, but more optimised and without the need to add a dependency
 */
let rec tokeniseValue = (key, value, ~append) => {
  if Js.Array2.isArray(value) {
    value
    ->(Obj.magic: unknown => array<unknown>)
    ->Js.Array2.forEachi((v, idx) => {
      tokeniseValue(`${key}[${idx->Js.Int.toString}]`, v, ~append)
    })
  } else if value === %raw(`null`) {
    append(key, "")
  } else if value === %raw(`void 0`) {
    ()
  } else if Js.typeof(value) === "object" {
    let dict = value->(Obj.magic: unknown => dict<unknown>)
    dict
    ->Js.Dict.keys
    ->Js.Array2.forEach(k => {
      tokeniseValue(`${key}[${encodeURIComponent(k)}]`, dict->Js.Dict.unsafeGet(k), ~append)
    })
  } else {
    append(key, value->(Obj.magic: unknown => string))
  }
}

// Inspired by https://github.com/ts-rest/ts-rest/blob/7792ef7bdc352e84a4f5766c53f984a9d630c60e/libs/ts-rest/core/src/lib/client.ts#L347
let getCompletePath = (~baseUrl, ~pathItems, ~maybeQuery, ~maybeParams, ~jsonQuery) => {
  let path = ref(baseUrl)

  for idx in 0 to pathItems->Js.Array2.length - 1 {
    let pathItem = pathItems->Js.Array2.unsafe_get(idx)
    switch pathItem {
    | Static(static) => path := path.contents ++ static
    | Param({name}) =>
      switch (maybeParams->Obj.magic && maybeParams->Js.Dict.unsafeGet(name)->Obj.magic)
        ->(Obj.magic: bool => option<string>) {
      | Some(param) => path := path.contents ++ param
      | None => panic(`Path parameter "${name}" is not defined in variables`)
      }
    }
  }

  switch maybeQuery {
  | None => ()
  | Some(query) => {
      let queryItems = []

      let append = (key, value) => {
        let _ = queryItems->Js.Array2.push(key ++ "=" ++ encodeURIComponent(value))
      }

      let queryNames = query->Js.Dict.keys
      for idx in 0 to queryNames->Js.Array2.length - 1 {
        let queryName = queryNames->Js.Array2.unsafe_get(idx)
        let value = query->Js.Dict.unsafeGet(queryName)
        let key = encodeURIComponent(queryName)
        if value !== %raw(`void 0`) {
          switch jsonQuery {
          // if value is a string and is not a reserved JSON value or a number, pass it without encoding
          // this makes strings look nicer in the URL (e.g. ?name=John instead of ?name=%22John%22)
          // this is also how OpenAPI will pass strings even if they are marked as application/json types
          | true =>
            append(
              key,
              if (
                Js.typeof(value) === "string" && {
                    let value = value->(Obj.magic: unknown => string)
                    value !== "true" &&
                    value !== "false" &&
                    value !== "null" &&
                    Js.Float.isNaN(Js.Float.fromString(value))
                  }
              ) {
                value->(Obj.magic: unknown => string)
              } else {
                value->(Obj.magic: unknown => Js.Json.t)->Js.Json.stringify
              },
            )
          | false => tokeniseValue(key, value, ~append)
          }
        }
      }

      if queryItems->Js.Array2.length > 0 {
        path := path.contents ++ "?" ++ queryItems->Js.Array2.joinWith("&")
      }
    }
  }

  path.contents
}

let fetch = (
  type variables response,
  route: route<variables, response>,
  baseUrl,
  variables,
  ~fetcher=ApiFetcher.default,
  ~jsonQuery=false,
) => {
  let route = route->(Obj.magic: route<variables, response> => route<unknown, unknown>)
  let variables = variables->(Obj.magic: variables => unknown)

  let {definition, variablesSchema, responsesMap, pathItems, isRawBody} = route->params

  let data = variables->S.reverseConvertOrThrow(variablesSchema)->Obj.magic

  if data["body"] !== %raw(`void 0`) {
    if !isRawBody {
      data["body"] = %raw(`JSON.stringify(data["body"])`)
    }
    if data["headers"] === %raw(`void 0`) {
      data["headers"] = %raw(`{}`)
    }
    data["headers"]["content-type"] = "application/json"
  }

  fetcher({
    body: data["body"],
    headers: data["headers"],
    path: getCompletePath(
      ~baseUrl,
      ~pathItems,
      ~maybeQuery=data["query"],
      ~maybeParams=data["params"],
      ~jsonQuery,
    ),
    method: (definition.method :> string),
  })->Promise.thenResolve(fetcherResponse => {
    switch responsesMap->Response.find(fetcherResponse.status) {
    | None =>
      let error = ref(`Unexpected response status "${fetcherResponse.status->Js.Int.toString}"`)
      if (
        fetcherResponse.data->Obj.magic &&
          Js.typeof((fetcherResponse.data->Obj.magic)["message"]) === "string"
      ) {
        error :=
          error.contents ++ ". Message: " ++ (fetcherResponse.data->Obj.magic)["message"]->Obj.magic
      }

      panic(error.contents)
    | Some(response) =>
      try fetcherResponse
      ->S.parseOrThrow(response.schema)
      ->(Obj.magic: unknown => response) catch {
      | S.Raised({path, code: InvalidType({expected, received})}) if path === S.Path.empty =>
        panic(
          `Failed parsing response data. Reason: Expected ${(
              expected->getSchemaField("data")->Option.unsafeUnwrap
            ).schema->S.name}, received ${(received->Obj.magic)["data"]->Obj.magic}`,
        )
      | S.Raised(error) =>
        panic(
          `Failed parsing response at ${error.path->S.Path.toString}. Reason: ${error->S.Error.reason}`,
        )
      }
    }
  })
}

let client = (~baseUrl, ~fetcher=ApiFetcher.default, ~jsonQuery=false) => {
  let call = (route, variables) => route->fetch(baseUrl, variables, ~fetcher, ~jsonQuery)
  {
    baseUrl,
    fetcher,
    call,
    jsonQuery,
  }
}
