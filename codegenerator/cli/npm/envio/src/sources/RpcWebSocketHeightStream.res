/*
WebSocket-based implementation for real-time block height tracking.
Uses eth_subscribe("newHeads") for low-latency block detection.
Falls back behavior is handled by SourceManager when subscription fails.
*/

let retryCount = 9
let baseDuration = 125
// Close and reconnect if no new block head arrives within this period.
// Detects silently dropped server-side subscriptions.
let staleTimeMillis = 60_000

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
  } => Js.Json.t)
  ->Js.Json.serializeExn

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

let subscribe = (~wsUrl, ~chainId, ~onHeight: int => unit): (unit => unit) => {
  let wsRef: ref<option<WebSocket.t>> = ref(None)
  let isUnsubscribed = ref(false)
  let errorCount = ref(0)
  let staleTimeoutId: ref<option<timeoutId>> = ref(None)

  let clearStaleTimeout = () => {
    switch staleTimeoutId.contents {
    | Some(id) =>
      clearTimeout(id)
      staleTimeoutId := None
    | None => ()
    }
  }

  let resetStaleTimeout = () => {
    clearStaleTimeout()
    staleTimeoutId := Some(setTimeout(() => {
          // Connection went stale - close to trigger reconnect
          switch wsRef.contents {
          | Some(ws) => ws->WebSocket.close
          | None => ()
          }
        }, staleTimeMillis))
  }

  let rec scheduleReconnect = () => {
    if !isUnsubscribed.contents && errorCount.contents < retryCount {
      let duration =
        baseDuration * Math.pow(2.0, ~exp=errorCount.contents->Belt.Int.toFloat)->Belt.Float.toInt
      let _ = setTimeout(() => {
        if !isUnsubscribed.contents {
          startConnection()
        }
      }, duration)
    }
  }
  and startConnection = () => {
    if isUnsubscribed.contents || errorCount.contents >= retryCount {
      ()
    } else {
      let ws = WebSocket.create(wsUrl)
      wsRef := Some(ws)

      ws->WebSocket.onopen(() => {
        ws->WebSocket.send(subscribeRequestJson)
        resetStaleTimeout()
      })

      ws->WebSocket.onmessage(event => {
        try {
          switch event.data->JSON.parseOrThrow->S.parseOrThrow(wsMessageSchema) {
          | NewHead(blockNumber) =>
            errorCount := 0
            resetStaleTimeout()
            Prometheus.SourceRequestCount.increment(
              ~sourceName="WebSocket",
              ~chainId,
              ~method="eth_subscribe",
            )
            onHeight(blockNumber)
          | SubscriptionConfirmed(_) => resetStaleTimeout()
          | ErrorResponse =>
            if errorCount.contents < retryCount {
              errorCount := errorCount.contents + 1
            }
            switch wsRef.contents {
            | Some(ws) => ws->WebSocket.close
            | None => ()
            }
          }
        } catch {
        | S.Error(_) =>
          Logging.warn({
            "msg": "WebSocket height stream received unrecognized message",
            "chainId": chainId,
            "data": event.data,
          })
        | JsExn(_) as e =>
          Logging.warn({
            "msg": "WebSocket height stream failed to parse message",
            "chainId": chainId,
            "err": e->Utils.prettifyExn,
            "data": event.data,
          })
        | e =>
          Logging.error({
            "msg": "Unexpected error in WebSocket height stream message handler",
            "chainId": chainId,
            "err": e->Utils.prettifyExn,
            "data": event.data,
          })
          throw(e)
        }
      })

      ws->WebSocket.onerror(_error => {
        if errorCount.contents < retryCount {
          errorCount := errorCount.contents + 1
        }
        switch wsRef.contents {
        | Some(ws) if ws->WebSocket.readyState === Open => ws->WebSocket.close
        | _ => ()
        }
      })

      ws->WebSocket.onclose(() => {
        wsRef := None
        clearStaleTimeout()
        scheduleReconnect()
      })
    }
  }

  startConnection()

  () => {
    isUnsubscribed := true
    clearStaleTimeout()
    switch wsRef.contents {
    | Some(ws) => ws->WebSocket.close
    | None => ()
    }
  }
}
