// The server pings every 5s, so 15s is a safe margin before treating the
// connection as dead.
let staleTimeout = 15_000

let failure = (error: EventSource.errorEvent): (
  Source.heightSubscriptionDownReason,
  option<string>,
) =>
  switch (error.code, error.message) {
  | (Some(code), message) => (Http(code), message)
  | (None, Some(message)) => (TransportError, Some(message))
  // The stream ended without an HTTP error, which is how a load balancer
  // rotating connections shows up.
  | (None, None) => (Closed, None)
  }

let subscribe = (~hyperSyncUrl, ~apiToken, ~onHeight, ~onStatus) =>
  HeightStream.subscribe(~staleTimeout, ~onHeight, ~onStatus, ~connect=driver => {
    let userAgent = `hyperindex/${Utils.EnvioPackage.value.version}`
    let es = EventSource.create(
      ~url=`${hyperSyncUrl}/height/sse`,
      ~options={
        fetch: (url, ~args) => {
          let headers =
            args.headers
            ->Option.getOr(Dict.make())
            ->Utils.Dict.merge(
              Dict.fromArray([("Authorization", `Bearer ${apiToken}`), ("User-Agent", userAgent)]),
            )
          EventSource.Fetch.fetch(url, ~args={...args, headers: headers})
        },
      },
    )

    es->EventSource.onopen(_ => driver.onConnected())
    es->EventSource.onerror(error => {
      let (reason, detail) = error->failure
      driver.onFailure(~reason, ~detail?)
    })
    es->EventSource.addEventListener("ping", _ => driver.onKeepAlive())
    es->EventSource.addEventListener("height", event =>
      switch event.data->Int.fromString {
      | Some(height) => driver.onHeight(height)
      | None => driver.onUnreadable(~detail=event.data)
      }
    )

    () => es->EventSource.close
  })
