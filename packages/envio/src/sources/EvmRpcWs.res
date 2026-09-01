// newHeads carries no keep-alive, so this has to tolerate slow chains rather
// than the seconds an SSE ping allows.
let staleTimeout = 60_000

// The id of the one request this stream ever sends, which is what tells a
// response meant for it apart from one about anything else sharing the socket.
let subscribeRequestId = 1
let subscribeRequestIdText = subscribeRequestId->Int.toString

let isText: unknown => bool = %raw(`(data) => typeof data === "string"`)

// A JSON-RPC id is any scalar, and gateways do echo an int id back as a string.
// Both spellings name the same request, so both have to be read.
type responseId = IntId(int) | StringId(string)

type wsMessage =
  | NewHead(int)
  // A response to some request, carrying the id it answers when it names one.
  | Response({id: option<responseId>, isError: bool})

let subscribeRequestJson =
  {"jsonrpc": "2.0", "id": subscribeRequestId, "method": "eth_subscribe", "params": ["newHeads"]}
  ->(Utils.magic: {
    "jsonrpc": string,
    "id": int,
    "method": string,
    "params": array<string>,
  } => JSON.t)
  ->JSON.stringify

// Nullable, not merely optional: JSON-RPC answers a request whose id it could
// not read with an explicit null.
let responseIdSchema = S.nullable(
  S.union([S.int->S.shape(id => IntId(id)), S.string->S.shape(id => StringId(id))]),
)

let namesSubscribe = id =>
  switch id {
  | IntId(id) => id === subscribeRequestId
  | StringId(id) => id === subscribeRequestIdText
  }

// The subscribe is the only request this socket ever sends, so an error naming
// its id — or naming none at all, which is how JSON-RPC answers a request it
// could not parse — is that subscription being refused.
let refusesSubscribe = id =>
  switch id {
  | None => true
  | Some(id) => id->namesSubscribe
  }

let wsMessageSchema = S.union([
  S.object(s => {
    let _ = s.field("method", S.literal("eth_subscription"))
    NewHead(
      s.field(
        "params",
        S.object(s => {
          s.field(
            "result",
            S.object(
              s => {
                s.field("number", Rpc.hexIntSchema)
              },
            ),
          )
        }),
      ),
    )
  }),
  S.object(s => {
    let id = s.field("id", responseIdSchema)
    let _ = s.field("result", S.string)
    Response({id, isError: false})
  }),
  S.object(s => {
    let id = s.field("id", responseIdSchema)
    // The error member as JSON-RPC defines it, rather than `S.unknown`: a
    // missing field parses as `undefined`, which `S.unknown` accepts, and this
    // arm would then match every frame the ones above turned down — including
    // one nobody can read.
    let _ = s.field("error", S.object(s => s.field("code", S.int)))
    Response({id, isError: true})
  }),
])

let subscribe = (~wsUrl, ~onHeight, ~onStatus) =>
  HeightStream.subscribe(~staleTimeout, ~onHeight, ~onStatus, ~connect=driver => {
    let ws = WebSocket.create(wsUrl)

    ws->WebSocket.onopen(() => ws->WebSocket.send(subscribeRequestJson))

    ws->WebSocket.onmessage(event =>
      if event.data->isText {
        let text = event.data->(Utils.magic: unknown => string)
        let message = try Some(text->JSON.parseOrThrow->S.parseOrThrow(wsMessageSchema)) catch {
        | _ => None
        }
        switch message {
        | Some(NewHead(blockNumber)) => driver.onHeight(blockNumber)
        // An open socket isn't usable until the node accepts the subscription,
        // and only the answer to the subscribe says that it has. A success frame
        // answering anything else would otherwise report a stream as live
        // without one ever having been subscribed.
        | Some(Response({id: Some(id), isError: false})) if id->namesSubscribe =>
          driver.onConnected()
        | Some(Response({id, isError: true})) if id->refusesSubscribe =>
          driver.onFailure(~reason=SubscribeRejected, ~detail=text)
        // A provider talking about something other than the subscription this
        // socket asked for — a rate limit, a request nobody here made. Read
        // fine, so not unreadable, and not this stream's to tear itself down
        // over.
        | Some(Response(_)) => ()
        | None => driver.onUnreadable(~detail=text)
        }
      } else {
        // A binary frame from a peer that should only ever be sending JSON text.
        driver.onUnreadable(~detail="binary frame")
      }
    )

    ws->WebSocket.onerror(error =>
      driver.onFailure(~reason=TransportError, ~detail=?error->JsExn.message)
    )
    ws->WebSocket.onclose(() => driver.onFailure(~reason=Closed))

    () => ws->WebSocket.close
  })
