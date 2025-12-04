/*
Pure js implementation of the HyperSync height stream.
*/

type t = {
  heightRef: ref<int>,
  errorRef: ref<option<string>>,
  timeoutIdRef: ref<Js.Global.timeoutId>,
  eventsourceRef: ref<option<EventSource.t>>,
}

let make = (~hyperSyncUrl, ~apiToken) => {
  /**
  On every successful ping or height event, clear the timeout and set a new one.

  if the timeout lapses, close and reconnect the EventSource.
  */
  let rec updateTimeoutId = (
    ~eventsourceRef: ref<option<EventSource.t>>,
    ~timeoutIdRef: ref<Js.Global.timeoutId>,
    ~hyperSyncUrl,
    ~apiToken,
    ~heightRef: ref<int>,
    ~errorRef: ref<option<string>>,
  ) => {
    timeoutIdRef.contents->Js.Global.clearTimeout

    // Should receive a ping at least every 5s, so 15s is a safe margin
    // for staleness to restart the EventSource connection
    let staleTimeMillis = 15_000
    let newTimeoutId = Js.Global.setTimeout(() => {
      Logging.trace({
        "msg": "Timeout fired for height stream",
        "url": hyperSyncUrl,
        "staleTimeMillis": staleTimeMillis,
      })
      refreshEventSource(
        ~eventsourceRef,
        ~hyperSyncUrl,
        ~apiToken,
        ~heightRef,
        ~errorRef,
        ~timeoutIdRef,
      )
    }, staleTimeMillis)

    timeoutIdRef := newTimeoutId
  }
  and /**
    Instantiate a new EventSource and set it to the shared refs.
    Add the necessary event listeners, handle errors
    and update the timeout.
    */
  refreshEventSource = (
    ~eventsourceRef: ref<option<EventSource.t>>,
    ~hyperSyncUrl,
    ~apiToken,
    ~heightRef: ref<int>,
    ~errorRef: ref<option<string>>,
    ~timeoutIdRef: ref<Js.Global.timeoutId>,
  ) => {
    // Close the old EventSource if it exists (on a new connection after timeout)
    switch eventsourceRef.contents {
    | Some(es) => es->EventSource.close
    | None => ()
    }

    let userAgent = `hyperindex/${Utils.EnvioPackage.json.version}`
    let es = EventSource.create(
      ~url=`${hyperSyncUrl}/height/sse`,
      ~options={
        headers: Js.Dict.fromArray([
          ("Authorization", `Bearer ${apiToken}`),
          ("User-Agent", userAgent),
        ]),
      },
    )

    // Set the new EventSource to the shared ref
    eventsourceRef := Some(es)
    // Update the timeout in case connection goes stale
    updateTimeoutId(~eventsourceRef, ~timeoutIdRef, ~hyperSyncUrl, ~apiToken, ~heightRef, ~errorRef)

    es->EventSource.onopen(_ => {
      Logging.trace({"msg": "SSE connection opened for height stream", "url": hyperSyncUrl})
    })

    es->EventSource.onerror(error => {
      Logging.trace({
        "msg": "EventSource error",
        "error": error->Js.Exn.message,
      })
      // On errors, set the error ref
      // so that getHeight can raise an error
      errorRef :=
        Some(error->Js.Exn.message->Belt.Option.getWithDefault("Unexpected no error.message"))
    })

    es->EventSource.addEventListener("ping", _event => {
      // ping lets us know from the server that the connection is still alive
      // and that the height hasn't updated for 5seconds
      // update the timeout on each successful ping received
      updateTimeoutId(
        ~eventsourceRef,
        ~timeoutIdRef,
        ~hyperSyncUrl,
        ~apiToken,
        ~heightRef,
        ~errorRef,
      )
      // reset the error ref, since we had a successful ping
      errorRef := None
    })

    es->EventSource.addEventListener("height", event => {
      switch event.data->Belt.Int.fromString {
      | Some(height) =>
        // On a successful height event, update the timeout
        // and reset the error ref
        updateTimeoutId(
          ~eventsourceRef,
          ~timeoutIdRef,
          ~hyperSyncUrl,
          ~apiToken,
          ~heightRef,
          ~errorRef,
        )
        errorRef := None
        // Set the actual height ref
        heightRef := height
      | None =>
        Logging.trace({"msg": "Height was not a number in event.data", "data": event.data})
        errorRef := Some("Height was not a number in event.data")
      }
    })
  }

  // Refs used between the functions

  let heightRef = ref(0)
  let errorRef = ref(None)
  let eventsourceRef = ref(None)
  // Timeout doesn't do anything for initalization
  let timeoutIdRef = ref(Js.Global.setTimeout(() => (), 0))
  refreshEventSource(
    ~eventsourceRef,
    ~hyperSyncUrl,
    ~apiToken,
    ~heightRef,
    ~errorRef,
    ~timeoutIdRef,
  )

  {
    heightRef,
    errorRef,
    timeoutIdRef,
    eventsourceRef,
  }
}

let getHeight = async (t: t) => {
  while t.heightRef.contents == 0 && t.errorRef.contents == None {
    // Poll internally until height is over 0
    await Utils.delay(200)
  }
  switch t.errorRef.contents {
  | None => t.heightRef.contents
  | Some(error) => Js.Exn.raiseError(error)
  }
}

let close = t => {
  t.timeoutIdRef.contents->Js.Global.clearTimeout
  switch t.eventsourceRef.contents {
  | Some(es) => es->EventSource.close
  | None => ()
  }
}
