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

  let raiseAny = (any: 'any): 'a =>
    any
    ->Obj.magic
    ->throw

  // Check if dataSchema is a literal (has a const value)

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
    dict->Dict.getUnsafe(key)->(Obj.magic: 'a => bool)
  }
  let set = Dict.set
  let getUnsafe = Dict.getUnsafe
  let make = Dict.make
  let keysToArray = Dict.keysToArray
}

let panic = (message, ~params: option<{..}>=?) => {
  let error = Exn.makeError(`[rescript-rest] ${message}`)
  switch params {
  | Some(params) => (error->Obj.magic)["params"] = params
  | None => ()
  }
  Exn.raiseError(error)
}

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
      contentType->String.includes("application/") &&
      contentType->String.includes("json")
    ) {
      {
        status: result["status"],
        data: await result["json"](),
        headers: result["headers"],
      }
    } else if contentType->Obj.magic && contentType->String.includes("text/") {
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
      map->Dict.set(key, builder->(Obj.magic: builder<'output> => t<'output>))
    }
  }

  @inline
  let find = (map: dict<t<'output>>, responseStatus: int): option<t<'output>> => {
    (map
    ->Dict.getUnsafe(responseStatus->(Obj.magic: int => string))
    ->(Obj.magic: t<'output> => bool) ||
    map
    ->Dict.getUnsafe((responseStatus / 100)->(Obj.magic: int => string) ++ "XX")
    ->(Obj.magic: t<'output> => bool) ||
    map->Dict.getUnsafe("default")->(Obj.magic: t<'output> => bool))
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
    switch path->String.indexOf("{") {
    | -1 => pathItems->Array.push(Static(path))->ignore
    | paramStartIdx =>
      switch path->String.indexOf("}") {
      | -1 => panic("Path contains an unclosed parameter")
      | paramEndIdx =>
        if paramStartIdx > paramEndIdx {
          panic("Path parameter is not enclosed in curly braces")
        }
        let paramName = String.slice(path, ~start=paramStartIdx + 1, ~end=paramEndIdx)
        if paramName === "" {
          panic("Path parameter name cannot be empty")
        }
        let param = {name: paramName}

        pathItems
        ->Array.push(Static(String.slice(path, ~start=0, ~end=paramStartIdx)))
        ->ignore
        pathItems->Array.push(Param(param))->ignore
        pathParams->Dict.set(paramName, param)->ignore

        parsePath(String.slice(path, ~start=paramEndIdx + 1), ~pathItems, ~pathParams)
      }
    }
  }
}

let coerceSchema = schema => {
  // Determine the inner type tag, unwrapping Option/Null wrappers (Union with Null/Undefined member)
  let tag = (schema->S.untag).tag
  let innerTag = if tag == Union {
    let anyOf: array<S.t<unknown>> = (schema->S.untag->(Obj.magic: S.untagged => {..}))["anyOf"]
    let inner = anyOf->Array.find(s => {
      let t = (s->S.untag).tag
      t != Null && t != Undefined
    })
    switch inner {
    | Some(s) => (s->S.untag).tag
    | None => tag
    }
  } else {
    tag
  }
  switch innerTag {
  | Boolean =>
    S.unknown
    ->S.transform(_ => {
      parser: unknown =>
        switch unknown->Obj.magic {
        | "true" => true->Obj.magic
        | "false" => false->Obj.magic
        | _ => unknown
        },
    })
    ->S.to(schema->Obj.magic)
  | Number =>
    S.unknown
    ->S.transform(_ => {
      parser: unknown => {
        let float = %raw(`+unknown`)
        if Float.isNaN(float) {
          unknown
        } else {
          float->Obj.magic
        }
      },
    })
    ->S.to(schema->Obj.magic)
  | _ => schema
  }
}

let stripInPlace = schema => (schema->S.untag->Obj.magic)["additionalItems"] = "strip"
let getSchemaField = (schema, fieldName): option<S.item> => {
  let s = (schema->S.untag->Obj.magic)["properties"]->Dict.getUnsafe(fieldName)
  if s->Obj.magic {
    Some(({schema: s, location: fieldName}: S.item))
  } else {
    None
  }
}

type typeValidation = (unknown, ~inputVar: string) => string
let removeTypeValidationInPlace = schema => (schema->Obj.magic)["f"] = ()
let setTypeValidationInPlace = (schema, typeValidation: typeValidation) =>
  (schema->Obj.magic)["f"] = typeValidation
let unsafeGetTypeValidationInPlace = (schema): typeValidation => (schema->Obj.magic)["f"]

let isNestedFlattenSupported = schema =>
  switch schema->(Obj.magic: S.t<'a> => S.t<unknown>) {
  | Object(_) =>
    switch schema->S.reverse {
    | Object(_) => true
    | _ => false
    }
  | _ => false
  }

let bearerAuthSchema = S.string->S.transform(s => {
  serializer: token => {
    `Bearer ${token}`
  },
  parser: string => {
    switch string->String.split(" ") {
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
    switch string->String.split(" ") {
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
        let responsesMap = Dict.make()
        responsesMap->Dict.set("200", response)
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
        let pathParams = Dict.make()
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
              let isNonStringBased = (schema->S.untag).tag != String
              if isNonStringBased {
                panic("Only string-based schemas are allowed in rawBody")
              }
              let _ = %raw(`isRawBody = true`)
              s.field("body", schema)
            },
            header: (fieldName, schema) => {
              s.nested("headers").field(fieldName->String.toLowerCase, coerceSchema(schema))
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

        let responsesMap = Dict.make()
        let responses = []
        definition.responses->Array.forEach(r => {
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
              s.nested("headers").field(fieldName->String.toLowerCase, coerceSchema(schema))
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

          if (dataSchema->S.untag->Obj.magic)["const"] !== %raw(`void 0`) {
            let dataTypeValidation = dataSchema->unsafeGetTypeValidationInPlace
            schema->setTypeValidationInPlace((b, ~inputVar) =>
              dataTypeValidation(b, ~inputVar=`${inputVar}.data`)
            )
          }
          switch schema->getSchemaField("headers") {
          | Some({schema}) =>
            schema->stripInPlace
            schema->removeTypeValidationInPlace
          | None => ()
          }
          builder.schema = Option.unsafeSome(schema)
          responses
          ->Array.push(builder->(Obj.magic: Response.builder<unknown> => Response.t<unknown>))
          ->ignore
        })

        if responses->Array.length === 0 {
          panic("At least single response should be registered")
        }

        {
          method: definition.method,
          path: definition.path,
          inputSchema,
          outputSchema: S.union(responses->Array.map(r => r.schema)),
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
  if Array.isArray(value) {
    value
    ->(Obj.magic: unknown => array<unknown>)
    ->Array.forEachWithIndex((v, idx) => {
      tokeniseValue(`${key}[${idx->Int.toString}]`, v, ~append)
    })
  } else if value === %raw(`null`) {
    append(key, "")
  } else if value === %raw(`void 0`) {
    ()
  } else if Js.typeof(value) === "object" {
    let dict = value->(Obj.magic: unknown => dict<unknown>)
    dict
    ->Dict.keysToArray
    ->Array.forEach(k => {
      tokeniseValue(`${key}[${encodeURIComponent(k)}]`, dict->Dict.getUnsafe(k), ~append)
    })
  } else {
    append(key, value->(Obj.magic: unknown => string))
  }
}

// Inspired by https://github.com/ts-rest/ts-rest/blob/7792ef7bdc352e84a4f5766c53f984a9d630c60e/libs/ts-rest/core/src/lib/client.ts#L347
let getCompletePath = (~baseUrl, ~pathItems, ~maybeQuery, ~maybeParams, ~jsonQuery=false) => {
  let path = ref(baseUrl)

  for idx in 0 to pathItems->Array.length - 1 {
    let pathItem = pathItems->Array.getUnsafe(idx)
    switch pathItem {
    | Static(static) => path := path.contents ++ static
    | Param({name}) =>
      switch (maybeParams->Obj.magic && maybeParams->Dict.getUnsafe(name)->Obj.magic)
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
        let _ = queryItems->Array.push(key ++ "=" ++ encodeURIComponent(value))
      }

      let queryNames = query->Dict.keysToArray
      for idx in 0 to queryNames->Array.length - 1 {
        let queryName = queryNames->Array.getUnsafe(idx)
        let value = query->Dict.getUnsafe(queryName)
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
                    Float.isNaN(Float.parseFloat(value))
                  }
              ) {
                value->(Obj.magic: unknown => string)
              } else {
                value->(Obj.magic: unknown => JSON.t)->JSON.stringify
              },
            )
          | false => tokeniseValue(key, value, ~append)
          }
        }
      }

      if queryItems->Array.length > 0 {
        path := path.contents ++ "?" ++ queryItems->Array.joinUnsafe("&")
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
  })->Promise_.thenResolve(fetcherResponse => {
    switch responsesMap->Response.find(fetcherResponse.status) {
    | None =>
      let error = ref(`Unexpected response status "${fetcherResponse.status->Int.toString}"`)
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
      | S.Error({path, code: InvalidType({expected, received})}) if path === S.Path.empty =>
        panic(
          `Failed parsing response data. Reason: Expected ${(
              expected->getSchemaField("data")->Option.unsafeUnwrap
            ).schema->S.toExpression}, received ${(received->Obj.magic)["data"]->Obj.magic}`,
        )
      | S.Error(error) =>
        panic(
          `Failed parsing response at ${error.path->S.Path.toString}. Reason: ${error.reason}`,
          ~params={
            "response": fetcherResponse,
          },
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
