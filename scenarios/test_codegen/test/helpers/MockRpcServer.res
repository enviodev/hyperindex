// A real local JSON-RPC server. eth_getLogs runs through the Rust client's own
// HTTP stack, which a globalThis.fetch stub can't intercept — tests point the
// source/client at one of these instead.
//
// Prefer `withScenario` for behavior/contract tests. It accepts the expected
// calls inline, verifies that all of them were consumed, rejects unexpected
// calls, and always waits for the server to close. The lower-level `start`,
// `makeRaw`, `makeWithParams`, and `make` helpers remain for tests that need a
// fully dynamic response function.
type server
type req
type res

@module("node:http")
external createServer: ((req, res) => unit) => server = "createServer"
@send external listenOnHost: (server, int, string, unit => unit) => unit = "listen"
@send external onceServerError: (server, @as("error") _, exn => unit) => unit = "once"
@send external closeAllConnections: server => unit = "closeAllConnections"
@send external close: (server, unit => unit) => unit = "close"

type address = {port: int}
@send external address: server => address = "address"

@send external setEncoding: (req, string) => unit = "setEncoding"
@send external onData: (req, @as("data") _, string => unit) => unit = "on"
@send external onEnd: (req, @as("end") _, unit => unit) => unit = "on"
@get external reqMethod: req => string = "method"
@get external reqUrl: req => string = "url"
// Node's IncomingHttpHeaders values are `string | string[]` (duplicated headers
// arrive as arrays); model both and expose a single-value accessor below.
@unboxed type headerValue = Single(string) | Multiple(array<string>)
@get external reqHeaders: req => dict<headerValue> = "headers"

@send external writeHead: (res, int, dict<string>) => unit = "writeHead"
@send external end_: (res, string) => unit = "end"
@send external destroy: res => unit = "destroy"

@module("node:util")
external isDeepStrictEqual: (JSON.t, JSON.t) => bool = "isDeepStrictEqual"

type rpcRequest = {
  sequence: int,
  httpMethod: string,
  url: string,
  method: string,
  params: JSON.t,
  id: JSON.t,
  jsonrpc: string,
  headers: dict<headerValue>,
  rawBody: string,
}

type rec reply =
  | RpcResult(JSON.t)
  | RpcError({code: int, message: string, data?: JSON.t})
  | RawHttp({status: int, headers?: dict<string>, body: string})
  | Delayed({millis: int, reply: reply})
  | Disconnect
  | NoResponse
  // Escape hatch for responses that genuinely depend on the parsed request.
  // Serializable pin tests should normally use the concrete variants above.
  | Dynamic(rpcRequest => reply)

type expectedCall = {
  label: string,
  method: string,
  params: option<JSON.t>,
  headers: option<dict<string>>,
  reply: reply,
  times: int,
  // Only expectations in the lowest unfinished phase may match. Calls within
  // one phase are unordered, which keeps concurrent fan-out tests stable.
  phase: int,
}

type expectationState = {
  call: expectedCall,
  mutable remaining: int,
}

type transcriptEntry = {
  request: rpcRequest,
  matchedLabel: option<string>,
}

type verification = {
  failures: array<string>,
  pending: array<string>,
}

type t = {
  url: string,
  // Kept for compatibility and ad-hoc inspection. Scenario tests should use
  // `transcript`, whose entries are already parsed and matched.
  requests: array<string>,
  requestHeaders: array<dict<headerValue>>,
  transcript: unit => array<transcriptEntry>,
  verify: unit => verification,
  verifyOrThrow: unit => unit,
  // Synchronous compatibility close. `withScenario` uses `closeAsync`.
  close: unit => unit,
  closeAsync: unit => promise<unit>,
}

// Read a single-valued request header (first value if it was repeated).
let getHeader = (headers: dict<headerValue>, name: string): option<string> =>
  switch headers->Dict.get(name->String.toLowerCase) {
  | Some(Single(value)) => Some(value)
  | Some(Multiple(values)) => values->Array.get(0)
  | None => None
  }

let expectCall = (
  ~label=?,
  ~method,
  ~params=?,
  ~headers=?,
  ~reply,
  ~times=1,
  ~phase=0,
) => {
  label: label->Option.getOr(method),
  method,
  params,
  headers,
  reply,
  times,
  phase,
}

let parseRequest = (~sequence, ~req, ~rawBody): result<rpcRequest, string> => {
  if req->reqMethod != "POST" {
    Error(`Expected HTTP POST, received ${req->reqMethod}`)
  } else {
    try {
      switch rawBody->JSON.parseOrThrow->JSON.Decode.object {
      | None => Error("Expected a JSON-RPC object request")
      | Some(obj) =>
        switch (
          obj->Dict.get("method")->Option.flatMap(JSON.Decode.string),
          obj->Dict.get("params"),
          obj->Dict.get("id"),
          obj->Dict.get("jsonrpc")->Option.flatMap(JSON.Decode.string),
        ) {
        | (Some(method), Some(params), Some(id), Some("2.0")) =>
          Ok({
            sequence,
            httpMethod: req->reqMethod,
            url: req->reqUrl,
            method,
            params,
            id,
            jsonrpc: "2.0",
            headers: req->reqHeaders,
            rawBody,
          })
        | (_, _, _, Some(version)) => Error(`Expected jsonrpc "2.0", received "${version}"`)
        | _ => Error("JSON-RPC request must contain method, params, id, and jsonrpc")
        }
      }
    } catch {
    | exn =>
      Error(
        `Invalid JSON-RPC request body: ${exn
          ->Utils.prettifyExn
          ->(Utils.magic: exn => string)}`,
      )
    }
  }
}

