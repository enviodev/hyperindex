open Vitest
open RealtimeChain

// When a chain polls its source for the height, how it backs off a failing
// one, and how that polling lives next to a height stream.
let scenario = Scenario.make(
  ~configYaml=`
name: height-polling
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
  owner: String!
}
`,
)

let fail = (mock: MockSource.t) => mock.rejectGetHeightOrThrow(JsError.make("height unavailable"))

let ramp = SourceManager.makeGetHeightRetryInterval(
  ~initialRetryInterval=50,
  ~backoffMultiplicative=2,
  ~maxRetryInterval=10_000,
)

describe("Polling only for someone", () => {
  scenario->Scenario.it(
    "Doesn't poll while the chain is fetching rather than waiting",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      let pollsWhileFetching = mock->polls
      await Utils.delay(30)
      t.expect(mock->polls).toEqual(pollsWhileFetching)
    },
  )

  scenario->Scenario.it(
    "Takes over the poll the last wait left in flight rather than asking again",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      let pollsAtRealtime = mock->polls
      await Utils.delay(20)
      let pollsLater = mock->polls
      mock.resolveGetHeightOrThrow(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect((pollsAtRealtime, pollsLater)).toEqual((2, 2))
    },
  )

  scenario->Scenario.it(
    "Polls at once for the next wait, however long the source's interval",
    ~sources=[{chain: 1337, pollingInterval: 60_000}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock->answerQuery(~fromBlock=1, ~toBlock=100)
      mock.resolveGetHeightOrThrow(101)
      let pollsAtAnswer = mock->polls
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      // The wait that follows starts right behind the loop that answered the
      // last one, which must not leave it a whole interval away.
      await mock.expectHeightCalls(pollsAtAnswer + 1)
      t.expect(mock->polls).toEqual(pollsAtAnswer + 1)
    },
  )

  scenario->Scenario.it(
    "Reports the height a query response carried as the source's known height",
    ~sources=[{chain: 1337, pollingInterval: 10_000}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 100, knownHeight: 105}),
        },
      ])
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(
        (await indexer.metric("envio_source_known_height"))->Array.map(({value}) => value),
      ).toEqual(["105"])
    },
  )
})

