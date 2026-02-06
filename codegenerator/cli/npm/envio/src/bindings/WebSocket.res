/*
Binding to the built-in Node.js WebSocket API (available in Node.js >= 22).
Used for eth_subscribe("newHeads") real-time block tracking.
*/

type t

@new external create: string => t = "WebSocket"

@get external readyState: t => int = "readyState"

// readyState constants
let connecting = 0
let open_ = 1
let closing = 2
let closed = 3

@set external onopen: (t, unit => unit) => unit = "onopen"
@set external onerror: (t, Js.Exn.t => unit) => unit = "onerror"
@set external onclose: (t, unit => unit) => unit = "onclose"

type messageEvent = {data: string}
@set external onmessage: (t, messageEvent => unit) => unit = "onmessage"

@send external send: (t, string) => unit = "send"
@send external close: t => unit = "close"
