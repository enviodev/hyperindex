/*
Pure subscription-based implementation of the HyperSync height stream.
*/

let subscribe = (~hyperSyncUrl, ~apiToken, ~chainId, ~onHeight: int => unit): (unit => unit) => {
  let eventsourceRef = ref(None)
  let errorCount = ref(0)
  let openedAtRef = ref(None)
  let baseDuration = 50
  let maxDuration = 60_000
  // Enough consecutive failures that the head is meaningfully stale, so an
  // operator should see it without turning on trace logs.
  let warnAfterErrorCount = 5
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
        "chainId": chainId,
        "url": hyperSyncUrl,
        "staleTimeMillis": staleTimeMillis,
      })
      refreshEventSource()
    }, staleTimeMillis)

    timeoutIdRef := newTimeoutId
  }
  and retryDelay = () => {
    let exp = Pervasives.min(errorCount.contents, 20)->Int.toFloat
    Pervasives.min(baseDuration * Math.pow(2.0, ~exp)->Float.toInt, maxDuration)
  }
  and scheduleReconnect = delay => {
    // Clear any pending stale/reconnect timeout to avoid double reconnect
    timeoutIdRef.contents->clearTimeout
    timeoutIdRef := setTimeout(() => refreshEventSource(), delay)
  }
  and handleError = (error: EventSource.errorEvent) => {
    errorCount := errorCount.contents + 1

    let connectedForMillis =
      openedAtRef.contents->Option.map(openedAt => (Performance.now() -. openedAt)->Float.toInt)
    openedAtRef := None

    // The eventsource package schedules its own retry for recoverable failures.
    // Close the connection here so that retry can't race the one we schedule,
    // and read readyState first to tell the two cases apart.
    let fatal = switch eventsourceRef.contents {
    | Some(es) =>
      let fatal = es->EventSource.readyState === EventSource.closed
      es->EventSource.close
      fatal
    | None => false
    }
    eventsourceRef := None

    let delay = retryDelay()
    let isUnauthorized = switch error.code {
    | Some(401 | 403) => true
    | _ => false
    }
    let payload = {
      "msg": isUnauthorized
        ? "Your ENVIO_API_TOKEN was rejected by HyperSync for the height stream. The indexer will not see new blocks until the token is fixed. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens"
        : "EventSource error on height stream, reconnecting",
      "chainId": chainId,
      "url": hyperSyncUrl,
      "status": error.code,
      "error": error.message,
      "errorCount": errorCount.contents,
      "fatal": fatal,
      "connectedForMillis": connectedForMillis,
      "retryInMillis": delay,
    }
    if isUnauthorized && errorCount.contents === 1 {
      Logging.error(payload)
    } else if isUnauthorized || errorCount.contents >= warnAfterErrorCount {
      Logging.warn(payload)
    } else {
      Logging.trace(payload)
    }

    scheduleReconnect(delay)
  }
  and refreshEventSource = () => {
    // Close the old EventSource if it exists (on a new connection after timeout)
    switch eventsourceRef.contents {
    | Some(es) => es->EventSource.close
    | None => ()
    }
    openedAtRef := None

    let userAgent = `hyperindex/${Utils.EnvioPackage.value.version}`
    let es = EventSource.create(
      ~url=`${hyperSyncUrl}/height/sse`,
      ~options={
        fetch: (url, ~args) => {
          EventSource.Fetch.fetch(
            url,
            ~args={
              ...args,
              headers: Dict.fromArray([
                ("Authorization", `Bearer ${apiToken}`),
                ("User-Agent", userAgent),
              ]),
            },
          )
        },
      },
    )

    // Set the new EventSource to the shared ref
    eventsourceRef := Some(es)
    // Update the timeout in case connection goes stale
    updateTimeoutId()

    es->EventSource.onopen(_ => {
      errorCount := 0
      openedAtRef := Some(Performance.now())
      Logging.trace({
        "msg": "SSE connection opened for height stream",
        "chainId": chainId,
        "url": hyperSyncUrl,
      })
    })

    es->EventSource.onerror(handleError)

    es->EventSource.addEventListener("ping", _event => {
      // ping lets us know from the server that the connection is still alive
      // and that the height hasn't updated for 5 seconds
      // update the timeout on each successful ping received
      updateTimeoutId()
    })

    es->EventSource.addEventListener("height", event => {
      switch event.data->Int.fromString {
      | Some(height) =>
        // On a successful height event, update the timeout
        updateTimeoutId()
        // Call the callback with the new height
        onHeight(height)
      | None =>
        Logging.trace({
          "msg": "Height was not a number in event.data",
          "chainId": chainId,
          "data": event.data,
        })
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
