/*
Vendored from: https://github.com/DZakh/rescript-rest
Version: 2.0.0-rc.6

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
    redirect: 'value. S.t<'value> => 'value,
  }

  type t<'output> = {
    // When it's empty, treat response as a default
    status: option<int>,
    description: option<string>,
    dataSchema: S.t<unknown>,
    emptyData: bool,
    schema: S.t<'output>,
  }

  type builder<'output> = {
    // When it's empty, treat response as a default
    mutable status?: int,
    mutable description?: string,
    mutable dataSchema?: S.t<unknown>,
    mutable emptyData: bool,
    mutable schema?: S.t<'output>,
  }

  let register = (
    map: dict<t<'output>>,
    status: [< status | #default],
    builder: builder<'output>,
  ) => {
    let key = status->(Obj.magic: [< status | #default] => string)
    if map->Dict.has(key) {
      panic(`Response for the "${key}" status registered multiple times`)
    } else {
      map->Js.Dict.set(key, builder->(Obj.magic: builder<'output> => t<'output>))
    }
  }

  @inline
  let find = (map: dict<t<'output>>, responseStatus: int): option<t<'output>> => {
    (map
    ->Js.Dict.unsafeGet(responseStatus->(Obj.magic: int => string))
    ->(Obj.magic: t<'output> => bool) ||
    map
    ->Js.Dict.unsafeGet((responseStatus / 100)->(Obj.magic: int => string) ++ "XX")
    ->(Obj.magic: t<'output> => bool) ||
    map->Js.Dict.unsafeGet("default")->(Obj.magic: t<'output> => bool))
      ->(Obj.magic: bool => option<t<'output>>)
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

type definition<'input, 'output> = {
  method: method,
  path: string,
  input: s => 'input,
  responses: array<Response.s => 'output>,
  summary?: string,
  description?: string,
  deprecated?: bool,
  operationId?: string,
  tags?: array<string>,
  // By default, all query parameters are encoded as strings, however, you can use the jsonQuery option to encode query parameters as typed JSON values.
  jsonQuery?: bool,
}

type rpc<'input, 'output> = {
  input: S.t<'input>,
  output: S.t<'output>,
  summary?: string,
  description?: string,
  deprecated?: bool,
  operationId?: string,
  tags?: array<string>,
}

type routeParams<'input, 'output> = {
  method: method,
  path: string,
  pathItems: array<pathItem>,
  inputSchema: S.t<'input>,
  outputSchema: S.t<'output>,
  responses: array<Response.t<'output>>,
  responsesMap: dict<Response.t<'output>>,
  isRawBody: bool,
  summary?: string,
  description?: string,
  deprecated?: bool,
  operationId?: string,
  tags?: array<string>,
  jsonQuery?: bool,
}

type route<'input, 'output> = unit => definition<'input, 'output>

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
  switch (route->Obj.magic)["_rest"]->(Obj.magic: unknown => option<routeParams<'input, 'output>>) {
  | Some(params) => params
  | None => {
      let definition = (route->(Obj.magic: route<'input, 'output> => route<unknown, unknown>))()

      let params = if (definition->Obj.magic)["output"] {
        let definition =
          definition->(Obj.magic: definition<unknown, unknown> => rpc<unknown, unknown>)
        let path =
          `/` ++
          switch definition.operationId {
          | Some(p) => p
          | None => (route->Obj.magic)["name"]
          }
        let inputSchema = S.object(s => s.field("body", definition.input))
        inputSchema->stripInPlace
        inputSchema->removeTypeValidationInPlace
        let outputSchema = S.object(s => s.field("data", definition.output))
        outputSchema->stripInPlace
        outputSchema->removeTypeValidationInPlace
        let response: Response.t<unknown> = {
          status: Some(200),
          description: None,
          dataSchema: definition.input,
          emptyData: false,
          schema: outputSchema,
        }
        let responsesMap = Js.Dict.empty()
        responsesMap->Js.Dict.set("200", response)
        {
          method: Post,
          path,
          inputSchema,
          outputSchema,
          responses: [response],
          responsesMap,
          pathItems: [Static(path)],
          isRawBody: false,
          summary: ?definition.summary,
          description: ?definition.description,
          deprecated: ?definition.deprecated,
          operationId: ?definition.operationId,
          tags: ?definition.tags,
        }
      } else {
        let pathItems = []
        let pathParams = Js.Dict.empty()
        parsePath(definition.path, ~pathItems, ~pathParams)

        // Don't use ref, since it creates an unnecessary object
        let isRawBody = %raw(`false`)

        let inputSchema = S.object(s => {
          definition.input({
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
          // The input input is guaranteed to be an object, so we reset the rescript-schema type filter here
          inputSchema->stripInPlace
          inputSchema->removeTypeValidationInPlace
          switch inputSchema->getSchemaField("headers") {
          | Some({schema}) =>
            schema->stripInPlace
            schema->removeTypeValidationInPlace
          | None => ()
          }
          switch inputSchema->getSchemaField("params") {
          | Some({schema}) => schema->removeTypeValidationInPlace
          | None => ()
          }
          switch inputSchema->getSchemaField("query") {
          | Some({schema}) => schema->removeTypeValidationInPlace
          | None => ()
          }
        }

        let responsesMap = Js.Dict.empty()
        let responses = []
        definition.responses->Js.Array2.forEach(r => {
          let builder: Response.builder<unknown> = {
            emptyData: true,
          }
          let schema = S.object(s => {
            let status = status => {
              builder.status = Some(status)
              let status = status->(Obj.magic: int => Response.status)
              responsesMap->Response.register(status, builder)
              s.tag("status", status)
            }
            let header = (fieldName, schema) => {
              s.nested("headers").field(fieldName->Js.String2.toLowerCase, coerceSchema(schema))
            }
            let definition = r({
              status,
              redirect: schema => {
                status(307)
                header("location", coerceSchema(schema))
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
              header,
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

        {
          method: definition.method,
          path: definition.path,
          inputSchema,
          outputSchema: S.union(responses->Js.Array2.map(r => r.schema)),
          responses,
          pathItems,
          responsesMap,
          isRawBody,
          summary: ?definition.summary,
          description: ?definition.description,
          deprecated: ?definition.deprecated,
          operationId: ?definition.operationId,
          tags: ?definition.tags,
          jsonQuery: ?definition.jsonQuery,
        }
      }

      (route->Obj.magic)["_rest"] = params
      params->(Obj.magic: routeParams<unknown, unknown> => routeParams<'input, 'output>)
    }
  }
}

external route: (unit => definition<'input, 'output>) => route<'input, 'output> = "%identity"
external rpc: (unit => rpc<'input, 'output>) => route<'input, 'output> = "%identity"

type client = {
  baseUrl: string,
  fetcher: ApiFetcher.t,
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
let getCompletePath = (~baseUrl, ~pathItems, ~maybeQuery, ~maybeParams, ~jsonQuery=false) => {
  let path = ref(baseUrl)

  for idx in 0 to pathItems->Js.Array2.length - 1 {
    let pathItem = pathItems->Js.Array2.unsafe_get(idx)
    switch pathItem {
    | Static(static) => path := path.contents ++ static
    | Param({name}) =>
      switch (maybeParams->Obj.magic && maybeParams->Js.Dict.unsafeGet(name)->Obj.magic)
        ->(Obj.magic: bool => option<string>) {
      | Some(param) => path := path.contents ++ param
      | None => panic(`Path parameter "${name}" is not defined in input`)
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

let url = (route, input, ~baseUrl="") => {
  let {pathItems, inputSchema} = route->params
  let data = input->S.reverseConvertOrThrow(inputSchema)->Obj.magic
  getCompletePath(
    ~baseUrl,
    ~pathItems,
    ~maybeQuery=data["query"],
    ~maybeParams=data["params"],
    ~jsonQuery=false,
  )
}

type global = {
  @as("c")
  mutable client: option<client>,
}

let global = {
  client: None,
}

let fetch = (type input response, route: route<input, response>, input, ~client=?) => {
  let route = route->(Obj.magic: route<input, response> => route<unknown, unknown>)
  let input = input->(Obj.magic: input => unknown)

  let {path, method, ?jsonQuery, inputSchema, responsesMap, pathItems, isRawBody} = route->params

  let client = switch client {
  | Some(client) => client
  | None =>
    switch global.client {
    | Some(client) => client
    | None =>
      panic(
        `Client is not set for the ${path} fetch request. Please, use Rest.setGlobalClient or pass a client explicitly to the Rest.fetch arguments`,
      )
    }
  }

  let data = input->S.reverseConvertOrThrow(inputSchema)->Obj.magic

  if data["body"] !== %raw(`void 0`) {
    if !isRawBody {
      data["body"] = %raw(`JSON.stringify(data["body"])`)
    }
    if data["headers"] === %raw(`void 0`) {
      data["headers"] = %raw(`{}`)
    }
    data["headers"]["content-type"] = "application/json"
  }

  client.fetcher({
    body: data["body"],
    headers: data["headers"],
    path: getCompletePath(
      ~baseUrl=client.baseUrl,
      ~pathItems,
      ~maybeQuery=data["query"],
      ~maybeParams=data["params"],
      ~jsonQuery?,
    ),
    method: (method :> string),
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

let client = (baseUrl, ~fetcher=ApiFetcher.default) => {
  {
    baseUrl,
    fetcher,
  }
}

let setGlobalClient = (baseUrl, ~fetcher=?) => {
  switch global.client {
  | Some(_) =>
    panic("There's already a global client defined. You can have only one global client at a time.")
  | None => global.client = Some(client(baseUrl, ~fetcher?))
  }
}