let matchesCall = (call: expectedCall, request: rpcRequest) => {
  let paramsMatch = switch call.params {
  | None => true
  | Some(expected) => isDeepStrictEqual(expected, request.params)
  }
  let headersMatch = switch call.headers {
  | None => true
  | Some(expected) => {
      let matches = ref(true)
      expected->Utils.Dict.forEachWithKey((value, name) => {
        if request.headers->getHeader(name) != Some(value) {
          matches := false
        }
      })
      matches.contents
    }
  }
  call.method == request.method && paramsMatch && headersMatch
}

let addHeaders = (~base: dict<string>, extra: option<dict<string>>) => {
  switch extra {
  | None => ()
  | Some(headers) => headers->Utils.Dict.forEachWithKey((value, name) => base->Dict.set(name, value))
  }
  base
}

let writeRaw = (res, ~status, ~headers=?, ~body) => {
  let responseHeaders = addHeaders(
    ~base=Dict.fromArray([("Content-Type", "application/json")]),
    headers,
  )
  res->writeHead(status, responseHeaders)
  res->end_(body)
}

let writeEnvelope = (res, ~id, ~fieldName, ~value) => {
  res->writeRaw(
    ~status=200,
    ~body=JSON.stringify(
      JSON.Object(
        Dict.fromArray([
          ("jsonrpc", JSON.String("2.0")),
          ("id", id),
          (fieldName, value),
        ]),
      ),
    ),
  )
}

let rec sendReply = (res, request, reply, ~onTimer) =>
  switch reply {
  | RpcResult(result) => res->writeEnvelope(~id=request.id, ~fieldName="result", ~value=result)
  | RpcError({code, message, ?data}) => {
      let error = Dict.fromArray([
        ("code", JSON.Number(code->Int.toFloat)),
        ("message", JSON.String(message)),
      ])
      switch data {
      | Some(value) => error->Dict.set("data", value)
      | None => ()
      }
      res->writeEnvelope(~id=request.id, ~fieldName="error", ~value=JSON.Object(error))
    }
  | RawHttp({status, ?headers, body}) => res->writeRaw(~status, ~headers?, ~body)
  | Delayed({millis, reply}) => {
      let id = setTimeout(() => sendReply(res, request, reply, ~onTimer), millis)
      onTimer(id)
    }
  | Disconnect => res->destroy
  | NoResponse => ()
  | Dynamic(makeReply) => sendReply(res, request, makeReply(request), ~onTimer)
  }

let makeVerification = (states, failures): verification => {
  let pending = []
  states->Array.forEach(({call, remaining}) => {
    if remaining > 0 {
      pending
      ->Array.push(
        remaining == 1 ? call.label : `${call.label} (${remaining->Int.toString} remaining)`,
      )
      ->ignore
    }
  })
  {failures: failures->Utils.Array.copy, pending}
}

let verificationMessage = (~name, {failures, pending}: verification) => {
  let sections = [`RPC scenario "${name}" failed`]
  if failures->Utils.Array.isEmpty->not {
    sections->Array.push("Failures:\n" ++ failures->Array.joinUnsafe("\n"))->ignore
  }
  if pending->Utils.Array.isEmpty->not {
    sections
    ->Array.push("Unconsumed expectations:\n  - " ++ pending->Array.joinUnsafe("\n  - "))
    ->ignore
  }
  sections->Array.joinUnsafe("\n\n")
}

