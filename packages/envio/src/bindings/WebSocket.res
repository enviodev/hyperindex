/*
Binding to the built-in Node.js WebSocket API (available in Node.js >= 22).
Used for eth_subscribe("newHeads") real-time block tracking.
*/

type t

@new external create: string => t = "WebSocket"

@set external onopen: (t, unit => unit) => unit = "onopen"
@set external onerror: (t, JsExn.t => unit) => unit = "onerror"
@set external onclose: (t, unit => unit) => unit = "onclose"

// Node delivers a string for a text frame and a Blob for a binary one, so what
// arrives is only text when the peer sent text. Typed as a string it would reach
// a JSON parse — and, once that threw, a log line — as an object, past every
// length cap written for a string.
type messageEvent = {data: unknown}
@set external onmessage: (t, messageEvent => unit) => unit = "onmessage"

// Nothing in here may be a runtime value. `create` compiles to `new WebSocket`
// against the global, and a value would make consumers import this module under
// that same name, shadowing the global they are trying to construct.

@send external send: (t, string) => unit = "send"
@send external close: t => unit = "close"
