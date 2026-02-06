/*
WebSocket-based implementation for real-time block height tracking.
Uses eth_subscribe("newHeads") for low-latency block detection.
Falls back behavior is handled by SourceManager when subscription fails.
*/

let retryCount = 9
let baseDuration = 125

type wsMessage =
  | NewHead(int)
  | SubscriptionConfirmed(string)
  | ErrorResponse

let wsMessageSchema = S.union([
  S.object(s => {
    let _ = s.field("method", S.literal("eth_subscription"))
    NewHead(
      s.field(
        "params",
        S.object(s => {
          s.field(
            "result",
            S.object(s => {
              s.field("number", Rpc.hexIntSchema)
            }),
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

  let rec startConnection = () => {
    if isUnsubscribed.contents || errorCount.contents >= retryCount {
      ()
    } else {
      let ws = WebSocket.create(wsUrl)
      wsRef := Some(ws)

      ws->WebSocket.onopen(() => {
        let subscribeRequest = Js.Json.serializeExn(
          Js.Json.object_(
            Js.Dict.fromArray([
              ("jsonrpc", Js.Json.string("2.0")),
              ("id", Js.Json.number(1.0)),
              ("method", Js.Json.string("eth_subscribe")),
              (
                "params",
                Js.Json.array([Js.Json.string("newHeads")]),
              ),
            ]),
          ),
        )
        ws->WebSocket.send(subscribeRequest)
      })

      ws->WebSocket.onmessage(event => {
        try {
          switch event.data->Js.Json.parseExn->S.parseOrThrow(wsMessageSchema) {
          | NewHead(blockNumber) =>
            errorCount := 0
            Prometheus.SourceRequestCount.increment(~sourceName="WebSocket", ~chainId)
            onHeight(blockNumber)
          | SubscriptionConfirmed(_) => ()
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
        | _ => ()
        }
      })

      ws->WebSocket.onerror(_error => {
        if errorCount.contents < retryCount {
          errorCount := errorCount.contents + 1
        }
        switch wsRef.contents {
        | Some(ws) if ws->WebSocket.readyState === WebSocket.open_ => ws->WebSocket.close
        | _ =>
          wsRef := None
          if !isUnsubscribed.contents && errorCount.contents < retryCount {
            let duration =
              baseDuration *
              Js.Math.pow_float(
                ~base=2.0,
                ~exp=errorCount.contents->Belt.Int.toFloat,
              )->Belt.Float.toInt
            let _ = Js.Global.setTimeout(() => startConnection(), duration)
          }
        }
      })

      ws->WebSocket.onclose(() => {
        wsRef := None

        if !isUnsubscribed.contents && errorCount.contents < retryCount {
          let duration =
            baseDuration *
            Js.Math.pow_float(
              ~base=2.0,
              ~exp=errorCount.contents->Belt.Int.toFloat,
            )->Belt.Float.toInt
          let _ = Js.Global.setTimeout(() => startConnection(), duration)
        }
      })
    }
  }

  startConnection()

  () => {
    isUnsubscribed := true
    switch wsRef.contents {
    | Some(ws) => ws->WebSocket.close
    | None => ()
    }
  }
}
