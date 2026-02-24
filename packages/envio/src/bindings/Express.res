// Inspired by https://github.com/bloodyowl/rescript-express

type app

// "default" &  seem to conflict a bit right now
// https://github.com/rescript-lang/rescript-compiler/issues/5004
@module external makeCjs: unit => app = "express"
@module("express") external make: unit => app = "default"

type req = private {
  headers: dict<string>,
  method: Rest.method,
  query: dict<string>,
}
type res

type handler = (req, res) => unit
type middleware = (req, res, unit => unit) => unit

@module("express") external jsonMiddleware: unit => middleware = "json"

@send external use: (app, middleware) => unit = "use"
@send external useFor: (app, string, middleware) => unit = "use"

@send external get: (app, string, handler) => unit = "get"
@send external post: (app, string, handler) => unit = "post"

type server

@send external listen: (app, int) => server = "listen"

// res methods
@send external sendStatus: (res, int) => unit = "sendStatus"
@send external set: (res, string, string) => unit = "set"
@send external json: (res, Js.Json.t) => unit = "json"
@send external endWithData: (res, 'a) => res = "end"
@send external setHeader: (res, string, string) => unit = "setHeader"
