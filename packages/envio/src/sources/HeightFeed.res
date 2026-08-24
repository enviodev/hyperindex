/*
The current height of one source, however it arrives: pushed by a height stream
while one is connected, polled while one isn't. Callers register interest and get
called back; they never learn which path answered.

Callbacks rather than promises because this is subscription lifecycle. A waiter
that loses a race has to be *removed*, and a promise reaction cannot be — the
guards the wait loop used to carry (resolver arrays filtered after the fact, a
settled flag, counting catch-ups to retire a poll loop) were all working around
that. The transports and the HeightStream driver underneath are already
callback-based; the promise boundary is one level up, in
SourceManager.waitForNewBlock.
*/

type waiter = {
  // The height this waiter has to beat.
  knownHeight: int,
  onHeight: int => unit,
  // How fast to poll while nothing is pushing. The most recently registered
  // waiter's interval wins: only a wait superseded by a rollback overlaps with
  // another, and both want the same cadence anyway.
  interval: unit => int,
  // The wait this waiter belongs to sat out a whole window hearing nothing from
  // a stream that says it is connected. It belongs to the waiter rather than the
  // feed because two waits can overlap on one source after a rollback, and one
  // of them giving up on the stream is not the other one doing so.
  mutable poked: bool,
}

// What a waiter's own wait can do to it afterwards. Both are inert once the
// waiter is gone, which is what makes them safe to hold past the answer.
type subscription = {
  unsubscribe: unit => unit,
  poke: unit => unit,
}

type t = {
  source: Source.t,
  logger: Pino.t,
  recordRequestStats: array<Source.requestStat> => unit,
  getHeightRetryInterval: (~retry: int) => int,
  mutable knownHeight: int,
  mutable waiters: array<waiter>,
  mutable unsubscribe: option<unit => unit>,
  mutable streamLive: bool,
  // The stream connected but has not shown yet that it closed the gap the
  // connect left: a connect only ever delivers the *next* block, so until its
  // catch-up lands or a height arrives, the head it connected on is unaccounted
  // for.
  mutable connectionUnproven: bool,
  mutable polling: bool,
  // Ends the poll loop's sleep early, so a waiter arriving mid-interval doesn't
  // wait out a sleep that started for someone else.
  mutable wakePoll: option<unit => unit>,
  // Outlives a single wait on purpose. Waits come and go once a block, and
  // restarting the ramp with each one would keep an endpoint that fails every
  // time pinned near the base delay forever. A poll that answers clears it.
  mutable pollRetry: int,
  // Bumped whenever the connection in place changes hands. A request made for
  // one connection can land after another has replaced it, and what it says
  // about the connection that asked is no longer about the one in place.
  mutable connectionGeneration: int,
  mutable connects: int,
  disconnects: dict<int>,
  // A stopped feed never subscribes again: `stop` is the capability verdict that
  // benched its source.
  mutable stopped: bool,
}

let make = (~source: Source.t, ~recordRequestStats, ~getHeightRetryInterval): t => {
  source,
  logger: Logging.createChild(~params={"chainId": source.chainId, "source": source.name}),
  recordRequestStats,
  getHeightRetryInterval,
  knownHeight: 0,
  waiters: [],
  unsubscribe: None,
  streamLive: false,
  connectionUnproven: false,
  polling: false,
  wakePoll: None,
  pollRetry: 0,
  connectionGeneration: 0,
  connects: 0,
  disconnects: Dict.make(),
  stopped: false,
}

type streamSample = {connectCount: int, disconnects: array<(string, int)>}
type sample = {
  knownHeight: int,
  // None for a source that cannot subscribe at all, so a chain that only ever
  // polls renders none of the height stream families rather than sitting at
  // zero on them.
  stream: option<streamSample>,
}

let knownHeight = (feed: t) => feed.knownHeight

let sample = (feed: t): sample => {
  knownHeight: feed.knownHeight,
  stream: switch feed.source.createHeightSubscription {
  | Some(_) =>
    Some({
      connectCount: feed.connects,
      // Sorted because a dict orders integer-like keys (HTTP statuses) ahead of
      // the named reasons, which would make the rendered order depend on which
      // reasons a stream happened to hit.
      disconnects: feed.disconnects
      ->Dict.toArray
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
    })
  | None => None
  },
}

// The loop runs exactly while somebody is waiting and nothing is proving that
// the stream delivers.
let shouldPoll = (feed: t) =>
  feed.waiters->Array.length > 0 &&
    (!feed.streamLive ||
    feed.connectionUnproven ||
    feed.waiters->Array.some(waiter => waiter.poked))

