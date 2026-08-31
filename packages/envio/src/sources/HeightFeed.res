/*
The current height of one source, however it arrives: pushed by a height stream
while one is connected, polled while one isn't. Callers register interest and get
called back; they never learn which path answered.

A waiter that loses a race has to be removed, and a promise reaction cannot be.
*/

type waiter = {
  // The height this waiter has to beat.
  knownHeight: int,
  onHeight: int => unit,
  // How fast to poll while nothing is pushing. Read per poll rather than fixed
  // here, so a wait that goes on to stall slows itself down without restarting
  // anything.
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
  // Whether an operator has been told once that this source's stream sends
  // something this cannot read. The condition repeats every staleness window.
  mutable unreadableWarned: bool,
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
  unreadableWarned: false,
}

type streamSample = {connectCount: int, disconnects: array<(string, int)>}

let knownHeight = (feed: t) => feed.knownHeight

// None for a source that cannot subscribe at all, so a chain that only ever
// polls renders none of the height stream families rather than sitting at zero
// on them.
let sample = (feed: t): option<streamSample> =>
  switch feed.source.createHeightSubscription {
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
  }

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

// Takes back every waiter's complaint that its stream had gone silent. The
// reason differs at each call site; the effect is always that polling alongside
// the stream is no longer owed.
let clearPokes = (feed: t) => feed.waiters->Array.forEach(waiter => waiter.poked = false)

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

// The shortest cadence any waiter asked for. Waits overlap on one source after a
// rollback, and a wait that only needs a slow poll must not stretch the one a
// faster wait is sitting on.
let currentInterval = (feed: t) =>
  feed.waiters
  ->Array.reduce(None, (shortest, waiter) =>
    Utils.Math.minOptInt(shortest, Some(waiter.interval()))
  )
  ->Option.getOr(feed.source.pollingInterval)

// What an answer means for the feed, whoever asked for it: the endpoint
// responded, and it responded with the head.
let recordAnswer = (feed: t, ~generation, res: Source.getHeightResponse) => {
  feed.recordRequestStats(res.requestStats)
  feed.pollRetry = 0

  // Fetching the head is the whole job a connect's catch-up exists to do, so any
  // answer closes that gap too — as long as it was asked for the connection
  // still in place. Without this a stream whose delivery lags the polling
  // interval would never clear the flag: the poll would reach each head first,
  // and the push behind it would arrive already known. A catch-up that lands
  // after its connection was replaced would otherwise retire the polling
  // covering a replacement that has delivered nothing.
  if generation === feed.connectionGeneration {
    feed.connectionUnproven = false
  }
  // Deliberately does not take back a poke, however quiet the answer is. A poll
  // agreeing with the stream at one instant says nothing about whether the
  // stream would have delivered the next block, and that is the only thing the
  // poke ever doubted — only the stream itself delivering settles it.
  feed->recordHeight(res.height)
  // Answering may have been the last of the loop's reasons to run. Costs nothing
  // when the loop itself is the caller: it only sleeps after this returns.
  feed->wakeIfIdle
}

// A source that has not answered in this long is not going to. One loop covers
// the feed, and it waits on one request at a time, so an unbounded call — a
// source with no timeout of its own, or a socket that died without saying so —
// would stop the height moving for the rest of the process rather than for one
// poll. Far longer than any healthy getHeight, so a merely slow endpoint answers
// first and nothing here fires in normal running.
let pollTimeoutMillis = 60_000

// What a bound request fails with when the bound is what ended it rather than
// the endpoint, so the one catch a caller needs can still say which happened.
let timedOut = () =>
  JsError.make(`Did not answer within ${(pollTimeoutMillis / 1000)->Int.toString}s.`)->(
    Utils.magic: JsError.t => exn
  )

