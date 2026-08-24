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
  let unsubscribe =
    feed->HeightFeed.onHeightAbove(~knownHeight, ~interval, ~onHeight=height =>
      heights->Array.push(height)->ignore
    )
  (heights, unsubscribe)
}

describe("HeightFeed answers a waiter", () => {
  Async.it("From a poll when nothing is pushing", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10)
    let (feed, _stats) = makeFeed(mock)
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)

    let pollsBeforeAnswer = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(101)
    await Utils.delay(0)

    t.expect((pollsBeforeAnswer, heights, (feed->HeightFeed.sample).knownHeight)).toStrictEqual((
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

    t.expect((heights, (feed->HeightFeed.sample).knownHeight)).toStrictEqual(([105], 105))
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
    let (_heights, unsubscribe) = feed->watch(~knownHeight=100, ~interval=() => 5)

    // A height that doesn't clear the floor, so the loop sleeps and comes back.
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(20)
    let pollsWhileWaiting = mock.getHeightOrThrowCalls->Array.length
    mock.resolveGetHeightOrThrow(100)

    unsubscribe()
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
      (feed->HeightFeed.sample).knownHeight,
    )).toStrictEqual((1, 1, 105))
  })

  Async.it("Reuses a poll already in flight rather than stacking another", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let (first, unsubscribeFirst) = feed->watch(~knownHeight=100)
    let pollsAfterFirst = mock.getHeightOrThrowCalls->Array.length
    unsubscribeFirst()

    // A second wait arrives while the request the first one triggered is still
    // out. Asking the same source twice would not make it answer sooner.
    let (second, _unsubscribeSecond) = feed->watch(~knownHeight=100)
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
    let (heights, unsubscribe) = feed->watch(~knownHeight=100)

    unsubscribe()
    unsubscribe()
    feed->HeightFeed.recordHeight(101)
    await Utils.delay(0)

    t.expect(heights).toStrictEqual([])
  })

  Async.it("Works from inside the callback it is unsubscribing", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    let heights = []
    let unsubscribeRef = ref(() => ())
    unsubscribeRef :=
      feed->HeightFeed.onHeightAbove(
        ~knownHeight=100,
        ~interval=() => 10,
        // The wait above does exactly this: the first height it hears cancels
        // every waiter it registered, including the one delivering it.
        ~onHeight=height => {
          heights->Array.push(height)->ignore
          unsubscribeRef.contents()
        },
      )

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
  Async.it("Polls alongside a live stream once poked, until a push proves it", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream
    let (heights, _unsubscribe) = feed->watch(~knownHeight=100)

    mock.setHeightSubscriptionStatus(Live)
    mock.resolveGetHeightOrThrow(100)
    await Utils.delay(0)
    // Live and proven by its catch-up: nothing polls beside it.
    let pollsWhileProven = mock.getHeightOrThrowCalls->Array.length
    await Utils.delay(20)
    let pollsAfterWaiting = mock.getHeightOrThrowCalls->Array.length

    feed->HeightFeed.poke
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
      (feed->HeightFeed.sample).stream,
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

  Async.it("Keeps polling when a replaced connection's catch-up lands late", async t => {
    let mock = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~pollingInterval=10_000,
    )
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream

    mock.setHeightSubscriptionStatus(Live)
    mock.setHeightSubscriptionStatus(Down({reason: "closed"}))
    // The connection now in place, with a catch-up of its own outstanding.
    mock.setHeightSubscriptionStatus(Live)
    let (_heights, _unsubscribe) = feed->watch(~knownHeight=100, ~interval=() => 5)
    let pollsBefore = mock.getHeightOrThrowCalls->Array.length

    // The dropped connection's catch-up, answering after its replacement took
    // over. It says nothing about whether the connection in place delivers, so
    // it must not retire the polling covering that one.
    mock.resolveGetHeightOrThrowAt(~index=0, 100)
    mock.resolveGetHeightOrThrowAt(~index=2, 100)
    await Utils.delay(20)

    t.expect((pollsBefore, mock.getHeightOrThrowCalls->Array.length > pollsBefore)).toStrictEqual((
      3,
      true,
    ))
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

    t.expect((whileNeverConnected.stream, (feed->HeightFeed.sample).stream)).toStrictEqual((
      Some({HeightFeed.connectCount: 0, disconnects: []}),
      Some({HeightFeed.connectCount: 1, disconnects: [("closed", 1)]}),
    ))
  })

  Async.it("Reports no stream at all for a source that cannot subscribe", async t => {
    let mock = MockSource.make([#getHeightOrThrow], ~pollingInterval=10_000)
    let (feed, _stats) = makeFeed(mock)
    feed->HeightFeed.enableStream

    t.expect((
      mock.heightSubscriptionCalls->Array.length,
      (feed->HeightFeed.sample).stream,
    )).toStrictEqual((0, None))
  })
})

describe("HeightFeed poll failures", () => {
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
})