let wake = (feed: t) =>
  switch feed.wakePoll {
  | Some(wakePoll) => wakePoll()
  | None => ()
  }

// The loop sleeps between polls, so anything that takes away its reason to run
// has to wake it. Left asleep it would hold `polling`, and the next thing that
// needs a poll — a stream dropping, a source being benched — would sit out an
// interval that was scheduled before any of it happened.
let wakeIfIdle = (feed: t) =>
  if !(feed->shouldPoll) {
    feed->wake
  }

// Collect before firing: a callback is free to cancel waiters — the wait above
// cancels all of its own the moment one answers — and iterating the live array
// while it changes underneath is how that goes wrong.
let fireWaiters = (feed: t, height) => {
  let satisfied = feed.waiters->Array.filter(waiter => height > waiter.knownHeight)
  if satisfied->Array.length > 0 {
    feed.waiters = feed.waiters->Array.filter(waiter => height <= waiter.knownHeight)
    satisfied->Array.forEach(waiter =>
      try waiter.onHeight(height) catch {
      | exn =>
        feed.logger->Logging.childError({
          "msg": "A height waiter threw. Dropping it rather than losing the height for the others.",
          "err": exn->Utils.prettifyExn,
        })
      }
    )
    // Answering the last waiter is one of the ways the loop stops being needed,
    // and the callbacks just run may have cancelled others.
    feed->wakeIfIdle
  }
}

let recordHeight = (feed: t, height) =>
  if height > feed.knownHeight {
    feed.knownHeight = height
    feed->fireWaiters(height)
  }

let sleep = (feed: t, millis) =>
  Promise.make((resolve, _reject) => {
    let timeoutId = setTimeout(() => {
      feed.wakePoll = None
      resolve()
    }, millis)
    feed.wakePoll = Some(
      () => {
        clearTimeout(timeoutId)
        feed.wakePoll = None
        resolve()
      },
    )
  })

let currentInterval = (feed: t) =>
  switch feed.waiters->Array.get(feed.waiters->Array.length - 1) {
  | Some(waiter) => waiter.interval()
  | None => feed.source.pollingInterval
  }

// A source that has not answered in this long is not going to. One loop covers
// the feed, and it waits on one request at a time, so an unbounded call — a
// source with no timeout of its own, or a socket that died without saying so —
// would stop the height moving for the rest of the process rather than for one
// poll. Far longer than any healthy getHeight, so a merely slow endpoint answers
// first and nothing here fires in normal running.
let pollTimeoutMillis = 60_000

// Bounds a height request. A call that never settles then costs one request
// rather than the loop that is waiting on it, or — on the catch-up path, which
// nothing waits on — a promise per connect that is never released.
let heightWithin = async (feed: t, ~millis) => {
  let timeoutId = ref(None)
  let clearRequestTimeout = () =>
    switch timeoutId.contents {
    | Some(id) => clearTimeout(id)
    | None => ()
    }
  try {
    let answered = await Promise.race([
      feed.source.getHeightOrThrow()->Promise.thenResolve(res => Some(res)),
      Promise.make((resolve, _reject) => {
        timeoutId := Some(setTimeout(() => resolve(None), millis))
      }),
    ])
    clearRequestTimeout()
    answered
  } catch {
  | exn =>
    clearRequestTimeout()
    throw(exn)
  }
}

let nextRetryInterval = (feed: t) => {
  let retryInterval = feed.getHeightRetryInterval(~retry=feed.pollRetry)
  feed.pollRetry = feed.pollRetry + 1
  retryInterval
}

// One poll, with the escalating backoff a failing endpoint earns: it is usually
// the same endpoint whose stream just dropped, so asking again at the polling
// interval would lean on something already in trouble.
let pollOnce = async (feed: t) => {
  let generation = feed.connectionGeneration
  try {
    switch await feed->heightWithin(~millis=pollTimeoutMillis) {
    | None =>
      let retryInterval = feed->nextRetryInterval
      feed.logger->Logging.childTrace({
        "msg": `Height retrieval from ${feed.source.name} source did not answer within ${(pollTimeoutMillis /
            1000)->Int.toString}s. Retrying in ${retryInterval->Int.toString}ms.`,
      })
      retryInterval
    | Some(res) =>
      feed.recordRequestStats(res.requestStats)
      feed.pollRetry = 0
      // Fetching the head is the whole job a connect's catch-up exists to do, so
      // a poll that answers closes that gap too — as long as it was asked for
      // the connection still in place. Without this a stream whose delivery lags
      // the polling interval would never clear the flag: the poll would reach
      // each head first, and the push behind it would arrive already known.
      if generation === feed.connectionGeneration {
        feed.connectionUnproven = false
      }
      feed->recordHeight(res.height)
      feed->currentInterval
    }
  } catch {
  | exn =>
    let retryInterval = feed->nextRetryInterval
    feed.logger->Logging.childTrace({
      "msg": `Height retrieval from ${feed.source.name} source failed. Retrying in ${retryInterval->Int.toString}ms.`,
      "err": exn->Utils.prettifyExn,
    })
    retryInterval
  }
}

