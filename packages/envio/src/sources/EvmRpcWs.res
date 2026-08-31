// newHeads carries no keep-alive, so this has to tolerate slow chains rather
// than the seconds an SSE ping allows.
let staleTimeout = 60_000

// The id of the one request this stream ever sends, which is what tells an error
// meant for it apart from one about anything else sharing the socket.
let subscribeRequestId = 1

type wsMessage =
  | NewHead(int)
  | SubscriptionConfirmed
  // An error frame, carrying the id of the request it answers when it names one.
  | ErrorResponse(option<int>)

let subscribeRequestJson =
  {"jsonrpc": "2.0", "id": subscribeRequestId, "method": "eth_subscribe", "params": ["newHeads"]}
  ->(Utils.magic: {
    "jsonrpc": string,
    "id": int,
    "method": string,
    "params": array<string>,
  } => JSON.t)
  ->JSON.stringify

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
    let _ = s.field("result", S.string)
    SubscriptionConfirmed
  }),
  S.object(s => {
    // Nullable, not merely optional: JSON-RPC answers a request whose id it
    // could not read with an explicit null, and that is still an error frame.
    let id = s.field("id", S.nullable(S.int))
    // The error member as JSON-RPC defines it, rather than `S.unknown`: a
    // missing field parses as `undefined`, which `S.unknown` accepts, and this
    // arm would then match every frame the ones above turned down — including
    // one nobody can read.
    let _ = s.field("error", S.object(s => s.field("code", S.int)))
    ErrorResponse(id)
  }),
])

let subscribe = (~wsUrl, ~onHeight, ~onStatus) =>
  HeightStream.subscribe(~staleTimeout, ~onHeight, ~onStatus, ~connect=driver => {
    let ws = WebSocket.create(wsUrl)

    ws->WebSocket.onopen(() => ws->WebSocket.send(subscribeRequestJson))

    ws->WebSocket.onmessage(event => {
      let message = Utils.Option.catchToNone(
        () => event.data->JSON.parseOrThrow->S.parseOrThrow(wsMessageSchema),
      )
      switch message {
      | Some(NewHead(blockNumber)) => driver.onHeight(blockNumber)
      // An open socket isn't usable until the node accepts the subscription.
      | Some(SubscriptionConfirmed) => driver.onConnected()
      | Some(ErrorResponse(Some(id))) if id === subscribeRequestId =>
        driver.onFailure(~reason="subscribe-rejected", ~detail=event.data)
      // A provider reporting trouble with something other than the subscription
      // this socket asked for — a rate limit, a request nobody here made. Read
      // fine, so not unreadable, and not this stream's to tear itself down over.
      | Some(ErrorResponse(_)) => ()
      | None => driver.onUnreadable(~detail=event.data)
      }
    })

    ws->WebSocket.onerror(error => driver.onFailure(~reason="error", ~detail=?error->JsExn.message))
    ws->WebSocket.onclose(() => driver.onFailure(~reason=Source.closedReason))

    () => ws->WebSocket.close
  })
