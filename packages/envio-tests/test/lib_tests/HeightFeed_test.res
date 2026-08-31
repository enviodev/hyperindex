open Vitest

let makeFeed = (mock: MockSource.t, ~getHeightRetryInterval=(~retry as _) => 1_000) => {
  let stats = []
  let feed = HeightFeed.make(
    ~source=mock.source,
    ~recordRequestStats=requestStats =>
      requestStats->Array.forEach(stat => stats->Array.push(stat)->ignore),
    ~getHeightRetryInterval,
  )
  (feed, stats)
}

let watch = (feed, ~knownHeight, ~interval=() => 10) => {
  let heights = []
  let subscription =
    feed->HeightFeed.onHeightAbove(~knownHeight, ~interval, ~onHeight=height =>
      heights->Array.push(height)->ignore
    )
  (heights, subscription)
}

describe("HeightFeed answers a waiter", () => {
  Async.it("From a poll when nothing is pushing", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10)
    let (feed, _stats) = makeFeed(mock)
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)

    let pollsBeforeAnswer = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(0)

    t.expect((pollsBeforeAnswer, heights, feed->HeightFeed.knownHeight)).toStrictEqual((
      1,
      [101],
      101,
    ))
  })

  Async.it("From a pushed height, without polling for it", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval=10)
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    mock.setHeightSubscriptionStatus(Live)
    // The catch-up the connect fired, answered below the waiter's floor.
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)

    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)
    let pollsWhileLive = mock.getHeightOrThrowCalls->Array.length
    mock.triggerHeightSubscription(101)
    await Utils.delay(0)

    // A live stream that has proven itself carries the wait on its own.
    t.expect((pollsWhileLive, heights)).toStrictEqual((1, [101]))
  })

  Async.it("From a height another part of the indexer observed", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)

    // What a query response carries: a height for this source, learned without
    // asking for it.
    feed->HeightFeed.recordHeight(105)
    await Utils.delay(0)

    t.expect((heights, feed->HeightFeed.knownHeight)).toStrictEqual(([105], 105))
  })

  Async.it("Immediately when it already knows a higher height", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10)
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.recordHeight(105)

    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)

    // Synchronous, and without a poll: there is nothing to wait for.
    t.expect((heights, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual(([105], 0))
  })

  Async.it("Only the waiters whose floor the height clears", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let (below, _u1) = feed->watch(~knownHeight=100)
    let (above, _u2) = feed->watch(~knownHeight=110)

    feed->HeightFeed.recordHeight(105)
    await Utils.delay(0)

    t.expect((below, above)).toStrictEqual(([105], []))
  })
})

describe("HeightFeed polls only for someone", () => {
  Async.it("Does not poll at all until somebody waits", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=1)
    let (feed, _stats) = makeFeed(mock)

    await Utils.delay(20)
    let pollsWithoutWaiters = mock.getHeightOrThrowCalls->Array.length

    let (_heights, _unsubscribe) = feed->watch(~knownHeight=100)
    t.expect((pollsWithoutWaiters, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((0, 1))
  })

  Async.it("Stops polling when the last waiter leaves", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=5)
    let (feed, _stats) = makeFeed(mock)
    let (_heights, subscription) = feed->watch(~knownHeight=100, ~interval=() => 5)

    // A height that doesn't clear the floor, so the loop sleeps and comes back.
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(20)
    let pollsWhileWaiting = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(100)

    subscription.unsubscribe()
    await Utils.delay(30)

    t.expect((
      pollsWhileWaiting > 1,
      mock.getHeightOrThrowCalls->Array.length === pollsWhileWaiting,
    )).toStrictEqual((true, true))
  })

  Async.it("Catches up once on connect even with nobody waiting", async t => {
    let mock = MockSource.make([#getHeightOrThrow, #createHeightSubscription], ~pollingInterval=1)
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream

    mock.setHeightSubscriptionStatus(Live)
    let catchUpPolls = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(105)
    await Utils.delay(20)

    // The one request this module makes for nobody: eth_subscribe only ever
    // delivers the next block, so a head reached while idle is lost otherwise.
    t.expect((
      catchUpPolls,
      mock.getHeightOrThrowCalls->Array.length,
      feed->HeightFeed.knownHeight,
    )).toStrictEqual((1, 1, 105))
  })

  Async.it("Reuses a poll already in flight rather than stacking another", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let (first, firstSubscription) = feed->watch(~knownHeight=100)
    let pollsAfterFirst = mock.getHeightOrThrowCalls->Array.length
    firstSubscription.unsubscribe()

    // A second wait arrives while the request the first one triggered is still
    // out. Asking the same source twice would not make it answer sooner.
    let (second, _secondSubscription) = feed->watch(~knownHeight=100)
    let pollsAfterSecond = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(0)

    t.expect((pollsAfterFirst, pollsAfterSecond, first, second)).toStrictEqual((1, 1, [], [101]))
  })
})

