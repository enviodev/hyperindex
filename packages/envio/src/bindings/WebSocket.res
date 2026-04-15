/*
Binding to the built-in Node.js WebSocket API (available in Node.js >= 22).
Used for eth_subscribe("newHeads") real-time block tracking.
*/

type t

@new external create: string => t = "WebSocket"

@unboxed
type readyState =
  | @as(0) Connecting
  | @as(1) Open
  | @as(2) Closing
  | @as(3) Closed

@get external readyState: t => readyState = "readyState"

@set external onopen: (t, unit => unit) => unit = "onopen"
@set external onerror: (t, JsExn.t => unit) => unit = "onerror"
@set external onclose: (t, unit => unit) => unit = "onclose"

type messageEvent = {data: string}
@set external onmessage: (t, messageEvent => unit) => unit = "onmessage"

@send external send: (t, string) => unit = "send"
@send external close: t => unit = "close"