let runPollLoop = async (feed: t) => {
  while feed->shouldPoll {
    let interval = await feed->pollOnce
    if feed->shouldPoll {
      await feed->sleep(interval)
    }
  }
  feed.polling = false
}

let startPolling = (feed: t) =>
  if feed->shouldPoll && !feed.polling {
    feed.polling = true
    feed->runPollLoop->Promise.ignore
  }

// Counted per reason so envio_source_height_stream_disconnects_total shows what
// ended each connection: a rotation, or the kind of trouble a flapping stream is
// in. Only a connection that was delivering can be lost, so every caller checks
// that first.
let recordDisconnect = (feed: t, ~reason) =>
  feed.disconnects->Dict.set(
    reason,
    switch feed.disconnects->Utils.Dict.dangerouslyGetNonOption(reason) {
    | Some(count) => count + 1
    | None => 1
    },
  )

// One poll on every connect, closing the gap left by heights emitted before this
// connection existed: eth_subscribe only ever delivers the *next* block. The one
// request this module makes with nobody waiting — a chain that reconnects while
// idle would otherwise sit on a stale head until the next block is mined.
let catchUp = async (feed: t, ~generation) =>
  try {
    switch await feed->heightWithin(~millis=pollTimeoutMillis) {
    | None =>
      // Same as a failure: nothing else is fetching the height, so the poll loop
      // has to keep covering the connection this was meant to prove.
      feed.logger->Logging.childTrace({
        "msg": `Height stream catch-up from ${feed.source.name} source did not answer within ${(pollTimeoutMillis /
            1000)->Int.toString}s. Polling continues until the stream delivers.`,
      })
    | Some(res) =>
      feed.recordRequestStats(res.requestStats)
      // The endpoint answered, which is what the poll ramp measures — it makes
      // no difference which of the two asked.
      feed.pollRetry = 0
      // A height is a height whoever fetched it, so this counts either way.
      feed->recordHeight(res.height)

      // Only the connection that asked is proven by the answer. A catch-up that
      // lands after its connection was replaced would otherwise retire the
      // polling covering a replacement that has delivered nothing.
      if generation === feed.connectionGeneration {
        feed.connectionUnproven = false
        feed->wakeIfIdle
      }
    }
  } catch {
  | exn =>
    // Deliberately leaves the stream unproven: nothing else is fetching the
    // height, so the poll loop has to keep covering it.
    feed.logger->Logging.childTrace({
      "msg": `Height stream catch-up from ${feed.source.name} source failed. Polling continues until the stream delivers.`,
      "err": exn->Utils.prettifyExn,
    })
  }

let handlePushedHeight = (feed: t, height) =>
  if height > feed.knownHeight {
    feed.recordRequestStats([{Source.method: "heightPush", seconds: 0.}])

    // A height that advances accounts for the gap a connect leaves as well as
    // showing the stream is delivering.
    feed.connectionUnproven = false
    feed.waiters->Array.forEach(waiter => waiter.poked = false)
    feed->recordHeight(height)
    feed->wakeIfIdle
  } else {
    feed.recordRequestStats([{Source.method: "heightPushIgnored", seconds: 0.}])
    // Not a height worth having — the head a stream re-emits on reconnect is
    // what its catch-up is already fetching — but it is the stream delivering,
    // which is all the silence behind a poke ever claimed otherwise.
    feed.waiters->Array.forEach(waiter => waiter.poked = false)
    feed->wakeIfIdle
  }