let startInternal = (~name, ~calls: array<expectedCall>, ~legacyHandler=?) =>
  Promise.make((resolve, reject) => {
    let requests = []
    let requestHeaders = []
    let transcript = []
    let failures = []
    let sequence = ref(0)
    let closed = ref(false)
    let pendingTimers = []
    let states = calls->Array.map(call => {
      if call.times <= 0 {
        JsError.throwWithMessage(`RPC expectation "${call.label}" must have times > 0`)
      }
      {call, remaining: call.times}
    })

    let server = createServer((req, res) => {
      req->setEncoding("utf8")
      let data = ref("")
      req->onData(chunk => data := data.contents ++ chunk)
      req->onEnd(() => {
        sequence := sequence.contents + 1
        requests->Array.push(data.contents)->ignore
        requestHeaders->Array.push(req->reqHeaders)->ignore

        switch legacyHandler {
        | Some(handler) => {
            let (status, body) = handler(data.contents)
            res->writeRaw(~status, ~body)
          }
        | None =>
          switch parseRequest(~sequence=sequence.contents, ~req, ~rawBody=data.contents) {
          | Error(message) => {
              failures->Array.push(`Request #${sequence.contents->Int.toString}: ${message}`)->ignore
              res->writeRaw(~status=400, ~body=JSON.stringify(JSON.String(message)))
            }
          | Ok(request) => {
              let activePhase = states->Array.reduce(2147483647, (phase, state) =>
                state.remaining > 0 ? Pervasives.min(phase, state.call.phase) : phase
              )
              let matched = states->Array.find(state =>
                state.remaining > 0 &&
                state.call.phase == activePhase &&
                state.call->matchesCall(request)
              )
              switch matched {
              | Some(state) => {
                  state.remaining = state.remaining - 1
                  transcript->Array.push({request, matchedLabel: Some(state.call.label)})->ignore
                  sendReply(
                    res,
                    request,
                    state.call.reply,
                    ~onTimer=id => pendingTimers->Array.push(id)->ignore,
                  )
                }
              | None => {
                  transcript->Array.push({request, matchedLabel: None})->ignore
                  let pendingInPhase = states
                  ->Array.filter(state => state.remaining > 0 && state.call.phase == activePhase)
                  ->Array.map(state => state.call.label)
                  let detail = `Unexpected request #${request.sequence->Int.toString}: ${request.method}(${request.params->JSON.stringify}). Active expectations: ${pendingInPhase->Array.joinUnsafe(", ")}`
                  failures->Array.push(detail)->ignore
                  res->writeRaw(
                    ~status=500,
                    ~body=JSON.stringify(JSON.Object(Dict.fromArray([("error", JSON.String(detail))]))),
                  )
                }
              }
            }
          }
        }
      })
    })
    server->onceServerError(reject)
    server->listenOnHost(0, "127.0.0.1", () => {
      let closeAsync = () =>
        Promise.make((resolveClose, _rejectClose) => {
          if closed.contents {
            resolveClose()
          } else {
            closed := true
            pendingTimers->Array.forEach(clearTimeout)
            pendingTimers->Utils.Array.clearInPlace
            server->closeAllConnections
            server->close(resolveClose)
          }
        })
      let verify = () => makeVerification(states, failures)
      let verifyOrThrow = () => {
        let verification = verify()
        if verification.failures->Utils.Array.isEmpty->not ||
          verification.pending->Utils.Array.isEmpty->not {
          JsError.throwWithMessage(verification->verificationMessage(~name))
        }
      }
      resolve({
        url: `http://127.0.0.1:${(server->address).port->Int.toString}`,
        requests,
        requestHeaders,
        transcript: () => transcript->Utils.Array.copy,
        verify,
        verifyOrThrow,
        close: () => closeAsync()->ignore,
        closeAsync,
      })
    })
  })

let startScenario = (~name="unnamed", ~calls) => startInternal(~name, ~calls)

let withScenario = async (~name="unnamed", ~calls, testFn) => {
  let mock = await startScenario(~name, ~calls)
  try {
    let result = await testFn(mock)
    mock.verifyOrThrow()
    await mock.closeAsync()
    result
  } catch {
  | exn =>
    await mock.closeAsync()
    throw(exn)
  }
}

// Low-level dynamic server retained for cases whose reply cannot reasonably be
// expressed as a finite inline scenario.
let start = (~handler: string => (int, string)) =>
  startInternal(~name="legacy dynamic handler", ~calls=[], ~legacyHandler=handler)

// Reply with a fixed status and body to every request.
let makeRaw = (~status, ~body) => start(~handler=_ => (status, body))

// Reply 200 with a JSON-RPC envelope whose `result` is routed by the request's
// `method` and `params`, echoing the request's `id` back.
let makeWithParams = (~getResult: (~method: string, ~params: JSON.t) => JSON.t) =>
  start(~handler=requestBody => {
    let parsed = requestBody->JSON.parseOrThrow->JSON.Decode.object
    let method =
      parsed
      ->Option.flatMap(Dict.get(_, "method"))
      ->Option.flatMap(JSON.Decode.string)
      ->Option.getOr("")
    let params = parsed->Option.flatMap(Dict.get(_, "params"))->Option.getOr(JSON.Null)
    let id = parsed->Option.flatMap(Dict.get(_, "id"))->Option.getOr(JSON.Number(1.))
    (
      200,
      JSON.stringify(
        JSON.Object(
          Dict.fromArray([
            ("jsonrpc", JSON.String("2.0")),
            ("id", id),
            ("result", getResult(~method, ~params)),
          ]),
        ),
      ),
    )
  })

// Reply 200 with a JSON-RPC envelope whose `result` is routed by the request's
// `method`, echoing the request's `id` back.
let make = (~getResult: string => JSON.t) =>
  makeWithParams(~getResult=(~method, ~params as _) => getResult(method))