describe("HeightFeed unsubscribe", () => {
  Async.it("Is idempotent, and silences the waiter", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let (heights, subscription) = feed->watch(~knownHeight=100)

    subscription.unsubscribe()
    subscription.unsubscribe()
    feed->HeightFeed.recordHeight(101)
    await Utils.delay(0)

    t.expect(heights).toStrictEqual([])
  })

  Async.it("Works from inside the callback it is unsubscribing", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let heights = []
    let unsubscribeRef = ref(() => ())
    let subscription = feed->HeightFeed.onHeightAbove(
      ~knownHeight=100,
      ~interval=() => 10,
      // The wait above does exactly this: the first height it hears cancels every
      // waiter it registered, including the one delivering it.
      ~onHeight=height => {
        heights->Array.push(height)->ignore
        unsubscribeRef.contents()
      },
    )
    unsubscribeRef := subscription.unsubscribe

    feed->HeightFeed.recordHeight(101)
    feed->HeightFeed.recordHeight(102)
    await Utils.delay(0)

    t.expect(heights).toStrictEqual([101])
  })

  Async.it("Keeps delivering to the others when one waiter throws", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let delivered = []
    let _throwing =
      feed->HeightFeed.onHeightAbove(
        ~knownHeight=100,
        ~interval=() => 10,
        ~onHeight=_ => JsError.throwWithMessage("waiter blew up"),
      )
    let _recording =
      feed->HeightFeed.onHeightAbove(
        ~knownHeight=100,
        ~interval=() => 10,
        ~onHeight=height => delivered->Array.push(height)->ignore,
      )

    feed->HeightFeed.recordHeight(101)
    await Utils.delay(0)

    t.expect(delivered).toStrictEqual([101])
  })
})

