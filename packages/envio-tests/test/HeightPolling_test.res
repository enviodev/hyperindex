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
  ~virtualTime=true,
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
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await mock.expectNewHeightCalls(1)
      // Thirty of its polling intervals.
      await indexer.advanceTime(30)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Takes over the poll the last wait left in flight rather than asking again",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await indexer.advanceTime(20)
      await mock.expectNewHeightCalls(0)
      mock.resolveGetHeightOrThrow(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
    },
  )

  scenario->Scenario.it(
    "Polls at once for the next wait, however long the source's interval",
    ~sources=[{chain: 1337, pollingInterval: 60_000}],
    async (~t as _, ~indexer as _, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock->answerQuery(~fromBlock=1, ~toBlock=100)
      await mock.expectNewHeightCalls(2)
      mock.resolveGetHeightOrThrow(101)
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      // The wait that follows starts right behind the loop that answered the
      // last one, which must not leave it a whole interval away.
      await mock.expectNewHeightCalls(1)
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
      await mock.expectNewHeightCalls(1)
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
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive(~indexer)
      mock.setAutoHeight(101)
      // The stall poke distrusts the quiet stream somewhere in the window's
      // second half, and polling starts.
      await indexer.advanceTime(199)
      await mock.expectNewHeightCallsAtLeast(1)
      mock.triggerHeightSubscription(102)
      await mock->answerQuery(~fromBlock=102, ~toBlock=102)
      // Well short of the next wait's own stall poke.
      await indexer.advanceTime(50)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Keeps polling a distrusted stream until it delivers, not until one poll is quiet",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive(~indexer)
      await indexer.advanceTime(199)
      await mock.expectNewHeightCalls(1)
      // A poll that agrees the chain is quiet says nothing about whether the
      // stream would have delivered, so the distrust stands.
      mock.resolveGetHeightOrThrow(101)
      await indexer.advanceTime(5)
      await mock.expectNewHeightCalls(1)
      mock.resolveGetHeightOrThrow(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
    },
  )

  scenario->Scenario.it(
    "Takes a distrust back on any push, even of a height it already knew",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive(~indexer)
      await indexer.advanceTime(199)
      await mock.expectNewHeightCalls(1)
      // The poll beat the stream to the head, so the stream pushes a height
      // already known. That is still it delivering.
      mock.triggerHeightSubscription(101)
      mock.resolveGetHeightOrThrow(101)
      mock.setAutoHeight(101)
      // Still distrusted, it would poll every 5ms. The one poll is the stall
      // timeout landing at 200ms and distrusting it afresh.
      await indexer.advanceTime(30)
      await mock.expectNewHeightCalls(1)
    },
  )

  scenario->Scenario.it(
    "Keeps polling a new connection until a poll made after it accounts for its head",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 1},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      // Older than the connection, so it says nothing about the head the
      // connection came up on.
      mock->fail
      await indexer.advanceTime(1)
      await mock.expectNewHeightCalls(1)
      mock.resolveGetHeightOrThrow(100)
      await indexer.advanceTime(50)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Drops a distrust when the wait that made it is answered by another source",
    ~sources=[
      {chain: 1337, methods: streaming, pollingInterval: 5},
      {chain: 1337, pollingInterval: 10},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t as _, ~indexer, ~source) => {
      let streamed = source(1337)
      let polled = source(1337, ~index=1)
      await reach(~sync=streamed)
      await streamed->goLive(~indexer)
      polled.setAutoHeight(101)
      streamed.setAutoHeight(101)
      await indexer.advanceTime(199)
      await streamed.expectNewHeightCallsAtLeast(1)

      // No push ever comes to take the distrust back: another source answers.
      polled.setAutoHeight(102)
      await indexer.advanceTime(10)
      await polled->answerQuery(~fromBlock=102, ~toBlock=102)
      await polled.expectNewHeightCallsAtLeast(1)
      // The answer ended the wait, and with it the distrusted stream's polling.
      await streamed.expectNewHeightCalls(0)
      await indexer.advanceTime(50)
      await streamed.expectNewHeightCalls(0)
      // The source that answered goes on polling for the next block.
      await polled.expectNewHeightCalls(5)
    },
  )

  scenario->Scenario.it(
    "Polls straight away when a live connection drops while polling sleeps",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      await mock->goLive(~indexer)
      // The stall poke's poll answers below the head and the polling settles in
      // for an interval chosen while the connection still covered the source.
      mock.setAutoHeight(101)
      await indexer.advanceTime(199)
      await mock.expectNewHeightCalls(1)
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await mock.expectNewHeightCalls(1)
    },
  )

  scenario->Scenario.it(
    "Doesn't poll again for each retry failing against a stream already down",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      await indexer.waitUntilIdle()
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      await indexer.advanceTime(10)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Sits out the backoff when the stream drops while polls are failing",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 10_000},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      mock->fail
      await indexer.waitUntilIdle()
      // Usually the same endpoint's doing, so no reason to ask ahead of time.
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await indexer.advanceTime(10)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Keeps polling when a replaced connection's catch-up lands late",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 1},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      await indexer.waitUntilIdle()
      mock.setHeightSubscriptionStatus(Live)
      await mock.expectNewHeightCalls(1)
      let firstCatchUp = mock.getHeightOrThrowCalls->Array.length - 1
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      // The connection now in place, with a catch-up of its own outstanding.
      mock.setHeightSubscriptionStatus(Live)
      // The dropped connection's catch-up says nothing about the head the one
      // in place came up on, and everything else fails.
      mock.resolveGetHeightOrThrowAt(~index=firstCatchUp, 100)
      mock->fail
      await indexer.advanceTime(5)
      await mock.expectNewHeightCallsAtLeast(1)
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
      await mock.expectNewHeightCalls(1)
      // Answered by nothing, ever.
      await indexer.advanceTime(51)
      await mock.expectNewHeightCalls(1)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(indexer->heightRetryIntervals).toEqual(["1"])
    },
  )

  scenario->Scenario.it(
    "Uses a height that answers after the poll was given up on",
    ~sources=[{chain: 1337, pollingInterval: 10_000}],
    ~sourceTiming={heightPollTimeout: 50, getHeightRetryInterval: (~retry as _) => 10_000},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await mock.expectNewHeightCalls(1)
      await indexer.advanceTime(80)
      // Slower than the bound, but the head it came back with is real.
      mock.resolveGetHeightOrThrowAt(~index=0, 100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Lets any answer reset the poll backoff, even one that proves no connection",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 5}],
    ~sourceTiming={getHeightRetryInterval: ramp},
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock->fail
      await indexer.advanceTime(50)
      await mock.expectNewHeightCalls(1)
      mock->fail
      await indexer.advanceTime(100)
      await mock.expectNewHeightCalls(1)
      // The stream connects while that poll is out. Asked before the connection,
      // its answer can't prove it, so polling goes on — but the endpoint did
      // answer, which is all the backoff measures.
      mock.setHeightSubscriptionStatus(Live)
      mock.resolveGetHeightOrThrow(100)
      await indexer.advanceTime(5)
      await mock.expectNewHeightCalls(1)
      mock->fail
      await indexer.waitUntilIdle()
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
      mock->fail
      await indexer.advanceTime(50)
      await mock.expectNewHeightCalls(1)
      mock->fail
      await indexer.advanceTime(100)
      await mock.expectNewHeightCalls(1)
      // The stream connects and delivers while that poll is out. The source is
      // answering after all, so the poll's failure starts the backoff from the
      // bottom rather than the top.
      mock.setHeightSubscriptionStatus(Live)
      mock.triggerHeightSubscription(101)
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      mock->fail
      await indexer.waitUntilIdle()
      t.expect(indexer->heightRetryIntervals).toEqual(["50", "100", "50"])
    },
  )

  scenario->Scenario.it(
    "Keeps the backoff a failing endpoint earned when its stream flaps",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 10_000},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock->fail
      await indexer.waitUntilIdle()
      // Claiming to be connected is not the endpoint answering.
      mock.setHeightSubscriptionStatus(Live)
      await indexer.waitUntilIdle()
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await indexer.advanceTime(10)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Asks once, not twice, when a stream connects while polling",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      // Answered below the floor, so the polling sleeps off an interval.
      mock.resolveGetHeightOrThrow(100)
      await indexer.waitUntilIdle()
      mock.setHeightSubscriptionStatus(Live)
      await mock.expectNewHeightCalls(1)
      await indexer.advanceTime(10)
      await mock.expectNewHeightCalls(0)
    },
  )

  scenario->Scenario.it(
    "Drops the backoff when a push shows the source answering after all",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={getHeightRetryInterval: (~retry as _) => 60_000},
    async (~t as _, ~indexer, ~source) => {
      let mock = source(1337)
      await reach(~sync=mock)
      mock.setHeightSubscriptionStatus(Live)
      mock->fail
      await indexer.waitUntilIdle()
      mock.triggerHeightSubscription(101)
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      // The minute the failures earned was owed by an endpoint that has since
      // answered, so the connection dropping is polled for now.
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await mock.expectNewHeightCalls(1)
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
