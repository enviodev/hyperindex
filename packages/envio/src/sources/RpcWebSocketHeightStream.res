/*
WebSocket-based implementation for real-time block height tracking.
Uses eth_subscribe("newHeads") for low-latency block detection.
*/

// newHeads carries no keep-alive, so this has to tolerate slow chains rather
// than the seconds an SSE ping allows.
let staleTimeout = 60_000

type wsMessage =
  | NewHead(int)
  | SubscriptionConfirmed(string)
  | ErrorResponse

let subscribeRequestJson =
  {"jsonrpc": "2.0", "id": 1, "method": "eth_subscribe", "params": ["newHeads"]}
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
    SubscriptionConfirmed(s.field("result", S.string))
  }),
  S.object(s => {
    let _ = s.field("error", S.unknown)
    ErrorResponse
  }),
])

let subscribe = (~wsUrl, ~onHeight, ~onStatus) =>
  HeightStream.subscribe(~staleTimeout, ~onHeight, ~onStatus, ~connect=driver => {
    let ws = WebSocket.create(wsUrl)

    ws->WebSocket.onopen(() => ws->WebSocket.send(subscribeRequestJson))

    ws->WebSocket.onmessage(event => {
      let message = try {
        Some(event.data->JSON.parseOrThrow->S.parseOrThrow(wsMessageSchema))
      } catch {
      | _ => None
      }
      switch message {
      | Some(NewHead(blockNumber)) => driver.onHeight(blockNumber)
      // An open socket isn't usable until the node accepts the subscription.
      | Some(SubscriptionConfirmed(_)) => driver.onConnected()
      | Some(ErrorResponse) => driver.onFailure(~reason="subscribe-rejected")
      | None => driver.onUnreadable()
      }
    })

    ws->WebSocket.onerror(_ => driver.onFailure(~reason="error"))
    ws->WebSocket.onclose(() => driver.onFailure(~reason="closed"))

    () => ws->WebSocket.close
  })