describe("HeightFeed stream state", () => {
  // Several tests below install fake timers inline. A throw between installing
  // and restoring them would otherwise leave the fake clock running for every
  // real-timer test after it, burying the original failure in timeouts. A no-op
  // where fake timers were never installed.
  afterEach(() => Vi.useRealTimers())

  Async.it("Polls alongside a live stream once poked, until a push proves it", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (heights, subscription) = feed->watch(~knownHeight=100)

    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    // Live and proven by its catch-up: nothing polls beside it.
    let pollsWhileProven = mock.getHeightOrThrowCalls->Array.length
    await Utils.delay(20)
    let pollsAfterWaiting = mock.getHeightOrThrowCalls->Array.length

    subscription.poke()
    let pollsAfterPoke = mock.getHeightOrThrowCalls->Array.length

    // A push that advances is the stream proving it carries heights again.
    mock.triggerHeightSubscription(101)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(20)

    t.expect((
      pollsWhileProven,
      pollsAfterWaiting,
      pollsAfterPoke,
      heights,
      mock.getHeightOrThrowCalls->Array.length,
    )).toStrictEqual((2, 2, 3, [101], 3))
  })

  Async.it("Takes a poke back on any push, even of a height it already knew", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (_heights, subscription) = feed->watch(~knownHeight=100)
    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)

    subscription.poke()
    let pollsAfterPoke = mock.getHeightOrThrowCalls->Array.length

    // The poll beat the stream to the head, so what the stream pushes next is a
    // height already known. It is still the stream delivering, which is all the
    // poke was ever complaining it did not do.
    mock.triggerHeightSubscription(100)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    subscription.unsubscribe()
    await Utils.delay(0)

    // Nothing for the next wait to inherit: the stream is live and delivering.
    let (_later, _unsubscribeLater) = feed->watch(~knownHeight=100)
    await Utils.delay(10)

    t.expect((pollsAfterPoke, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((3, 3))
  })

  Async.it("Lets a poll close the gap a failed catch-up left", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 1)
    feed->HeightFeed.enableStream
    let (_heights, subscription) = feed->watch(~knownHeight=100)

    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    // The catch-up fails, so nothing has accounted for the head this connection
    // came up on.
    mock.rejectGetHeightOrThrow(JsError.make("catch-up failed"))
    await Utils.delay(10)
    // A poll fetches exactly that head, which is the same gap closed by other
    // means.
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(10)
    let pollsOnceClosed = mock.getHeightOrThrowCalls->Array.length

    subscription.unsubscribe()
    await Utils.delay(0)
    let (_later, _unsubscribeLater) = feed->watch(~knownHeight=100)
    await Utils.delay(20)

    // Nothing left for the next wait to cover: the stream is live and the head
    // it connected on is accounted for.
    t.expect(mock.getHeightOrThrowCalls->Array.length).toEqual(pollsOnceClosed)
  })

  Async.it("Drops a poke when the wait that made it ends", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (_heights, subscription) = feed->watch(~knownHeight=100)
    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)

    subscription.poke()
    let pollsWhilePoked = mock.getHeightOrThrowCalls->Array.length

    // Answered by a height learned elsewhere — a query response, or a sibling
    // source settling the wait — so no push ever comes to take the poke back.
    feed->HeightFeed.recordHeight(101)
    await Utils.delay(0)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)

    // The complaint belonged to a wait that is over. The next one starts on a
    // stream that is live and delivering, and polls nothing.
    let (_later, _unsubscribeLater) = feed->watch(~knownHeight=101)
    await Utils.delay(10)

    t.expect((pollsWhilePoked, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((3, 3))
  })

  Async.it("Ignores a poke for a waiter that has already gone", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (_heights, subscription) = feed->watch(~knownHeight=100)
    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    subscription.unsubscribe()
    let pollsBefore = mock.getHeightOrThrowCalls->Array.length

    // Its wait is over, so there is nobody to poll for. Acting on it anyway
    // would leave the complaint for a later waiter to act on.
    subscription.poke()
    let (_later, _laterSubscription) = feed->watch(~knownHeight=100)
    await Utils.delay(10)

    t.expect((pollsBefore, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((2, 2))
  })

  Async.it("Ignores a push that does not clear the height it already knows", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)
    feed->HeightFeed.recordHeight(105)

    // The head a stream re-emits on every reconnect.
    mock.triggerHeightSubscription(105)
    await Utils.delay(0)

    t.expect((heights, stats->Array.map(stat => stat.method))).toStrictEqual((
      [105],
      ["heightPushIgnored"],
    ))
  })

  Async.it("Subscribes once however many waits ask it to, and never after stopping", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)

    feed->HeightFeed.enableStream
    feed->HeightFeed.enableStream
    let subscriptions = mock.heightSubscriptionCalls->Array.length

    mock.setHeightSubscriptionStatus(Live)
    feed->HeightFeed.stop
    feed->HeightFeed.stop
    feed->HeightFeed.enableStream

    t.expect((
      subscriptions,
      mock.heightSubscriptionCalls->Array.length,
      mock.heightSubscriptionCloseCalls->Array.length,
      feed->HeightFeed.sample,
    )).toStrictEqual((
      1,
      1,
      1,
      Some({
        HeightFeed.connectCount: 1,
        disconnects: [("unsubscribed", 1)],
      }),
    ))
  })

  Async.it("Falls back to polling for a waiter when the stream is stopped under it", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (_heights, _unsubscribe) = feed->watch(~knownHeight=100)

    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    let pollsWhileLive = mock.getHeightOrThrowCalls->Array.length

    feed->HeightFeed.stop

    // Being benched is a capability verdict, not an outage: the source can still
    // answer a height poll, and until another source answers it is what there is.
    t.expect((pollsWhileLive, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((2, 3))
  })

  Async.it("Polls straight away when a live connection drops mid-interval", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (_heights, subscription) = feed->watch(~knownHeight=100, ~interval=() => 10_000)

    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)

    // Poked, so a loop runs beside the live stream. Its poll answers below the
    // floor and it settles in for an interval chosen while that connection was
    // still the thing covering this source.
    subscription.poke()
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    let pollsWhileSleeping = mock.getHeightOrThrowCalls->Array.length

    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)

    t.expect((pollsWhileSleeping, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((3, 4))
  })

  Async.it("Sits out the backoff when the stream drops while polls are failing", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 10_000)
    feed->HeightFeed.enableStream
    let (_heights, _unsubscribe) = feed->watch(~knownHeight=100, ~interval=() => 10_000)

    mock.setHeightSubscriptionStatus(Live)
    // Both the catch-up and the loop's poll fail, so the loop is sleeping off
    // the backoff the endpoint earned rather than a polling interval.
    mock.rejectGetHeightOrThrow(JsError.make("down"))
    await Utils.delay(0)
    let pollsWhileBackingOff = mock.getHeightOrThrowCalls->Array.length

    // The stream dropping is usually the same endpoint's doing, so it is no
    // reason to ask again ahead of schedule.
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    await Utils.delay(0)

    t.expect((pollsWhileBackingOff, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual((2, 2))
  })

  Async.it("Keeps polling when a replaced connection's catch-up lands late", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 1)
    feed->HeightFeed.enableStream

    mock.setHeightSubscriptionStatus(Live)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    // The connection now in place, with a catch-up of its own outstanding.
    mock.setHeightSubscriptionStatus(Live)
    let (_heights, _unsubscribe) = feed->watch(~knownHeight=100, ~interval=() => 1)

    // The dropped connection's catch-up, answering after its replacement took
    // over. It says nothing about the head the connection in place came up on.
    mock.resolveGetHeightOrThrowAt(~index=0, 100)
    // Everything still outstanding fails, so nothing else accounts for that head
    // either: only a loop that is still running keeps issuing calls.
    mock.rejectGetHeightOrThrow(JsError.make("still down"))
    let pollsBefore = mock.getHeightOrThrowCalls->Array.length
    await Utils.delay(20)

    t.expect(mock.getHeightOrThrowCalls->Array.length > pollsBefore).toBe(true)
  })

  Async.it("Counts an outage once, however many retries fail inside it", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream

    // Never connected: the retries are attempts at a connection that never
    // existed, so there is nothing to have disconnected.
    mock.setHeightSubscriptionStatus(Down({reason: "connect-failed"}))
    mock.setHeightSubscriptionStatus(Down({reason: "connect-failed"}))
    let whileNeverConnected = feed->HeightFeed.sample

    mock.setHeightSubscriptionStatus(Live)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    mock.setHeightSubscriptionStatus(Down({reason: "connect-failed"}))

    t.expect((whileNeverConnected, feed->HeightFeed.sample)).toStrictEqual((
      Some({HeightFeed.connectCount: 0, disconnects: []}),
      Some({HeightFeed.connectCount: 1, disconnects: [("closed", 1)]}),
    ))
  })

  Async.it("Reports no stream at all for a source that cannot subscribe", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream

    t.expect((mock.heightSubscriptionCalls->Array.length, feed->HeightFeed.sample)).toStrictEqual((
      0,
      None,
    ))
  })
})

