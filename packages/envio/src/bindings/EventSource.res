type t

module Fetch = {
  type args = {body?: unknown, headers?: dict<string>, method?: string, path?: string}
  type t = (string, ~args: args) => promise<unknown>
  // NOTE: don't try make the type t. Rescript 11 will curry the args which breaks
  // keet the type inline. This is a workaround for now.
  external fetch: (string, ~args: args) => promise<unknown> = "fetch"
}
type options = {fetch?: Fetch.t}

@module("eventsource") @new
external create: (~url: string, ~options: options=?) => t = "EventSource"

@set external onopen: (t, unit => unit) => unit = "onopen"
@set external onerror: (t, Js.Exn.t => unit) => unit = "onerror"

type event = {data: string}
@send external addEventListener: (t, string, event => unit) => unit = "addEventListener"
@send external close: t => unit = "close"