describe("Polling behind a stream", () => {
  scenario->Scenario.it(
    "Stops polling behind a distrusted stream once a push proves it",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive
      mock.setAutoHeight(101)
      // The stall poke distrusts the quiet stream, and polling starts.
      await mock.expectHeightCalls(mock->polls + 2)
      mock.triggerHeightSubscription(102)
      await mock->answerQuery(~fromBlock=102, ~toBlock=102)
      let pollsAtNextWait = mock->polls
      // Well short of the next wait's own stall poke.
      await Utils.delay(50)
      t.expect(mock->polls).toEqual(pollsAtNextWait)
    },
  )

  scenario->Scenario.it(
    "Keeps polling a distrusted stream until it delivers, not until one poll is quiet",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive
      let pollsWhileProven = mock->polls
      await mock.expectHeightCalls(pollsWhileProven + 1)
      // A poll that agrees the chain is quiet says nothing about whether the
      // stream would have delivered, so the distrust stands.
      mock.resolveGetHeightOrThrow(101)
      await mock.expectHeightCalls(pollsWhileProven + 2)
      mock.resolveGetHeightOrThrow(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(mock.pendingItemsQueries->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Takes a distrust back on any push, even of a height it already knew",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive
      await mock.expectHeightCalls(mock->polls + 1)
      // The poll beat the stream to the head, so the stream pushes a height
      // already known. That is still it delivering.
      mock.triggerHeightSubscription(101)
      mock.resolveGetHeightOrThrow(101)
      await Utils.delay(0)
      let pollsAfterPush = mock->polls
      mock.setAutoHeight(101)
      await Utils.delay(30)
      // Still distrusted, it would poll every 5ms. The one poll allowed is the
      // stall timeout itself landing in the window.
      t.expect(mock->polls - pollsAfterPush <= 1).toBe(true)
    },
  )

  scenario->Scenario.it(
    "Keeps polling a new connection until a poll made after it accounts for its head",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 1},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      await Utils.delay(0)
      // Older than the connection, so it says nothing about the head the
      // connection came up on.
      mock->fail
      let pollsAfterFailure = mock->polls
      await mock.expectHeightCalls(pollsAfterFailure + 1)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(10)
      let pollsOnceAccounted = mock->polls
      await Utils.delay(40)
      t.expect(mock->polls).toEqual(pollsOnceAccounted)
    },
  )

  scenario->Scenario.it(
    "Drops a distrust when the wait that made it is answered by another source",
    ~sources=[
      {chain: 1337, methods: streaming, pollingInterval: 5},
      {chain: 1337, pollingInterval: 1},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let streamed = source(1337)
      let polled = source(1337, ~index=1)
      await reach(~sync=streamed)
      await streamed->goLive
      polled.setAutoHeight(101)
      streamed.setAutoHeight(101)
      await streamed.expectHeightCalls(streamed->polls + 1)

      // No push ever comes to take the distrust back: another source answers.
      polled.setAutoHeight(102)
      await polled->answerQuery(~fromBlock=102, ~toBlock=102)
      let pollsAtNextWait = streamed->polls
      await Utils.delay(50)
      t.expect(streamed->polls).toEqual(pollsAtNextWait)
    },
  )

  scenario->Scenario.it(
    "Polls straight away when a live connection drops while polling sleeps",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive
      // The stall poke's poll answers below the head and the polling settles in
      // for an interval chosen while the connection still covered the source.
      mock.setAutoHeight(101)
      await mock.expectHeightCalls(mock->polls + 1)
      let pollsWhileSleeping = mock->polls
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await mock.expectHeightCalls(pollsWhileSleeping + 1)
      t.expect(mock->polls).toEqual(pollsWhileSleeping + 1)
    },
  )

  scenario->Scenario.it(
    "Doesn't poll again for each retry failing against a stream already down",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      let pollsWhileSleeping = mock->polls
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      await Utils.delay(10)
      t.expect(mock->polls).toEqual(pollsWhileSleeping)
    },
  )

  scenario->Scenario.it(
    "Sits out the backoff when the stream drops while polls are failing",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 10_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      mock->fail
      await Utils.delay(0)
      let pollsWhileBackingOff = mock->polls
      // Usually the same endpoint's doing, so no reason to ask ahead of time.
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(10)
      t.expect(mock->polls).toEqual(pollsWhileBackingOff)
    },
  )

  scenario->Scenario.it(
    "Keeps polling when a replaced connection's catch-up lands late",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 1},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      let firstCatchUp = mock->polls
      mock.setHeightSubscriptionStatus(Live)
      await mock.expectHeightCalls(firstCatchUp + 1)
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      // The connection now in place, with a catch-up of its own outstanding.
      mock.setHeightSubscriptionStatus(Live)
      // The dropped connection's catch-up says nothing about the head the one
      // in place came up on, and everything else fails.
      mock.resolveGetHeightOrThrowAt(~index=firstCatchUp, 100)
      mock->fail
      let pollsBefore = mock->polls
      await Utils.delay(20)
      t.expect(mock->polls > pollsBefore).toBe(true)
    },
  )
})

