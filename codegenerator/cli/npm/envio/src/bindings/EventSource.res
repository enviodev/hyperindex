type t

type options = {headers?: dict<string>}

@module("eventsource") @new
external create: (~url: string, ~options: options=?) => t = "EventSource"

@set external onopen: (t, unit => unit) => unit = "onopen"
@set external onerror: (t, JsExn.t => unit) => unit = "onerror"

type event = {data: string}
@send external addEventListener: (t, string, event => unit) => unit = "addEventListener"
@send external close: t => unit = "close"
