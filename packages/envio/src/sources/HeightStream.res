/*
Reconnect driver shared by every height subscription transport. A transport
supplies `connect`, which wires its socket to the driver callbacks and returns a
close function; the driver owns retries, staleness detection and status
reporting so SSE and WebSocket streams behave identically.

Nothing here logs. A height stream failing is not something an operator has to
act on — the indexer polls for the height instead — so its health is reported
through the envio_source_height_stream_* counters, and every failure reason has
to stand on its own as a metric label.
*/

type driver = {
  // The stream is usable: for SSE the connection opened, for WebSocket the
  // subscription was confirmed.
  onConnected: unit => unit,
  // Traffic that proves the connection is alive without carrying a height.
  onKeepAlive: unit => unit,
  onHeight: int => unit,
  // A message the transport couldn't read. Not a failure by itself, but from
  // then on only a height we can read counts as the connection still being
  // useful, so a stream of them goes quiet and fails as "unreadable".
  onUnreadable: unit => unit,
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
  // Must not allocate anything it can then throw past: a throw leaves the driver
  // without the close function, so only the transport can release what it took.
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
  let connectionStartedAt = ref(Performance.now())
  let sawUnreadable = ref(false)

  let clearPendingTimeout = () => {
    switch timeoutId.contents {
    | Some(id) => clearTimeout(id)
    | None => ()
    }
    timeoutId := None
  }

  // A transport that throws while closing must not be able to stop the retry
  // that follows, nor escape a timer callback and take the process down. Every
  // close goes through here, including the one for a connection superseded
  // while connect was still running.
  let closeSafely = close =>
    try close() catch {
    | _ => ()
    }

  let closeConnection = () => {
    switch closeConnectionRef.contents {
    | Some(close) => closeSafely(close)
    | None => ()
    }
    closeConnectionRef := None
  }

  let rec armStaleTimeout = () => {
    clearPendingTimeout()
    timeoutId := Some(setTimeout(() => {
          timeoutId := None
          // Distinguishes a provider whose message shape we don't understand
          // from a chain that simply has nothing to report.
          fail(~reason=sawUnreadable.contents ? "unreadable" : "stale", ~windowElapsed=true)
        }, staleTimeout))
  }
  and fail = (~reason, ~windowElapsed=false) => {
    generation := generation.contents + 1
    clearPendingTimeout()
    closeConnection()

    // A connection that lasted a full staleness window did its job, however it
    // ended, and deserves a prompt retry. Duration rather than whether it
    // connected or carried traffic, because HyperSync sends a height the moment
    // it connects: an endpoint accepting and dropping connections would
    // otherwise look healthy every time and never back off.
    //
    // The staleness timer knows it waited the window out, and says so rather
    // than leaving it to be re-derived: a timer can reach its own deadline a
    // fraction of a millisecond before the clock agrees. So those failures never
    // escalate, which is what a chain whose blocks are further apart than the
    // timeout needs, and costs nothing on an endpoint that is silent or
    // unreadable either, because reaching the timeout is what already spaces
    // those retries a whole window apart.
    if (
      windowElapsed ||
        Performance.now() -. connectionStartedAt.contents >= staleTimeout->Int.toFloat
    ) {
      failureCount := 0
    }
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
    connectionStartedAt := Performance.now()
    sawUnreadable := false
    let connectionGeneration = generation.contents
    let isCurrent = () => !unsubscribed.contents && generation.contents === connectionGeneration

    // Armed before connecting, so it covers a connect that never reports
    // anything, and so a synchronous failure inside connect replaces it with
    // the retry timeout rather than the other way around.
    armStaleTimeout()

    // A height is proof the stream is delivering, so it reports Live as well as
    // onConnected does. Without that, a transport that never reports the
    // connection usable would leave its consumer polling at full rate next to a
    // stream that works.
    let reportedLive = ref(false)
    let goLive = () => {
      armStaleTimeout()
      if !reportedLive.contents {
        reportedLive := true
        onStatus(Live)
      }
    }

    let driver = {
      onConnected: () =>
        if isCurrent() {
          goLive()
        },
      onKeepAlive: () =>
        // Stops counting once something unreadable has arrived. A stream whose
        // heights are all malformed would otherwise be held open indefinitely
        // by the keep-alives between them, never failing and so never reporting
        // anything, while its consumer sat on the staleness backstop.
        if isCurrent() && !sawUnreadable.contents {
          armStaleTimeout()
        },
      onHeight: height =>
        if isCurrent() {
          // A height we could read proves the shape is fine again. A keep-alive
          // deliberately doesn't: on a stream whose heights are all malformed,
          // the pings between them would clear this and the staleness that
          // followed would look like a chain with nothing to report.
          sawUnreadable := false
          goLive()
          onHeight(height)
        },
      onUnreadable: () =>
        if isCurrent() {
          sawUnreadable := true
        },
      onFailure: (~reason) =>
        if isCurrent() {
          fail(~reason)
        },
    }

    // A transport constructor can throw on a malformed url. Left to escape it
    // would reach a timer callback on the next retry and take the process down.
    let closeCurrentConnection = try Some(connect(driver)) catch {
    | _ => None
    }

    switch closeCurrentConnection {
    | Some(closeCurrentConnection) =>
      if isCurrent() {
        closeConnectionRef := Some(closeCurrentConnection)
      } else {
        closeSafely(closeCurrentConnection)
      }
    | None =>
      if isCurrent() {
        fail(~reason="connect-failed")
      }
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
