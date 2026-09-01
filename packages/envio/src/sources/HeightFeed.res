/*
The current height of one source, however it arrives: pushed by a height stream
while one is connected, polled while one isn't. Callers register interest and get
called back; they never learn which path answered.

One invariant carries the module: while anybody is waiting, either a stream
connection this has seen deliver is covering the source, or the poll loop is
running. `shouldPoll` states it, and `syncPolling` is the only thing that acts on
it, so no caller has to work out which of its changes needs a loop started.

A waiter that loses a race has to be removed, and a promise reaction cannot be.
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
  mutable distrustsStream: bool,
}

// What a waiter's own wait can do to it afterwards. Both are inert once the
// waiter is gone, which is what makes them safe to hold past the answer.
type subscription = {
  unsubscribe: unit => unit,
  // Stop taking a connected stream's word for it and poll alongside it until it
  // delivers something. A transport that keeps its keep-alives flowing while its
  // heights stop is the one failure its own staleness detector cannot see.
  distrustStream: unit => unit,
}

// What this feed knows about its source's height stream. `Connected` is the
// transport's claim; `proven` is this module having seen that connection account
// for the head it came up on. A connect only ever delivers the *next* block, so
// until a height arrives on it, or a request made after it came up answers, the
// head it connected above is unaccounted for and polling has to stay.
type streamState =
  // Never asked for — the source cannot push heights, or its chain has not
  // reached realtime yet. Nothing about it is worth reporting, because nothing
  // about it is failing.
  | NeverEnabled
  | Disconnected
  | Connected({proven: bool})

// Why the poll loop is sleeping, which is what decides whether anything may cut
// the sleep short. A cadence is a choice about how often to ask a working
// endpoint, so anything that needs an answer sooner is free to end it. A backoff
// is the wait a failing endpoint earned, and ending it early is how a provider
// already in trouble gets asked harder by the very events its trouble causes —
// its own stream dropping, most of all.
type pollSleep = Cadence | Backoff

// Mutable because a sleep can stop being a backoff while it is being slept: the
// endpoint answering is what the wait was ever about, and it can answer through
// the stream rather than through the poll the loop is backing off from.
type sleeping = {mutable kind: pollSleep, wake: unit => unit}

type pollOutcome =
  | Answered(Source.getHeightResponse)
  | Failed(exn)
  // The source did not answer inside the window. One loop covers this feed and
  // it waits on one request at a time, so a call that never settles would stop
  // the height moving for the rest of the process rather than for one poll.
  | TimedOut

type t = {
  source: Source.t,
  logger: Pino.t,
  recordRequestStats: array<Source.requestStat> => unit,
  getHeightRetryInterval: (~retry: int) => int,
  mutable knownHeight: int,
  mutable waiters: array<waiter>,
  mutable stream: streamState,
  // Bumped whenever the stream changes hands. A height request made for one
  // connection can land after another has replaced it, and what it said about
  // the connection that asked is no longer about the one in place.
  mutable generation: int,
  mutable closeStream: option<unit => unit>,
  mutable polling: bool,
  mutable sleeping: option<sleeping>,
  // Outlives a single wait on purpose. Waits come and go once a block, and
  // restarting the ramp with each one would keep an endpoint that fails every
  // time pinned near the base delay forever. A poll that answers clears it.
  mutable pollRetry: int,
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
  stream: NeverEnabled,
  generation: 0,
  closeStream: None,
  polling: false,
  sleeping: None,
  pollRetry: 0,
  connects: 0,
  disconnects: Dict.make(),
  stopped: false,
  unreadableWarned: false,
}

type streamSample = {connectCount: int, disconnectsByReason: array<(string, int)>}

let knownHeight = (feed: t) => feed.knownHeight

// None until this feed has asked for a stream, so a chain that only ever polls —
// because its source cannot subscribe, or because it is still backfilling and
// nothing has wanted a stream yet — renders none of the height stream families
// rather than sitting at a flat zero on them, which reads as a stream that
// cannot connect. Once asked for, a stream that never came up is exactly what
// these counters are for.
let sample = (feed: t): option<streamSample> =>
  switch feed.stream {
  | NeverEnabled => None
  | Disconnected | Connected(_) =>
    Some({
      connectCount: feed.connects,
      // Sorted so the rendered order doesn't depend on which reasons a stream
      // happened to hit in which order.
      disconnectsByReason: feed.disconnects
      ->Dict.toArray
      ->Array.toSorted(((a, _), (b, _)) => String.compare(a, b)),
    })
  }

// What this feed owes, in one place. Everything else here exists to keep it true.
let shouldPoll = (feed: t) =>
  feed.waiters->Array.length > 0 &&
    switch feed.stream {
    | NeverEnabled | Disconnected => true
    | Connected({proven}) => !proven || feed.waiters->Array.some(waiter => waiter.distrustsStream)
    }

// Ends a sleep that is only a cadence, and leaves a backoff alone. Safe to call
// from anywhere, including from things that have just made the loop's job
// smaller: the loop re-reads `shouldPoll` when it wakes and stops if there is
// nothing left to do.
let wakeCadence = (feed: t) =>
  switch feed.sleeping {
  | Some({kind: Cadence, wake}) => wake()
  | Some({kind: Backoff}) | None => ()
  }

// The source answered, so the wait its failures earned is no longer owed —
// including one already being slept. Without this a source that recovers through
// its stream, and then loses the stream again, would sit out the rest of a
// backoff earned before any of that, with nothing covering it.
let clearBackoff = (feed: t) => {
  feed.pollRetry = 0
  switch feed.sleeping {
  | Some(sleeping) => sleeping.kind = Cadence
  | None => ()
  }
}

// Collect before firing: a callback is free to cancel waiters — the wait above
// cancels all of its own the moment one answers — and iterating the live array
// while it changes underneath is how that goes wrong.
let fireWaiters = (feed: t, height) => {
  let isSatisfied = (waiter: waiter) => height > waiter.knownHeight
  let satisfied = feed.waiters->Array.filter(isSatisfied)
  if satisfied->Array.length > 0 {
    feed.waiters = feed.waiters->Array.filter(waiter => !isSatisfied(waiter))
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
    feed->wakeCadence
  }
}

let recordHeight = (feed: t, height) =>
  if height > feed.knownHeight {
    feed.knownHeight = height
    feed->fireWaiters(height)
  }

// What an answer means for the feed, whoever asked for it. The poll loop and a
// connect's catch-up both reach this, and an answer is worth the same from
// either: the endpoint responded, and it responded with the head.
let recordAnswer = (feed: t, ~generation, res: Source.getHeightResponse) => {
  feed.recordRequestStats(res.requestStats)
  feed->clearBackoff
  // Fetching the head is the whole job a connect's catch-up exists to do, so any
  // answer closes that gap too — as long as it was asked for after the
  // connection in place came up. A request older than the connection saw a head
  // from before it existed, and a catch-up that lands after its own connection
  // was replaced would otherwise retire the polling covering a replacement that
  // has delivered nothing.
  switch feed.stream {
  | Connected(_) if generation === feed.generation => feed.stream = Connected({proven: true})
  | _ => ()
  }
  feed->recordHeight(res.height)
  // Answering may have been the last of the loop's reasons to run. Costs nothing
  // when the loop itself is the caller: it only sleeps after this returns.
  feed->wakeCadence
}

// An answer that arrived after the loop stopped waiting for it. The height is
// real and the request was paid for either way, so recording it saves asking
// again for something already known — but it does not clear the retry ramp the
// way a timely answer does, because taking longer than the whole timeout is the
// endpoint being unwell rather than well.
let recordLateAnswer = (feed: t, res: Source.getHeightResponse) => {
  feed.recordRequestStats(res.requestStats)
  feed->recordHeight(res.height)
}

// A source that has not answered in this long is not going to. Far longer than
// any healthy getHeight, so a merely slow endpoint answers first and nothing
// here fires in normal running.
let pollTimeoutMillis = 60_000

// One height request, with a bound on how long the caller waits for it. The
// request itself is not cancelled and a late answer is not thrown away: it is
// still the head the endpoint had. Only the waiting is bounded, so an endpoint
// that never settles costs one request rather than the loop waiting on it — or,
// on the catch-up path that nothing waits on, a promise per connect that is
// never released.
let heightWithin = (feed: t, ~millis): promise<pollOutcome> => {
  let timeoutId = ref(None)
  let timedOut = ref(false)
  let request = feed.source.getHeightOrThrow()

  request
  ->Promise.thenResolve(res =>
    if timedOut.contents {
      feed->recordLateAnswer(res)
    }
  )
  ->Promise.catch(_ => Promise.resolve())
  ->Promise.ignore

  Promise.race([
    request
    ->Promise.thenResolve(res => Answered(res))
    ->Promise.catch(exn => Promise.resolve(Failed(exn))),
    Promise.make((resolve, _reject) => timeoutId := Some(setTimeout(() => {
            timedOut := true
            resolve(TimedOut)
          }, millis))),
  ])->Promise.thenResolve(outcome => {
    switch timeoutId.contents {
    | Some(id) => clearTimeout(id)
    | None => ()
    }
    outcome
  })
}

let sleep = (feed: t, ~kind, millis) =>
  Promise.make((resolve, _reject) => {
    let timeoutId = setTimeout(() => {
      feed.sleeping = None
      resolve()
    }, millis)
    feed.sleeping = Some({
      kind,
      wake: () => {
        clearTimeout(timeoutId)
        feed.sleeping = None
        resolve()
      },
    })
  })

let currentInterval = (feed: t) =>
  switch feed.waiters->Array.get(feed.waiters->Array.length - 1) {
  | Some(waiter) => waiter.interval()
  | None => feed.source.pollingInterval
  }

let nextRetryInterval = (feed: t) => {
  let retryInterval = feed.getHeightRetryInterval(~retry=feed.pollRetry)
  feed.pollRetry = feed.pollRetry + 1
  retryInterval
}

// One poll, and what the loop should wait before the next: the source's own
// cadence after an answer, or the escalating backoff a failing endpoint earns.
// It is usually the same endpoint whose stream just dropped, so asking again at
// the polling interval would lean on something already in trouble.
let pollOnce = async (feed: t) => {
  let generation = feed.generation
  switch await feed->heightWithin(~millis=pollTimeoutMillis) {
  | Answered(res) =>
    feed->recordAnswer(~generation, res)
    (feed->currentInterval, Cadence)
  | TimedOut =>
    let retryInterval = feed->nextRetryInterval
    feed.logger->Logging.childTrace({
      "msg": `Height retrieval from ${feed.source.name} source did not answer within ${(pollTimeoutMillis / 1000)
          ->Int.toString}s. Retrying in ${retryInterval->Int.toString}ms.`,
    })
    (retryInterval, Backoff)
  | Failed(exn) =>
    let retryInterval = feed->nextRetryInterval
    feed.logger->Logging.childTrace({
      "msg": `Height retrieval from ${feed.source.name} source failed. Retrying in ${retryInterval->Int.toString}ms.`,
      "err": exn->Utils.prettifyExn,
    })
    (retryInterval, Backoff)
  }
}

let runPollLoop = async (feed: t) => {
  while feed->shouldPoll {
    // A poll cannot end the loop: its failure is a value, and a waiter's is
    // caught where it fires. Anything else in here throwing would leave coverage
    // owed with nothing providing it — the one state this module must never be
    // in — so the loop keeps that promise itself rather than trusting everything
    // it calls to be total.
    let (interval, kind) = try await feed->pollOnce catch {
    | exn =>
      feed.logger->Logging.childError({
        "msg": "The height poll cycle threw. Backing off and carrying on rather than leaving the source uncovered.",
        "err": exn->Utils.prettifyExn,
      })
      (feed->nextRetryInterval, Backoff)
    }
    if feed->shouldPoll {
      await feed->sleep(~kind, interval)
    }
  }
  feed.polling = false
}

// The only thing that acts on `shouldPoll`. Everything that changes what this
// feed owes ends here, so no caller has to know which changes need a loop
// started, which need a sleep chosen before them cut short, and which need
// neither.
let syncPolling = (feed: t) =>
  if feed->shouldPoll && !feed.polling {
    feed.polling = true
    feed->runPollLoop->Promise.ignore
  } else {
    // Either there is now less to do and the loop should notice, or there is
    // more and it should stop sleeping through it.
    feed->wakeCadence
  }

// The one height request this module makes with nobody waiting for it, closing
// the gap left by heights emitted before this connection existed. A chain that
// reconnects while idle would otherwise sit on a stale head until the next block
// is mined. With a waiter there is a loop doing this already, and asking twice
// does not make the endpoint answer sooner.
let catchUpWhileIdle = async (feed: t) => {
  let generation = feed.generation
  switch await feed->heightWithin(~millis=pollTimeoutMillis) {
  | Answered(res) => feed->recordAnswer(~generation, res)
  // Nobody is waiting, so nothing is owed and there is nothing to retry: the
  // next wait polls on its own, and the next height the stream pushes lands
  // whatever happened here.
  | Failed(_) | TimedOut => ()
  }
}

let handlePushedHeight = (feed: t, height) => {
  let advances = height > feed.knownHeight
  feed.recordRequestStats([
    {Source.method: advances ? "heightPush" : "heightPushIgnored", seconds: 0.},
  ])

  // A height that advances accounts for the gap a connect leaves. One that does
  // not is the head a stream re-emits on reconnect — but either way it is the
  // stream delivering, which is all the silence behind a distrusting wait ever
  // claimed otherwise — and the source answering at all, which is what any
  // backoff beside it was waiting to find out.
  feed->clearBackoff
  switch feed.stream {
  | Connected(_) if advances => feed.stream = Connected({proven: true})
  | _ => ()
  }
  feed.waiters->Array.forEach(waiter => waiter.distrustsStream = false)
  feed->recordHeight(height)
  // Never more to do than before: a delivering stream only takes work away.
  feed->wakeCadence
}

// Everything a connection going away means for the feed. The stream reporting it
// and this module closing it leave the same state behind, so they share it:
// nothing is pushing, nothing is proven, and what the waiters concluded about
// the connection that is gone says nothing about the one that replaces it.
let markStreamDown = (feed: t, ~reason) => {
  switch feed.stream {
  // Only a connection that existed can be lost. A stream that is down stays down
  // through every failed retry, and each of those reports Down again; counting
  // them would make the total measure how long an outage lasted rather than how
  // many there were, and would leave a stream that has never connected
  // disconnecting without ever having connected.
  | Connected(_) => feed.disconnects->Utils.Dict.incrementBy(reason->Source.downReasonLabel, 1)
  | NeverEnabled | Disconnected => ()
  }
  feed.stream = Disconnected
  feed.generation = feed.generation + 1
  // The connection they gave up on is gone; the one that replaces it starts with
  // a head of its own to account for.
  feed.waiters->Array.forEach(waiter => waiter.distrustsStream = false)
  feed->syncPolling
}

let handleStatus = (feed: t, status: Source.heightSubscriptionStatus) =>
  switch status {
  | Live =>
    switch feed.stream {
    // A transport re-reporting a connection this already has.
    | Connected(_) => ()
    | NeverEnabled | Disconnected =>
      feed.stream = Connected({proven: false})
      feed.generation = feed.generation + 1
      feed.connects = feed.connects + 1

      // Live is a claim, not a delivery: polling keeps covering the source until
      // the head this connection came up above is accounted for. A loop already
      // running is the thing that will account for it, and one sleeping off a
      // backoff stays asleep — the endpoint that just accepted a socket is the
      // one whose height calls are failing.
      feed->syncPolling
      if !feed.polling {
        feed->catchUpWhileIdle->Promise.ignore
      }
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
    let log = switch reason {
    | Unreadable if !feed.unreadableWarned =>
      feed.unreadableWarned = true
      Logging.childWarn
    | _ => Logging.childTrace
    }
    let label = reason->Source.downReasonLabel
    feed.logger->log({
      "msg": `Height subscription for ${feed.source.name} source went down (${label}). Polling for the height until it reconnects.`,
      "reason": label,
      "detail": down.detail,
    })
  }

// Explicit and lazy: the caller subscribes when it starts wanting heights in
// realtime, not when the feed is built. Idempotent, because after a rollback two
// waits run for the same source and both reach this — a second subscription
// would overwrite the first one's close function, leaving a socket nothing can
// close, still pushing heights and still retrying, for the life of the process.
let enableStream = (feed: t) =>
  switch (feed.source.createHeightSubscription, feed.closeStream) {
  | (Some(createSubscription), None) if !feed.stopped =>
    // Before connecting, so a transport that fails inside `createSubscription`
    // reports against a feed that already has a stream to report on.
    switch feed.stream {
    | NeverEnabled => feed.stream = Disconnected
    | Disconnected | Connected(_) => ()
    }
    feed.closeStream = Some(
      createSubscription(
        ~onHeight=height => feed->handlePushedHeight(height),
        ~onStatus=status => feed->handleStatus(status),
      ),
    )
  | _ => ()
  }

let stop = (feed: t) => {
  feed.stopped = true
  switch feed.closeStream {
  | Some(closeStream) =>
    closeStream()
    feed.closeStream = None

    // Counted as a disconnect like any other: leaving it out would leave the
    // source reporting one more connect than disconnects — a stream still
    // delivering — for the rest of the process. Being benched is a capability
    // verdict, not an outage, so whoever is still waiting keeps being polled
    // for: the source can still answer a height poll, and until another source
    // answers the wait it is what there is.
    feed->markStreamDown(~reason=Unsubscribed)
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
    {unsubscribe: () => (), distrustStream: () => ()}
  } else {
    let waiter = {knownHeight, onHeight, interval, distrustsStream: false}
    feed.waiters->Array.push(waiter)->ignore
    feed->syncPolling
    {
      unsubscribe: () => {
        // Removing by reference is what makes this idempotent, including from
        // inside onHeight where the waiter has already been taken out.
        feed.waiters = feed.waiters->Array.filter(w => w !== waiter)
        // The loop's reason to run may have just left with it.
        feed->wakeCadence
      },
      distrustStream: () =>
        switch feed.stream {
        | Connected(_) if !waiter.distrustsStream =>
          waiter.distrustsStream = true
          feed->syncPolling
        // Nothing to distrust, or already distrusted. A waiter that has been
        // answered is no longer in the list, so this does nothing for it either.
        | _ => ()
        },
    }
  }
