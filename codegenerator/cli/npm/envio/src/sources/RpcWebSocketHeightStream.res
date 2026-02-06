/*
WebSocket-based implementation for real-time block height tracking.
Uses eth_subscribe("newHeads") for low-latency block detection.
Falls back behavior is handled by SourceManager when subscription fails.
*/

let retryCount = 9
let baseDuration = 125

let parseHexInt: string => option<int> = %raw(`function(hex) {
  var n = parseInt(hex, 16);
  return isNaN(n) ? undefined : n;
}`)

let subscribe = (~wsUrl, ~chainId, ~onHeight: int => unit): (unit => unit) => {
  let wsRef: ref<option<WebSocket.t>> = ref(None)
  let isUnsubscribed = ref(false)
  let subscriptionId: ref<option<string>> = ref(None)
  let errorCount = ref(0)

  let rec startConnection = () => {
    if isUnsubscribed.contents || errorCount.contents >= retryCount {
      // Exhausted retries or unsubscribed - stop reconnecting.
      // SourceManager will fall back to polling.
      ()
    } else {
      let ws = WebSocket.create(wsUrl)
      wsRef := Some(ws)

      ws->WebSocket.onopen(() => {
        Logging.trace({
          "msg": "WebSocket connection opened for height stream",
          "url": wsUrl,
          "chainId": chainId,
        })
        // Send eth_subscribe("newHeads") request
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
          let msg = event.data->Js.Json.parseExn
          let msgDict =
            msg
            ->Js.Json.decodeObject
            ->Belt.Option.getWithDefault(Js.Dict.empty())

          // Check if it's a subscription notification with a block header
          let isSubscriptionNotification = switch msgDict->Js.Dict.get("method") {
          | Some(method) =>
            method->Js.Json.decodeString->Belt.Option.getWithDefault("") === "eth_subscription"
          | None => false
          }

          if isSubscriptionNotification {
            // Extract block number from params.result.number
            switch msgDict->Js.Dict.get("params") {
            | Some(params) =>
              switch params->Js.Json.decodeObject {
              | Some(paramsDict) =>
                // Verify subscription ID matches
                let matchesSubscription = switch (
                  paramsDict->Js.Dict.get("subscription"),
                  subscriptionId.contents,
                ) {
                | (Some(subId), Some(expectedId)) =>
                  subId->Js.Json.decodeString->Belt.Option.getWithDefault("") === expectedId
                | _ => true // Accept if we don't have a subscription ID yet
                }

                if matchesSubscription {
                  switch paramsDict->Js.Dict.get("result") {
                  | Some(result) =>
                    switch result->Js.Json.decodeObject {
                    | Some(resultDict) =>
                      switch resultDict->Js.Dict.get("number") {
                      | Some(numberJson) =>
                        switch numberJson->Js.Json.decodeString {
                        | Some(hexNumber) =>
                          // Parse hex block number (0x...)
                          let blockNumber = parseHexInt(hexNumber)
                          switch blockNumber {
                          | Some(height) =>
                            // Reset error count on successful message
                            errorCount := 0
                            Prometheus.SourceRequestCount.increment(
                              ~sourceName="WebSocket",
                              ~chainId,
                            )
                            onHeight(height)
                          | None =>
                            Logging.trace({
                              "msg": "Failed to parse block number from WebSocket newHeads",
                              "number": hexNumber,
                            })
                          }
                        | None => ()
                        }
                      | None => ()
                      }
                    | None => ()
                    }
                  | None => ()
                  }
                }
              | None => ()
              }
            | None => ()
            }
          } else {
            // Check if this is a subscription ID confirmation
            switch msgDict->Js.Dict.get("result") {
            | Some(result) =>
              switch result->Js.Json.decodeString {
              | Some(subId) =>
                subscriptionId := Some(subId)
                Logging.trace({
                  "msg": "WebSocket subscription confirmed",
                  "subscriptionId": subId,
                  "chainId": chainId,
                })
              | None => ()
              }
            | None =>
              // Check if server returned an error
              switch msgDict->Js.Dict.get("error") {
              | Some(_) =>
                Logging.trace({
                  "msg": "WebSocket received error response",
                  "chainId": chainId,
                })
                if errorCount.contents < retryCount {
                  errorCount := errorCount.contents + 1
                }
                switch wsRef.contents {
                | Some(ws) => ws->WebSocket.close
                | None => ()
                }
              | None => ()
              }
            }
          }
        } catch {
        | exn =>
          Logging.trace({
            "msg": "Error processing WebSocket message",
            "err": exn->Utils.prettifyExn,
            "chainId": chainId,
          })
          if errorCount.contents < retryCount {
            errorCount := errorCount.contents + 1
          }
          switch wsRef.contents {
          | Some(ws) => ws->WebSocket.close
          | None => ()
          }
        }
      })

      ws->WebSocket.onerror(error => {
        Logging.trace({
          "msg": "WebSocket error for height stream",
          "error": error->Js.Exn.message,
          "url": wsUrl,
          "chainId": chainId,
          "errorCount": errorCount.contents,
        })
        if errorCount.contents < retryCount {
          errorCount := errorCount.contents + 1
        }
        // If socket is open, close it (will trigger onclose -> reconnect).
        // If it never opened, trigger reconnect directly.
        switch wsRef.contents {
        | Some(ws) if ws->WebSocket.readyState === WebSocket.open_ => ws->WebSocket.close
        | _ =>
          wsRef := None
          if !isUnsubscribed.contents && errorCount.contents < retryCount {
            let duration = baseDuration * Js.Math.pow_float(~base=2.0, ~exp=errorCount.contents->Belt.Int.toFloat)->Belt.Float.toInt
            let _ = Js.Global.setTimeout(() => startConnection(), duration)
          }
        }
      })

      ws->WebSocket.onclose(() => {
        wsRef := None
        subscriptionId := None

        if !isUnsubscribed.contents && errorCount.contents < retryCount {
          // Exponential backoff: 125, 250, 500, 1000, 2000, 4000, 8000, 16000, 32000 ms
          let duration = baseDuration * Js.Math.pow_float(~base=2.0, ~exp=errorCount.contents->Belt.Int.toFloat)->Belt.Float.toInt
          Logging.trace({
            "msg": "WebSocket closed, reconnecting after backoff",
            "duration": duration,
            "errorCount": errorCount.contents,
            "chainId": chainId,
          })
          let _ = Js.Global.setTimeout(() => startConnection(), duration)
        }
      })
    }
  }

  // Start the initial connection
  startConnection()

  // Return unsubscribe function
  () => {
    isUnsubscribed := true
    switch wsRef.contents {
    | Some(ws) =>
      // Send eth_unsubscribe before closing for clean server-side cleanup
      switch subscriptionId.contents {
      | Some(subId) =>
        try {
          let unsubscribeRequest = Js.Json.serializeExn(
            Js.Json.object_(
              Js.Dict.fromArray([
                ("jsonrpc", Js.Json.string("2.0")),
                ("id", Js.Json.number(2.0)),
                ("method", Js.Json.string("eth_unsubscribe")),
                ("params", Js.Json.array([Js.Json.string(subId)])),
              ]),
            ),
          )
          ws->WebSocket.send(unsubscribeRequest)
        } catch {
        | _ => () // Ignore send errors during cleanup
        }
      | None => ()
      }
      ws->WebSocket.close
    | None => ()
    }
  }
}
