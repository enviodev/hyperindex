/*
Vendored from: https://github.com/DZakh/rescript-rest
Version: 1.0.1

IF EDITING THIS FILE, PLEASE LIST THE CHANGES BELOW

here

 */

@@uncurried

module ApiFetcher: {
  type args = {body: option<unknown>, headers: option<dict<unknown>>, method: string, path: string}
  type response = {data: unknown, status: int, headers: dict<unknown>}
  type t = args => promise<response>

  // Inspired by https://github.com/ts-rest/ts-rest/blob/7792ef7bdc352e84a4f5766c53f984a9d630c60e/libs/ts-rest/core/src/lib/client.ts#L102
  /**
  * Default fetch api implementation:
  *
  * Can be used as a reference for implementing your own fetcher,
  * or used in the "api" field of ClientArgs to allow you to hook
  * into the request to run custom logic
  */
  let default: t
}

module Response: {
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

  type t<'response> = {
    // When it's empty, treat response as a default
    status: option<int>,
    description: option<string>,
    dataSchema: S.t<unknown>,
    emptyData: bool,
    schema: S.t<'response>,
  }

  type s = {
    status: int => unit,
    description: string => unit,
    data: 'value. S.t<'value> => 'value,
    field: 'value. (string, S.t<'value>) => 'value,
    header: 'value. (string, S.t<'value>) => 'value,
  }
}

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

type route<'variables, 'response>

type pathParam = {name: string}
@unboxed
type pathItem = Static(string) | Param(pathParam)

type routeParams<'variables, 'response> = {
  definition: definition<'variables, 'response>,
  pathItems: array<pathItem>,
  variablesSchema: S.t<'variables>,
  responses: array<Response.t<'response>>,
  responsesMap: dict<Response.t<'response>>,
  isRawBody: bool,
}

let params: route<'variables, 'response> => routeParams<'variables, 'response>

external route: (unit => definition<'variables, 'response>) => route<'variables, 'response> =
  "%identity"

type client = {
  call: 'variables 'response. (route<'variables, 'response>, 'variables) => promise<'response>,
  baseUrl: string,
  fetcher: ApiFetcher.t,
  jsonQuery: bool,
}

let client: (~baseUrl: string, ~fetcher: ApiFetcher.t=?, ~jsonQuery: bool=?) => client

let fetch: (
  route<'variables, 'response>,
  string,
  'variables,
  ~fetcher: ApiFetcher.t=?,
  ~jsonQuery: bool=?,
) => promise<'response>