describe("HeightFeed poll failures", () => {
  // Several tests below install fake timers inline. A throw between installing
  // and restoring them would otherwise leave the fake clock running for every
  // real-timer test after it, burying the original failure in timeouts. A no-op
  // where fake timers were never installed.
  afterEach(() => Vi.useRealTimers())

  Async.it("Escalates the retry interval, and resets it after a success", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let retries = []
    let (feed, _stats) = makeFeed(
      mock,
      ~getHeightRetryInterval=(~retry) => {
        retries->Array.push(retry)->ignore
        1
      },
    )
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100, ~interval=() => 1)

    mock.rejectGetHeightOrThrow(JsError.make("no"))
    await Utils.delay(10)
    mock.rejectGetHeightOrThrow(JsError.make("no again"))
    await Utils.delay(10)
    let retriesBeforeSuccess = retries->Array.copy
    // A height that does not clear the floor still counts as the endpoint
    // answering, so the next failure starts the escalation over.
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(10)
    mock.rejectGetHeightOrThrow(JsError.make("and again"))
    await Utils.delay(10)

    t.expect((retriesBeforeSuccess, retries, heights)).toStrictEqual(([0, 1], [0, 1, 0], []))
  })

  Async.it("Gives up on a poll that never answers rather than waiting on it forever", async t => {
    Vi.useFakeTimers()
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 1)
    let (_heights, _subscription) = feed->watch(~knownHeight=100, ~interval=() => 1)
    // Answered by nothing, ever: a source with no timeout of its own, or a
    // socket that died without saying so. One loop covers this feed, so a call
    // it can never stop waiting on is one the source never gets polled again.
    let pollsBefore = mock.getHeightOrThrowCalls->Array.length

    await Vi.advanceTimersByTimeAsync(HeightFeed.pollTimeoutMillis + 100)
    let pollsAfter = mock.getHeightOrThrowCalls->Array.length
    Vi.useRealTimers()

    t.expect((pollsBefore, pollsAfter > pollsBefore)).toStrictEqual((1, true))
  })

  Async.it("Polls at once for a waiter that arrives while the last loop is unwinding", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let (heights, _subscription) = feed->watch(~knownHeight=100, ~interval=() => 60_000)

    // The answer settles the wait, and whoever was waiting registers the next one
    // straight away — before the loop that answered it has finished unwinding, so
    // it still holds `polling` and no new loop can start. That loop does pick the
    // waiter up, but it was already on its way to a sleep chosen without it: left
    // there, the next poll is a whole interval away rather than now.
    mock.resolveGetHeightOrThrowAt(~index=0, 101)
    await Utils.delay(0)
    let (_next, _nextSubscription) = feed->watch(~knownHeight=101, ~interval=() => 60_000)
    await Utils.delay(20)

    t.expect((heights, mock.getHeightOrThrowCalls->Array.length)).toStrictEqual(([101], 2))
  })

  Async.it(
    "Records a poll answer that arrives after the bound rather than dropping it",
    async t => {
      Vi.useFakeTimers()
      let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
      let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 10_000)
      let (heights, _subscription) = feed->watch(~knownHeight=100, ~interval=() => 10_000)

      // The endpoint answers, only slower than the bound allows. The request was
      // made and the height is the head, so a source that always answers just past
      // the bound must still move the feed rather than never moving it at all.
      await Vi.advanceTimersByTimeAsync(HeightFeed.pollTimeoutMillis + 100)
      mock.resolveGetHeightOrThrowAt(~index=0, 101)
      await Vi.advanceTimersByTimeAsync(1)
      Vi.useRealTimers()

      t.expect((heights, feed->HeightFeed.knownHeight)).toStrictEqual(([101], 101))
    },
  )

  Async.it("Lets a catch-up that answers reset the poll ramp", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let retries = []
    let (feed, _stats) = makeFeed(
      mock,
      ~getHeightRetryInterval=(~retry) => {
        retries->Array.push(retry)->ignore
        1
      },
    )
    feed->HeightFeed.enableStream
    let (_heights, _subscription) = feed->watch(~knownHeight=100, ~interval=() => 1)

    mock.rejectGetHeightOrThrow(JsError.make("no"))
    await Utils.delay(10)
    mock.rejectGetHeightOrThrow(JsError.make("no again"))
    await Utils.delay(10)
    let retriesBeforeConnect = retries->Array.copy

    // The stream connects and its catch-up answers. That is the endpoint
    // answering, which is all the ramp beside it measures — it makes no
    // difference which of the two asked.
    mock.setHeightSubscriptionStatus(Live)
    await Utils.delay(0)
    let catchUpIndex = mock.getHeightOrThrowCalls->Array.length - 1
    mock.resolveGetHeightOrThrowAt(~index=catchUpIndex, 100)
    await Utils.delay(10)
    mock.rejectGetHeightOrThrow(JsError.make("and again"))
    await Utils.delay(10)

    t.expect((retriesBeforeConnect, retries)).toStrictEqual(([0, 1], [0, 1, 0]))
  })

  Async.it("Bounds a catch-up that never answers, though nothing waits on it", async t => {
    Vi.useFakeTimers()
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream

    // Nobody is waiting, so no loop is watching this request on anyone's behalf.
    // Unbounded it would be a request per connect that is never released.
    mock.setHeightSubscriptionStatus(Live)
    let timersWhileOutstanding = Vi.getTimerCount()
    await Vi.advanceTimersByTimeAsync(HeightFeed.pollTimeoutMillis + 100)
    let timersAfterDeadline = Vi.getTimerCount()
    Vi.useRealTimers()

    t.expect((timersWhileOutstanding, timersAfterDeadline)).toStrictEqual((1, 0))
  })

  Async.it("Keeps polling for the waiter rather than giving up on a failure", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 1)
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100, ~interval=() => 10_000)

    mock.rejectGetHeightOrThrow(JsError.make("nope"))
    await Utils.delay(10)
    let pollsAfterFailure = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(0)

    t.expect((pollsAfterFailure, heights)).toStrictEqual((2, [101]))
  })

  Async.it("Resets the poll ramp when a push recovers the stream after failed polls", async t => {
    Vi.useFakeTimers()
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let retries = []
    let (feed, _stats) = makeFeed(
      mock,
      ~getHeightRetryInterval=(~retry) => {
        retries->Array.push(retry)->ignore
        10_000
      },
    )
    feed->HeightFeed.enableStream
    let (_heights, subscription) = feed->watch(~knownHeight=100, ~interval=() => 10_000)

    mock.rejectGetHeightOrThrow(JsError.make("no"))
    await Vi.advanceTimersByTimeAsync(1)
    mock.rejectGetHeightOrThrow(JsError.make("no again"))
    await Vi.advanceTimersByTimeAsync(1)

    // Loop is sleeping off the 10s ramp, so the only in-flight request after
    // Live is the catch-up. A push answers the waiter; a failed catch-up must
    // not leave that ramp for the next outage.
    mock.setHeightSubscriptionStatus(Live)
    await Vi.advanceTimersByTimeAsync(1)
    mock.triggerHeightSubscription(101)
    await Vi.advanceTimersByTimeAsync(1)
    mock.rejectGetHeightOrThrow(JsError.make("catch-up failed"))
    await Vi.advanceTimersByTimeAsync(1)
    subscription.unsubscribe()

    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    let retriesAfterRecovery = retries->Array.length
    let (_later, _laterSubscription) = feed->watch(~knownHeight=101, ~interval=() => 10_000)
    mock.rejectGetHeightOrThrow(JsError.make("dropped again"))
    await Vi.advanceTimersByTimeAsync(1)
    Vi.useRealTimers()

    t.expect(retries->Array.getUnsafe(retriesAfterRecovery)).toEqual(0)
  })

  Async.it("Wakes a backoff sleep when a reconnect's catch-up fails", async t => {
    Vi.useFakeTimers()
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock, ~getHeightRetryInterval=(~retry as _) => 10_000)
    feed->HeightFeed.enableStream
    let (_heights, _subscription) = feed->watch(~knownHeight=100, ~interval=() => 10_000)

    mock.rejectGetHeightOrThrow(JsError.make("no"))
    await Vi.advanceTimersByTimeAsync(1)
    mock.setHeightSubscriptionStatus(Live)
    await Vi.advanceTimersByTimeAsync(1)
    mock.rejectGetHeightOrThrow(JsError.make("catch-up failed"))
    await Vi.advanceTimersByTimeAsync(1)
    let pollsAfterFailedCatchUp = mock.getHeightOrThrowCalls->Array.length
    Vi.useRealTimers()

    t.expect(pollsAfterFailedCatchUp).toBeGreaterThanOrEqual(3)
  })
})