// Bounds the wait on a height request, not the request itself. Whatever the
// endpoint eventually answers is recorded — it did answer, and a source that
// consistently answers just past the bound would otherwise never move the height
// at all — while the caller is released at the bound to back off and ask again.
let heightWithin = async (feed: t, ~generation) => {
  let timeoutId = ref(None)
  let abandoned = ref(false)
  let request = feed.source.getHeightOrThrow()

  // Registered before the race below, so on the path where the answer arrives in
  // time this has already declined it and the caller records it, in the caller's
  // own turn. Only an answer its caller has given up on is recorded here.
  request
  ->Promise.thenResolve(res =>
    if abandoned.contents {
      feed->recordAnswer(~generation, res)
    }
  )
  // A rejection this late is one the caller was already told about, or one it
  // stopped waiting for. Either way it is accounted for; left unhandled it would
  // be an unhandled rejection.
  ->Promise.catch(_ => Promise.resolve())
  ->Promise.ignore

  let answered = try await Promise.race([
    request->Promise.thenResolve(res => Some(res)),
    Promise.make((resolve, _reject) => {
      timeoutId := Some(setTimeout(() => {
            // Set here rather than after the race resolves, so it is already
            // true for a handler that runs in this same turn: an answer landing
            // alongside the timeout would otherwise be declined by the handler
            // and thrown away by the caller alike.
            abandoned := true
            resolve(None)
          }, pollTimeoutMillis))
    }),
  ]) catch {
  | exn =>
    timeoutId->Utils.clearTimeoutRef
    throw(exn)
  }
  timeoutId->Utils.clearTimeoutRef
  switch answered {
  | Some(res) => res
  | None => throw(timedOut())
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
    let res = await feed->heightWithin(~generation)
    feed->recordAnswer(~generation, res)
    feed->currentInterval
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
  // Nothing inside is meant to throw — a poll's failure is a value, and a
  // waiter's is caught where it fires — but the flag has to come back down
  // whatever happens. Left up it says a loop is running when none is, and this
  // source is never polled again.
  try {
    while feed->shouldPoll {
      let interval = await feed->pollOnce
      if feed->shouldPoll {
        await feed->sleep(interval)
      }
    }
  } catch {
  | exn =>
    feed.logger->Logging.childError({
      "msg": "The height poll loop threw. Stopping it rather than leaving the source looking covered.",
      "err": exn->Utils.prettifyExn,
    })
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
// in. Only a connection that was delivering can be lost, which is what
// `markStreamDown` checks before reaching here.
let recordDisconnect = (feed: t, ~reason) => feed.disconnects->Utils.Dict.incrementBy(reason, 1)

// One poll on every connect, closing the gap left by heights emitted before this
// connection existed: eth_subscribe only ever delivers the *next* block. The one
// request this module makes with nobody waiting — a chain that reconnects while
// idle would otherwise sit on a stale head until the next block is mined.
let catchUp = async (feed: t, ~generation) =>
  try {
    let res = await feed->heightWithin(~generation)
    feed->recordAnswer(~generation, res)
  } catch {
  | exn =>
    // Deliberately leaves the stream unproven, and deliberately does not advance
    // the poll ramp: nothing else is fetching the height, so the loop has to
    // keep covering it, and it is running alongside this against the same
    // endpoint. Two failures in one round is still one round. Wake a loop that
    // is sleeping off that ramp, otherwise the remainder of the backoff is a
    // coverage gap the catch-up was meant to close.
    feed.logger->Logging.childTrace({
      "msg": `Height stream catch-up from ${feed.source.name} source failed. Polling continues until the stream delivers.`,
      "err": exn->Utils.prettifyExn,
    })
    feed->wake
    feed->startPolling
  }

let handlePushedHeight = (feed: t, height) => {
  let advances = height > feed.knownHeight
  feed.recordRequestStats([
    {Source.method: advances ? "heightPush" : "heightPushIgnored", seconds: 0.},
  ])

  // A height that advances accounts for the gap a connect leaves. One that does
  // not is the head a stream re-emits on reconnect, which its catch-up is
  // already fetching — but either way it is the stream delivering, which is all
  // the silence behind a poke ever claimed otherwise.
  feed.pollRetry = 0
  if advances {
    feed.connectionUnproven = false
  }
  feed->clearPokes
  feed->recordHeight(height)
  feed->wakeIfIdle
}

// Everything a connection going away means for the feed. The stream reporting
// it and this module closing it leave the same state behind, so they share it:
// nothing is pushing, nothing is proven, and what the waiters concluded about
// the connection that is gone says nothing about the one that replaces it.
let markStreamDown = (feed: t, ~reason) => {
  // A stream that is down stays down through every failed retry, and each of
  // those reports Down again. Counting them would make the total measure how
  // long an outage lasted rather than how many there were, and would leave a
  // stream that has never connected disconnecting without ever connecting.
  let lostConnection = feed.streamLive
  if lostConnection {
    feed->recordDisconnect(~reason)
  }
  feed.streamLive = false
  feed.connectionUnproven = false
  // The connection they gave up on is gone; the one that replaces it starts with
  // a catch-up of its own to prove it.
  feed->clearPokes
  feed.connectionGeneration = feed.connectionGeneration + 1

  // A loop already running may be sleeping off an interval chosen while that
  // connection was still covering this source. Not while polls are failing,
  // though: that sleep is the backoff a struggling endpoint earned, and the
  // stream dropping is usually the same endpoint's doing.
  if lostConnection && feed.pollRetry === 0 {
    feed->wake
  }
  feed->startPolling
}

let handleStatus = (feed: t, status: Source.heightSubscriptionStatus) =>
  switch status {
  | Live =>
    if !feed.streamLive {
      feed.streamLive = true
      feed.connectionGeneration = feed.connectionGeneration + 1
      feed.connects = feed.connects + 1
      feed.pollRetry = 0

      // Live is a claim, not a delivery: polling keeps covering the source until
      // the catch-up lands or a height arrives.
      feed.connectionUnproven = true
      // Whoever was waiting is already being polled for — the loop cannot have
      // stopped while a waiter sat behind a stream that was not live — so the
      // catch-up is all this moment adds. It stays a request of its own rather
      // than a wake of that loop: proving a connection and backing off a failing
      // endpoint are different jobs, and running this one through the poll ramp
      // would let a flapping stream ratchet up the polling behind it.
      feed->catchUp(~generation=feed.connectionGeneration)->Promise.ignore
    }
  | Down({reason} as down) =>
    feed->markStreamDown(~reason)

    // The counters say a stream is flapping and how often, but only the
    // provider's own words say why, and a frame nobody could read is
    // unrecoverable from a bucketed label. An outage is the indexer's to absorb
    // — it polls instead — but a provider sending heights in a shape this does
    // not parse never heals on its own, and silently polling forever against a
    // stream that could be working is worth one line an operator can see. Once:
    // it repeats every staleness window for as long as the shape is wrong.
    let log = if reason === Source.unreadableReason && !feed.unreadableWarned {
      feed.unreadableWarned = true
      Logging.childWarn
    } else {
      Logging.childTrace
    }
    feed.logger->log({
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

    // Counted as a disconnect like any other: leaving it out would leave the
    // source reporting one more connect than disconnects — a stream still
    // delivering — for the rest of the process. Being benched is a capability
    // verdict, not an outage, so whoever is still waiting keeps being polled
    // for: the source can still answer a height poll, and until another source
    // answers the wait it is what there is.
    feed->markStreamDown(~reason=Source.unsubscribedReason)
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
    // Both self-guarding, and between them they cover either state: a loop
    // sleeping off an interval started for someone else ends it here rather than
    // making this waiter sit out the remainder, and no loop at all starts one.
    feed->wake
    feed->startPolling
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