describe("Height poll failures", () => {
  scenario->Scenario.it(
    "Gives up on a poll that never answers and polls again",
    ~sources=[{chain: 1337, pollingInterval: 10_000}],
    ~sourceTiming={heightPollTimeout: 50, getHeightRetryInterval: (~retry as _) => 1},
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await mock.expectHeightCalls(1)
      // Answered by nothing, ever.
      await mock.expectHeightCalls(2)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(indexer->heightRetryIntervals).toEqual(["1"])
    },
  )

  scenario->Scenario.it(
    "Uses a height that answers after the poll was given up on",
    ~sources=[{chain: 1337, pollingInterval: 10_000}],
    ~sourceTiming={heightPollTimeout: 50, getHeightRetryInterval: (~retry as _) => 10_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await mock.expectHeightCalls(1)
      await Utils.delay(80)
      // Slower than the bound, but the head it came back with is real.
      mock.resolveGetHeightOrThrowAt(~index=0, 100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(mock->polls).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Lets any answer reset the poll backoff, even one that proves no connection",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={getHeightRetryInterval: ramp},
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      let polls0 = mock->polls
      mock->fail
      await mock.expectHeightCalls(polls0 + 1)
      mock->fail
      await mock.expectHeightCalls(polls0 + 2)
      // The stream connects while that poll is out. Asked before the connection,
      // its answer can't prove it, so polling goes on — but the endpoint did
      // answer, which is all the backoff measures.
      mock.setHeightSubscriptionStatus(Live)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectHeightCalls(polls0 + 3)
      mock->fail
      await Utils.delay(0)
      t.expect(indexer->heightRetryIntervals).toEqual(["50", "100", "50"])
    },
  )

  scenario->Scenario.it(
    "Resets the poll backoff when a push recovers the stream after failed polls",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: ramp},
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      let polls0 = mock->polls
      mock->fail
      await mock.expectHeightCalls(polls0 + 1)
      mock->fail
      await mock.expectHeightCalls(polls0 + 2)
      // The stream connects and delivers while that poll is out. The source is
      // answering after all, so the poll's failure starts the backoff from the
      // bottom rather than the top.
      mock.setHeightSubscriptionStatus(Live)
      mock.triggerHeightSubscription(101)
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      mock->fail
      await Utils.delay(0)
      t.expect(indexer->heightRetryIntervals).toEqual(["50", "100", "50"])
    },
  )

  scenario->Scenario.it(
    "Keeps the backoff a failing endpoint earned when its stream flaps",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 10_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock->fail
      await Utils.delay(0)
      let pollsInBackoff = mock->polls
      // Claiming to be connected is not the endpoint answering.
      mock.setHeightSubscriptionStatus(Live)
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(10)
      t.expect(mock->polls).toEqual(pollsInBackoff)
    },
  )

  scenario->Scenario.it(
    "Asks once, not twice, when a stream connects while polling",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      // Answered below the floor, so the polling sleeps off an interval.
      mock.resolveGetHeightOrThrow(100)
      await Utils.delay(0)
      let pollsBeforeConnect = mock->polls
      mock.setHeightSubscriptionStatus(Live)
      await mock.expectHeightCalls(pollsBeforeConnect + 1)
      await Utils.delay(10)
      t.expect(mock->polls).toEqual(pollsBeforeConnect + 1)
    },
  )

  scenario->Scenario.it(
    "Drops the backoff when a push shows the source answering after all",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 60_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      mock->fail
      await Utils.delay(0)
      let pollsInBackoff = mock->polls
      mock.triggerHeightSubscription(101)
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      // The minute the failures earned was owed by an endpoint that has since
      // answered, so the connection dropping is polled for now.
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await mock.expectHeightCalls(pollsInBackoff + 1)
      t.expect(mock->polls).toEqual(pollsInBackoff + 1)
    },
  )
})

describe("Height stream warnings", () => {
  let warningReasons = (indexer: IndexerRunner.t) =>
    indexer.allLogsAsJson()->Array.filterMap(line =>
      switch (line->Dict.get("level"), line->Dict.get("reason")) {
      | (Some(String("warn")), Some(String(reason))) => Some(reason)
      | _ => None
      }
    )

  scenario->Scenario.it(
    "Says once that a provider is refusing the subscription",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      // A url that can't serve heights answers every retry the same way.
      for _ in 1 to 3 {
        mock.setHeightSubscriptionStatus(Down({reason: SubscribeRejected, detail: "not supported"}))
      }
      t.expect(indexer->warningReasons).toEqual(["subscribe-rejected"])
    },
  )

  scenario->Scenario.it(
    "Stays quiet about a refusal from a stream that has served before",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      mock.setHeightSubscriptionStatus(Down({reason: SubscribeRejected}))
      t.expect(indexer->warningReasons).toEqual([])
    },
  )
})
