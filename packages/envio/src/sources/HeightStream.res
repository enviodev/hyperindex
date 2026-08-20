/*
Reconnect driver shared by every height subscription transport. A transport
supplies `connect`, which wires its socket to the driver callbacks and returns a
close function; the driver owns retries, staleness detection and status
reporting so SSE and WebSocket streams behave identically.

Nothing here logs. A height stream failing is not something an operator has to
act on — the indexer polls for the height instead — so a failure travels out
through `onStatus`, where its reason becomes a metric label and its detail the
one log line that says what the provider actually sent.
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
  // useful, so a stream of them goes quiet and fails as "unreadable", carrying
  // the frame that started it.
  onUnreadable: (~detail: string) => unit,
  onFailure: (~reason: string, ~detail: string=?) => unit,
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
// Floor for how long a connection has to last to have been worth making. Both
// transports deliver something the moment they connect — HyperSync sends the
// head, a WebSocket confirms the subscription — so an endpoint that accepts and
// drops has produced everything a working one would have by then, and only
// staying open tells them apart.
let minProvenMillis = 1_000
// A frame nobody could read ends up in a log line, so cap what a provider can
// put there.
let maxDetailLength = 200

let truncateDetail = detail =>
  detail->String.length > maxDetailLength
    ? detail->String.slice(~start=0, ~end=maxDetailLength) ++ "…"
    : detail

let subscribe = (
  ~staleTimeout: int,
  ~onHeight: int => unit,
  ~onStatus: Source.heightSubscriptionStatus => unit,
  // Must not allocate anything it can then throw past: a throw leaves the driver
  // without the close function, so only the transport can release what it took.
  ~connect: driver => unit => unit,
): (unit => unit) => {
  let closeConnectionRef = ref(None)
  let failureCount = ref(0)
  // Bumped on every failure, reconnect and unsubscribe. Callbacks from a
  // superseded connection compare against it and no-op, so a socket that
  // reports an error and then a close only counts as one failure, and nothing a
  // connection reports after unsubscribing is heard.
  let generation = ref(0)
  // A connection is either waiting for traffic or waiting to be retried, never
  // both, so a single slot holds whichever timer is pending.
  let timeoutId = ref(None)
  // The frame that stopped this connection being readable, kept for the failure
  // it will eventually be named after.
  let unreadableDetail = ref(None)
  // How long the current connection has to last to count as worth making: the
  // wait it cost us, floored. Measuring the connection against the wait before
  // it is what a provider rotating connections clears and an endpoint that
  // drops immediately can't, and it needs no clock of its own — the bar rises
  // with the backoff, so an endpoint that always dies at the same age keeps
  // escalating instead of settling into a reconnect loop at a fixed delay.
  let provenMillis = ref(minProvenMillis)
  let connectedAt = ref(Performance.now())

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
          switch unreadableDetail.contents {
          | Some(detail) => fail(~reason="unreadable", ~detail)
          | None => fail(~reason="stale")
          }
        }, staleTimeout))
  }
  and fail = (~reason, ~detail=?) => {
    generation := generation.contents + 1
    clearPendingTimeout()
    closeConnection()

    // A connection that outlived the wait before it was worth making, whatever
    // ended it, so the backoff starts over. That covers a load balancer
    // rotating connections and a chain whose blocks are further apart than the
    // stale timeout alike, without either having to be recognised.
    let uptimeMillis = (Performance.now() -. connectedAt.contents)->Float.toInt
    failureCount := if uptimeMillis >= provenMillis.contents {
        1
      } else {
        failureCount.contents + 1
      }

    let exp = Pervasives.min(failureCount.contents - 1, maxRetryExponent)->Int.toFloat
    let retryMillis = Pervasives.min(
      baseRetryMillis * Math.pow(2.0, ~exp)->Float.toInt,
      maxRetryMillis,
    )
    provenMillis := Pervasives.max(retryMillis, minProvenMillis)

    // Scheduled before reporting, so a consumer that throws can't be what makes
    // the stream give up.
    timeoutId := Some(setTimeout(() => {
          timeoutId := None
          start()
        }, retryMillis))

    onStatus(Down({reason, ?detail}))
  }
  and start = () => {
    generation := generation.contents + 1
    unreadableDetail := None
    connectedAt := Performance.now()
    let connectionGeneration = generation.contents
    let isCurrent = () => generation.contents === connectionGeneration

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
        // Stops counting once anything unreadable has arrived, on the first one
        // rather than on some run of them: a stream whose heights are all
        // malformed is indistinguishable from one that has sent a single
        // garbled frame until a readable height arrives, and the keep-alives
        // between malformed heights would otherwise hold the connection open
        // indefinitely, never failing and so never reporting anything, while
        // its consumer sat on the staleness backstop. Being wrong about a lone
        // glitch costs one reconnect.
        if isCurrent() && unreadableDetail.contents->Option.isNone {
          armStaleTimeout()
        },
      onHeight: height =>
        if isCurrent() {
          // A height we could read proves the shape is fine again. A keep-alive
          // deliberately doesn't: on a stream whose heights are all malformed,
          // the pings between them would clear this and the staleness that
          // followed would look like a chain with nothing to report.
          unreadableDetail := None
          goLive()
          onHeight(height)
        },
      onUnreadable: (~detail) =>
        if isCurrent() {
          unreadableDetail := Some(detail->truncateDetail)
        },
      onFailure: (~reason, ~detail=?) =>
        if isCurrent() {
          fail(~reason, ~detail?)
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
    generation := generation.contents + 1
    clearPendingTimeout()
    closeConnection()
  }
}
