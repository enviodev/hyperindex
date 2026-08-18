// The server pings every 5s, so 15s is a safe margin before treating the
// connection as dead.
let staleTimeout = 15_000

let failureReason = (error: EventSource.errorEvent) =>
  switch (error.code, error.message) {
  | (Some(code), _) => code->Int.toString
  | (None, Some(_)) => "error"
  // The stream ended without an HTTP error, which is how a load balancer
  // rotating connections shows up.
  | (None, None) => "closed"
  }

let subscribe = (~hyperSyncUrl, ~apiToken, ~onHeight, ~onStatus) =>
  HeightStream.subscribe(~staleTimeout, ~onHeight, ~onStatus, ~connect=driver => {
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

    es->EventSource.onopen(_ => driver.onConnected())
    es->EventSource.onerror(error => driver.onFailure(~reason=error->failureReason))
    es->EventSource.addEventListener("ping", _ => driver.onKeepAlive())
    es->EventSource.addEventListener("height", event =>
      switch event.data->Int.fromString {
      | Some(height) => driver.onHeight(height)
      // Not counted as traffic, so a stream that only ever sends garbage goes
      // stale and reconnects instead of looking healthy forever.
      | None => ()
      }
    )

    () => es->EventSource.close
  })