let handleStatus = (feed: t, status: Source.heightSubscriptionStatus) =>
  switch status {
  | Live =>
    if !feed.streamLive {
      feed.streamLive = true
      feed.connectionGeneration = feed.connectionGeneration + 1
      feed.connects = feed.connects + 1

      // Live is a claim, not a delivery: polling keeps covering the source until
      // the catch-up lands or a height arrives.
      feed.connectionUnproven = true
      // Whoever was waiting is already being polled for — the loop cannot have
      // stopped while a waiter sat behind a stream that was not live — so the
      // catch-up is all this moment adds.
      feed->catchUp(~generation=feed.connectionGeneration)->Promise.ignore
    }
  | Down({reason} as down) =>
    // A stream that is down stays down through every failed retry, and each of
    // those reports Down again. Counting them would make the total measure how
    // long an outage lasted rather than how many there were, and would leave a
    // stream that has never connected disconnecting without ever connecting.
    if feed.streamLive {
      feed->recordDisconnect(~reason)
    }
    feed.streamLive = false
    feed.connectionUnproven = false
    // The connection they gave up on is gone; the one that replaces it starts
    // with a catch-up of its own to prove it.
    feed.waiters->Array.forEach(waiter => waiter.poked = false)
    feed.connectionGeneration = feed.connectionGeneration + 1
    feed->startPolling
    // The counters say a stream is flapping and how often, but only the
    // provider's own words say why, and a frame nobody could read is
    // unrecoverable from a bucketed label.
    feed.logger->Logging.childTrace({
      "msg": `Height subscription for ${feed.source.name} source went down (${reason}). Polling for the height until it reconnects.`,
      "reason": reason,
      "detail": down.detail,
    })
  }

// Explicit and lazy: the caller subscribes when it starts wanting heights in
// realtime, not when the feed is built. Idempotent, because after a rollback two
// waits run for the same source and both reach this — a second subscription
// would overwrite the first one's close function, leaving a socket nothing can
// close, still pushing heights and still retrying, for the life of the process.
let enableStream = (feed: t) =>
  switch (feed.source.createHeightSubscription, feed.unsubscribe) {
  | (Some(createSubscription), None) if !feed.stopped =>
    feed.unsubscribe = Some(
      createSubscription(
        ~onHeight=height => feed->handlePushedHeight(height),
        ~onStatus=status => feed->handleStatus(status),
      ),
    )
  | _ => ()
  }

let stop = (feed: t) => {
  feed.stopped = true
  switch feed.unsubscribe {
  | Some(unsubscribe) =>
    unsubscribe()
    feed.unsubscribe = None

    // Closing a live connection is a disconnect like any other, and leaving it
    // uncounted would leave the source reporting one more connect than
    // disconnects — a stream still delivering — for the rest of the process.
    if feed.streamLive {
      feed->recordDisconnect(~reason="unsubscribed")
    }
    feed.streamLive = false
    feed.connectionUnproven = false
    feed.waiters->Array.forEach(waiter => waiter.poked = false)
    feed.connectionGeneration = feed.connectionGeneration + 1
    // Whoever is still waiting has nothing pushing for them now. Being benched
    // is a capability verdict, not an outage: the source can still answer a
    // height poll, and until another one answers the wait it is what there is.
    feed->startPolling
  | None => ()
  }
}

// Fires once, at the first height above `knownHeight`, from a push, a poll or a
// height another part of the indexer observed. What comes back acts on this
// waiter alone, and does nothing once it is gone.
let onHeightAbove = (feed: t, ~knownHeight, ~interval, ~onHeight): subscription =>
  if feed.knownHeight > knownHeight {
    // Already past it: a wait that starts after a query moved the head has
    // nothing to wait for.
    onHeight(feed.knownHeight)
    {unsubscribe: () => (), poke: () => ()}
  } else {
    let waiter = {knownHeight, onHeight, interval, poked: false}
    feed.waiters->Array.push(waiter)->ignore
    if feed.polling {
      // A loop is already running. If it is sleeping off an interval started for
      // someone else, this waiter should not have to sit out the remainder.
      feed->wake
    } else {
      feed->startPolling
    }
    {
      unsubscribe: () => {
        // Removing by reference is what makes this idempotent, including from
        // inside onHeight where the waiter has already been taken out.
        feed.waiters = feed.waiters->Array.filter(w => w !== waiter)
        // The loop's reason to run may have just left with it.
        feed->wakeIfIdle
      },
      // Its wait sat through a whole stall window without hearing from a stream
      // that claims to be connected. Poll alongside it until the stream shows
      // otherwise: a transport that keeps pinging while its heights stop is the
      // one failure its own staleness detector cannot see. A waiter already
      // answered is no longer in the list, so this does nothing for it.
      poke: () =>
        if feed.streamLive && !waiter.poked {
          waiter.poked = true
          feed->startPolling
        },
    }
  }
