/*
Pure subscription-based implementation of the HyperSync height stream.
*/

let subscribe = (~hyperSyncUrl, ~apiToken, ~chainId, ~onHeight: int => unit): (unit => unit) => {
  let eventsourceRef = ref(None)
  // Timeout doesn't do anything for initialization
  let timeoutIdRef = ref(setTimeout(() => (), 0))

  // On every successful ping or height event, clear the timeout and set a new one.
  // If the timeout lapses, close and reconnect the EventSource.
  let rec updateTimeoutId = () => {
    timeoutIdRef.contents->clearTimeout

    // Should receive a ping at least every 5s, so 15s is a safe margin
    // for staleness to restart the EventSource connection
    let staleTimeMillis = 15_000
    let newTimeoutId = setTimeout(() => {
      Logging.trace({
        "msg": "Timeout fired for height stream",
        "url": hyperSyncUrl,
        "staleTimeMillis": staleTimeMillis,
      })
      refreshEventSource()
    }, staleTimeMillis)

    timeoutIdRef := newTimeoutId
  }
  // Instantiate a new EventSource and set it to the shared refs.
  // Add the necessary event listeners, handle errors
  // and update the timeout.
  and refreshEventSource = () => {
    // Close the old EventSource if it exists (on a new connection after timeout)
    switch eventsourceRef.contents {
    | Some(es) => es->EventSource.close
    | None => ()
    }

    let userAgent = `hyperindex/${Utils.EnvioPackage.value.version}`
    let es = EventSource.create(
      ~url=`${hyperSyncUrl}/height/sse`,
      ~options={
        headers: Dict.fromArray([
          ("Authorization", `Bearer ${apiToken}`),
          ("User-Agent", userAgent),
        ]),
      },
    )

    // Set the new EventSource to the shared ref
    eventsourceRef := Some(es)
    // Update the timeout in case connection goes stale
    updateTimeoutId()

    es->EventSource.onopen(_ => {
      Logging.trace({"msg": "SSE connection opened for height stream", "url": hyperSyncUrl})
    })

    es->EventSource.onerror(error => {
      Logging.trace({
        "msg": "EventSource error",
        "error": error->JsExn.message,
      })
    })

    es->EventSource.addEventListener("ping", _event => {
      // ping lets us know from the server that the connection is still alive
      // and that the height hasn't updated for 5 seconds
      // update the timeout on each successful ping received
      updateTimeoutId()
    })

    es->EventSource.addEventListener("height", event => {
      switch event.data->Belt.Int.fromString {
      | Some(height) =>
        // Track the SSE height event
        Prometheus.SourceRequestCount.increment(
          ~sourceName="HyperSync",
          ~chainId,
          ~method="heightStream",
        )
        // On a successful height event, update the timeout
        updateTimeoutId()
        // Call the callback with the new height
        onHeight(height)
      | None => Logging.trace({"msg": "Height was not a number in event.data", "data": event.data})
      }
    })
  }

  // Start the EventSource connection
  refreshEventSource()

  // Return unsubscribe function
  () => {
    timeoutIdRef.contents->clearTimeout
    switch eventsourceRef.contents {
    | Some(es) => es->EventSource.close
    | None => ()
    }
  }
}
