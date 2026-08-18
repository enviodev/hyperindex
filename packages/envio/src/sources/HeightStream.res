/*
Reconnect driver shared by every height subscription transport. A transport
supplies `connect`, which wires its socket to the driver callbacks and returns a
close function; the driver owns retries, staleness detection and status
reporting so SSE and WebSocket streams behave identically.
*/

type driver = {
  // The stream is usable: for SSE the connection opened, for WebSocket the
  // subscription was confirmed. Resets the retry backoff.
  onConnected: unit => unit,
  // Traffic that proves the connection is alive without carrying a height.
  onKeepAlive: unit => unit,
  onHeight: int => unit,
  onFailure: (~reason: string) => unit,
}

// While a stream is down its consumer polls instead, so the retry delay is what
// that fallback costs: a load balancer rotating a connection heals on the first
// retry, and every polling interval spent waiting for it is an avoidable
// request. Small first step, with the doubling to protect an endpoint that is
// genuinely in trouble.
let baseRetryMillis = 250
let maxRetryMillis = 60_000
// Keeps the doubling from overflowing on a stream that has been failing for
// days. The delay reaches maxRetryMillis long before this.
let maxRetryExponent = 20

let subscribe = (
  ~staleTimeout: int,
  ~onHeight: int => unit,
  ~onStatus: Source.heightSubscriptionStatus => unit,
  ~connect: driver => unit => unit,
): (unit => unit) => {
  let closeConnectionRef = ref(None)
  let unsubscribed = ref(false)
  let failureCount = ref(0)
  // Bumped on every failure, reconnect and unsubscribe. Callbacks from a
  // superseded connection compare against it and no-op, so a socket that
  // reports an error and then a close only counts as one failure.
  let generation = ref(0)
  // A connection is either waiting for traffic or waiting to be retried, never
  // both, so a single slot holds whichever timer is pending.
  let timeoutId = ref(None)

  let clearPendingTimeout = () => {
    switch timeoutId.contents {
    | Some(id) => clearTimeout(id)
    | None => ()
    }
    timeoutId := None
  }

  let closeConnection = () => {
    switch closeConnectionRef.contents {
    | Some(closeConnection) => closeConnection()
    | None => ()
    }
    closeConnectionRef := None
  }

  let rec armStaleTimeout = () => {
    clearPendingTimeout()
    timeoutId := Some(setTimeout(() => {
          timeoutId := None
          fail(~reason="stale")
        }, staleTimeout))
  }
  and fail = (~reason) => {
    generation := generation.contents + 1
    clearPendingTimeout()
    closeConnection()
    failureCount := failureCount.contents + 1

    let exp = Pervasives.min(failureCount.contents - 1, maxRetryExponent)->Int.toFloat
    let retryMillis = Pervasives.min(
      baseRetryMillis * Math.pow(2.0, ~exp)->Float.toInt,
      maxRetryMillis,
    )
    // Scheduled before reporting, so a consumer that throws can't be what makes
    // the stream give up.
    timeoutId := Some(setTimeout(() => {
          timeoutId := None
          start()
        }, retryMillis))

    onStatus(Down({reason: reason}))
  }
  and start = () => {
    generation := generation.contents + 1
    let connectionGeneration = generation.contents
    let isCurrent = () => !unsubscribed.contents && generation.contents === connectionGeneration

    // Armed before connecting, so it covers a connect that never reports
    // anything, and so a synchronous failure inside connect replaces it with
    // the retry timeout rather than the other way around.
    armStaleTimeout()

    let closeCurrentConnection = connect({
      onConnected: () =>
        if isCurrent() {
          failureCount := 0
          armStaleTimeout()
          onStatus(Live)
        },
      onKeepAlive: () =>
        if isCurrent() {
          armStaleTimeout()
        },
      onHeight: height =>
        if isCurrent() {
          armStaleTimeout()
          onHeight(height)
        },
      onFailure: (~reason) =>
        if isCurrent() {
          fail(~reason)
        },
    })

    if isCurrent() {
      closeConnectionRef := Some(closeCurrentConnection)
    } else {
      closeCurrentConnection()
    }
  }

  start()

  () => {
    unsubscribed := true
    generation := generation.contents + 1
    clearPendingTimeout()
    closeConnection()
  }
}
