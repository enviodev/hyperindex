open Vitest

// A realtime chain whose source can push heights: when it subscribes, when it
// trusts the stream, and when it polls behind it.
let scenario = Scenario.make(
  ~configYaml=`
name: height-subscription
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

let streaming: array<MockSource.method> = [
  #getHeightOrThrow,
  #getItemsOrThrow,
  #createHeightSubscription,
]

let polls = (mock: MockSource.t) => mock.getHeightOrThrowCalls->Array.length

let upTo = toBlock => MockSource.Respond({items: [], latestFetchedBlockNumber: toBlock})

// Backfills `query` to `head` on the source `sync`, after which the chain's
// realtime wait subscribes `mock` and polls it once beside the stream.
let reachRealtime = async (~sync: MockSource.t, ~mock=sync, ~head=100) => {
  sync.resolveGetHeightOrThrow(head)
  await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(head)}])
  await Scenario.waitUntil(
    () => mock.heightSubscriptionCalls->Array.length > 0,
    ~message="the height subscription",
  )
}

// Answers the query a new head starts, which puts the chain back to waiting.
let answerQuery = async (mock: MockSource.t, ~fromBlock, ~toBlock) =>
  await mock.expectItemsQueries([{fromBlock, reply: upTo(toBlock)}])

// Takes a freshly subscribed source to a live stream that has delivered: the
// catch-up poll its connect fires is answered, the stream pushes `head + 1`,
// and the query for it is answered. The chain is left waiting above `head + 1`
// with no poll in flight, the stream carrying the wait on its own.
let goLive = async (mock: MockSource.t, ~head=100) => {
  mock.resolveGetHeightOrThrow(head)
  let pollsBeforeLive = mock->polls
  mock.setHeightSubscriptionStatus(Live)
  await mock.expectHeightCalls(pollsBeforeLive + 1)
  mock.resolveGetHeightOrThrow(head)
  mock.triggerHeightSubscription(head + 1)
  await mock->answerQuery(~fromBlock=head + 1, ~toBlock=head + 1)
}

let streamMetrics = async (indexer: IndexerRunner.t) => {
  let samples = async name =>
    (await indexer.metric(name))->Array.map(({value, labels}: IndexerRunner.metric) => (
      labels->Dict.get("reason")->Option.getOr("-"),
      value,
    ))
  (
    await samples("envio_source_height_stream_connects_total"),
    await samples("envio_source_height_stream_disconnects_total"),
  )
}

describe("Height subscription", () => {
  scenario->Scenario.it(
    "Subscribes once the chain reaches realtime and takes the height it pushes",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      let subscriptionsInBackfill = mock.heightSubscriptionCalls->Array.length
      mock.drainPendingItemsQueries(~latestFetchedBlockNumber=100)
      await Scenario.waitUntil(
        () => mock.heightSubscriptionCalls->Array.length > 0,
        ~message="the height subscription",
      )
      mock.triggerHeightSubscription(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect((subscriptionsInBackfill, mock.heightSubscriptionCalls->Array.length)).toEqual((
        0,
        1,
      ))
    },
  )

  scenario->Scenario.it(
    "Fetches up to a pushed height without polling for it again",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      mock.setHeightSubscriptionStatus(Live)
      mock.triggerHeightSubscription(105)
      await mock->answerQuery(~fromBlock=101, ~toBlock=101)
      let pollsAfterPush = mock->polls
      await mock.expectItemsQueries([{fromBlock: 102, reply: upTo(105)}])
      t.expect(mock->polls).toEqual(pollsAfterPush)
    },
  )

  scenario->Scenario.it(
    "Waits for the next push, without polling, while the stream is live",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      let pollsWhileLive = mock->polls
      await Utils.delay(20)
      let pollsLater = mock->polls
      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(pollsLater).toEqual(pollsWhileLive)
    },
  )

  scenario->Scenario.it(
    "Polls in realtime when the source can't push heights",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock->answerQuery(~fromBlock=1, ~toBlock=100)
      mock.setAutoHeight(100)
      await mock.expectHeightCalls(mock->polls + 2)
      mock.setAutoHeight(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(mock.heightSubscriptionCalls).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Polls behind a live stream that stays quiet for the stall timeout",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 20},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      let pollsWhileLive = mock->polls
      // The poke lands somewhere in [stallTimeout/2, stallTimeout).
      await mock.expectHeightCalls(pollsWhileLive + 1)
      mock.resolveGetHeightOrThrow(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(mock.pendingItemsQueries->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Spreads the first stall poke below the window it warns at",
    ~sources=[
      {chain: 1337, pollingInterval: 10_000},
      {chain: 1337, sourceFor: Realtime, methods: streaming, pollingInterval: 10_000},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 400},
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      await reachRealtime(~sync, ~mock=live)
      await live->goLive
      // Answers the poll sync still has out from the backfill, so the poll the
      // stall recruits it for is a fresh one.
      sync.setAutoHeight(101)
      let startedAt = Date.now()
      let (livePolls, syncPolls) = (live->polls, sync->polls)
      let pokedAt = ref(None)
      let recruitedAt = ref(None)
      await Scenario.waitUntil(
        () => {
          let now = Date.now() -. startedAt
          if pokedAt.contents->Option.isNone && live->polls > livePolls {
            pokedAt := Some(now)
          }
          if recruitedAt.contents->Option.isNone && sync->polls > syncPolls {
            recruitedAt := Some(now)
          }
          recruitedAt.contents->Option.isSome
        },
        ~message="the stall to recruit sync",
      )
      live.resolveGetHeightOrThrow(102)
      await live.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])

      let pokedAt = pokedAt.contents->Option.getOr(infinity)
      let recruitedAt = recruitedAt.contents->Option.getOr(0.)
      // Timer slack only ever makes a timer late, never early.
      t.expect((pokedAt >= 200., pokedAt <= recruitedAt, recruitedAt >= 400.)).toEqual((
        true,
        true,
        true,
      ))
    },
  )

  // https://github.com/enviodev/hyperindex/issues/1270
  scenario->Scenario.it(
    "Stale pushed heights do not multiply concurrent height polls",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 100}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      let pollsBefore = mock->polls

      // What a flapping stream re-emits on each reconnect.
      for _ in 1 to 20 {
        mock.triggerHeightSubscription(101)
        await Utils.delay(0)
      }
      // Past the jittered stall poke, so the one poll it allows has run.
      await Utils.delay(240)
      let pollsAfterBurst = mock->polls - pollsBefore

      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(pollsAfterBurst <= 1).toBe(true)
    },
  )

  scenario->Scenario.it(
    "Closes the stream of a benched source and counts it as lost",
    ~sources=[
      {chain: 1337, methods: streaming},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 1},
    ],
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      let fallback = source(1337, ~index=1)
      await reachRealtime(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      mock.setHeightSubscriptionStatus(Live)
      mock.triggerHeightSubscription(101)
      // An unrecoverable selection error is what benches a source for good.
      await mock.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Fail(Source.GetItemsError(UnsupportedSelection({message: "test disable"}))),
        },
      ])
      await fallback->answerQuery(~fromBlock=101, ~toBlock=101)

      // The fallback is the only source left to find the next block.
      fallback.setAutoHeight(102)
      await fallback.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect((
        mock.heightSubscriptionCloseCalls->Array.length,
        await indexer->streamMetrics,
      )).toEqual((
        1,
        // The connection was delivering until it was closed, so it is counted
        // as lost — otherwise the source would read as still pushing heights
        // for the rest of the process.
        ([("-", "1")], [("unsubscribed", "1")]),
      ))
    },
  )

  scenario->Scenario.it(
    "Polls immediately when the stream reports it went down",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      let pollsWhileLive = mock->polls
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      // Well inside the stall timeout the wait would otherwise sit on.
      await mock.expectHeightCalls(pollsWhileLive + 1)
      mock.resolveGetHeightOrThrow(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(mock.pendingItemsQueries->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Polls at the source's interval while the stream has never connected",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      let pollsAtSubscribe = mock->polls
      await mock.expectHeightCalls(pollsAtSubscribe + 1)
      mock.resolveGetHeightOrThrow(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(mock.heightSubscriptionCalls->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Runs a single poll loop no matter how often the stream reports down",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      let pollsBefore = mock->polls
      for _ in 1 to 5 {
        mock.setHeightSubscriptionStatus(Down({reason: Closed}))
        await Utils.delay(0)
      }
      // The polling interval is far longer than the test, so a second loop
      // would show up as a second call in flight.
      let inFlightPolls = mock->polls - pollsBefore
      mock.resolveGetHeightOrThrow(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(inFlightPolls).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Stops polling behind the stream once it reconnects",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 20_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)

      // Unchanged heights keep a loop that hasn't stopped asking every polling
      // interval rather than blocking on one call.
      mock.setAutoHeight(101)
      await Utils.delay(30)
      let pollsAfterReconnect = mock->polls
      await Utils.delay(40)
      let pollsLater = mock->polls
      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(pollsLater - pollsAfterReconnect).toEqual(0)
    },
  )

  scenario->Scenario.it(
    "Backs the polling off when the source keeps failing",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10}],
    ~sourceTiming={
      newBlockStallTimeoutRealtime: 5_000,
      getHeightRetryInterval: (~retry as _) => 300,
    },
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await mock.expectHeightCalls(mock->polls)
      let pollsBefore = mock->polls
      // The endpoint whose stream just dropped fails these too. Asking again
      // every polling interval would issue one per round; the retry interval
      // is far longer than the whole window.
      for _ in 1 to 5 {
        mock.rejectGetHeightOrThrow("height unavailable")
        await Utils.delay(10)
      }
      let pollsDuringBackoff = mock->polls - pollsBefore
      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(pollsDuringBackoff).toEqual(0)
    },
  )

  scenario->Scenario.it(
    "Polls once on reconnect to pick up a height missed while down",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      // The chain moved to 102 while the stream was down. A newHeads
      // subscription would only deliver 103.
      mock.resolveGetHeightOrThrow(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(mock.pendingItemsQueries->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Catches up on the stream's first connect too",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      let pollsBeforeLive = mock->polls
      mock.setHeightSubscriptionStatus(Live)
      await mock.expectHeightCalls(pollsBeforeLive + 1)
      // A block mined between subscribing and the node accepting it.
      mock.resolveGetHeightOrThrow(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(mock->polls - pollsBeforeLive).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Catches up on reconnect even with nobody waiting",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      mock.resolveGetHeightOrThrow(100)
      let pollsBeforeLive = mock->polls
      mock.setHeightSubscriptionStatus(Live)
      await mock.expectHeightCalls(pollsBeforeLive + 1)
      mock.resolveGetHeightOrThrow(100)
      // The chain is fetching 101, not waiting, when the stream reconnects.
      mock.triggerHeightSubscription(101)
      await mock.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      mock.setHeightSubscriptionStatus(Live)
      mock.resolveGetHeightOrThrow(105)
      await Utils.delay(0)
      let pollsBefore = mock->polls

      // The next wait already knows the height the catch-up found.
      mock.drainPendingItemsQueries(~latestFetchedBlockNumber=101)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(mock->polls - pollsBefore).toEqual(0)
    },
  )

  scenario->Scenario.it(
    "Keeps waiting when the reconnect catch-up brings no new height",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      mock.resolveGetHeightOrThrow(101)
      await Utils.delay(10)
      let queriedEarly = mock.pendingItemsQueries->Array.length
      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(queriedEarly).toEqual(0)
    },
  )

  scenario->Scenario.it(
    "Keeps polling when the reconnect catch-up fails",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 20}],
    ~sourceTiming={
      newBlockStallTimeoutRealtime: 5_000,
      // Retry at the polling cadence, so this stays about whether the loop is
      // still running rather than about how far it backs off.
      getHeightRetryInterval: (~retry as _) => 20,
    },
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      await Utils.delay(0)
      let pollsAtReconnect = mock->polls
      // Nothing took the polling's job over, so it carries on rather than
      // leave the chain with no height until the stall timeout.
      for _ in 1 to 4 {
        mock.rejectGetHeightOrThrow("catch-up failed")
        await Utils.delay(20)
      }
      let pollsKeptComing = mock->polls > pollsAtReconnect
      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect(pollsKeptComing).toBe(true)
    },
  )

  scenario->Scenario.it(
    "Takes a head the catch-up recorded while the race was settling",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 5_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.triggerHeightSubscription(104)
      await mock->answerQuery(~fromBlock=102, ~toBlock=104)
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      // The catch-up's 105 lands with nobody left to hand it to, while the
      // race settles on the push's 103 — which isn't enough to end the wait.
      mock.resolveGetHeightOrThrow(105)
      mock.triggerHeightSubscription(103)
      await mock.expectItemsQueries([{fromBlock: 105, reply: LeavePending}])
      t.expect(mock.pendingItemsQueries->Array.length).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Runs one poll loop when a push settles a wait without advancing it",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 20}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 5_000},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      // Waiting well above the head, so a poll that finds a higher one keeps
      // the wait going instead of ending it.
      mock.triggerHeightSubscription(110)
      await mock->answerQuery(~fromBlock=102, ~toBlock=110)

      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      mock.resolveGetHeightOrThrow(105)
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Live)
      await Utils.delay(40)

      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      await Utils.delay(0)
      // A load-balanced backend can report a head behind the one a poll saw.
      // It settles the wait without moving it forward, which must still retire
      // the poll loop the wait started.
      mock.triggerHeightSubscription(103)
      await Utils.delay(0)

      let pollsBefore = mock->polls
      mock.resolveGetHeightOrThrow(104)
      await Utils.delay(40)
      let pollsAdded = mock->polls - pollsBefore
      mock.triggerHeightSubscription(111)
      await mock.expectItemsQueries([{fromBlock: 111, reply: LeavePending}])
      t.expect(pollsAdded).toEqual(1)
    },
  )

  scenario->Scenario.it(
    "Leaves no stall timer behind when recruiting a fallback answers the wait",
    ~sources=[
      {chain: 1337, pollingInterval: 10_000},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 10_000},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 50},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync->answerQuery(~fromBlock=1, ~toBlock=100)
      sync.resolveGetHeightOrThrow(100)
      await fallback.expectHeightCalls(1)
      // Sync settles the wait; the fallback's answer arrives after it, so the
      // fallback knows a head the chain doesn't.
      sync.resolveGetHeightOrThrow(101)
      fallback.resolveGetHeightOrThrow(105)
      await sync->answerQuery(~fromBlock=101, ~toBlock=101)

      // Recruiting the fallback answers this wait inside the stall callback
      // that recruited it.
      await sync.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      let stallWarnings = () =>
        indexer.infoAndAboveLogs()
        ->Array.filter(({msg}) => msg->String.startsWith("No new blocks detected"))
        ->Array.length
      let warningsAtAnswer = stallWarnings()
      await Utils.delay(200)
      t.expect((warningsAtAnswer, stallWarnings(), fallback->polls)).toEqual((2, 2, 1))
    },
  )

  scenario->Scenario.it(
    "Keeps covering a stream that goes quiet again after the stall",
    ~sources=[{chain: 1337, methods: streaming, pollingInterval: 10_000}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 100},
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      // Every poll is answered on the spot, so none is left in flight to
      // swallow the next poke.
      mock.setAutoHeight(101)
      let pollsWhileProven = mock->polls
      await Utils.delay(150)
      let pollsAfterFirstStall = mock->polls

      // A reconnect whose catch-up succeeds takes the stream at its word again,
      // and it goes quiet in exactly the same way.
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      mock.setHeightSubscriptionStatus(Live)
      await Utils.delay(0)
      let pollsAfterReconnect = mock->polls
      await Utils.delay(150)
      let pollsAfterSecondStall = mock->polls

      mock.triggerHeightSubscription(102)
      await mock.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect((
        pollsAfterFirstStall > pollsWhileProven,
        pollsAfterSecondStall > pollsAfterReconnect,
      )).toEqual((true, true))
    },
  )

  scenario->Scenario.it(
    "Recruits a stalled wait's fallback to poll, without opening its stream",
    ~sources=[
      {chain: 1337, pollingInterval: 10_000},
      {chain: 1337, sourceFor: Fallback, methods: streaming, pollingInterval: 10_000},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 50},
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync->answerQuery(~fromBlock=1, ~toBlock=100)
      sync.resolveGetHeightOrThrow(100)
      await fallback.expectHeightCalls(1)
      fallback.resolveGetHeightOrThrow(101)
      await sync.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(fallback.heightSubscriptionCalls).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Reports height stream connects and disconnects as metrics",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      mock.resolveGetHeightOrThrow(100)
      await mock.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      // Nothing until a wait asks for a stream: a source that can subscribe
      // but hasn't been asked to is no stream failing to connect.
      let beforeSubscribing = await indexer->streamMetrics
      mock.drainPendingItemsQueries(~latestFetchedBlockNumber=100)
      await Scenario.waitUntil(
        () => mock.heightSubscriptionCalls->Array.length > 0,
        ~message="the height subscription",
      )
      await mock->goLive
      let whileHealthy = await indexer->streamMetrics

      // One outage per connection lost, whatever the stream does while down:
      // the 401 and the second `closed` are retries that failed.
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      mock.setHeightSubscriptionStatus(Down({reason: Http(401)}))
      mock.setHeightSubscriptionStatus(Down({reason: Closed}))
      mock.setHeightSubscriptionStatus(Live)
      await Utils.delay(0)
      mock.setHeightSubscriptionStatus(Down({reason: Rotated}))
      mock.setHeightSubscriptionStatus(Live)

      t.expect((beforeSubscribing, whileHealthy, await indexer->streamMetrics)).toEqual((
        ([], []),
        ([("-", "1")], []),
        // Three connects against two disconnects: the stream is up.
        ([("-", "3")], [("closed", "1"), ("rotated", "1")]),
      ))
    },
  )

  scenario->Scenario.it(
    "Reports a stream that has never connected as zero connects",
    ~sources=[{chain: 1337, methods: streaming}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      // Retries at a connection that never existed: nothing disconnected.
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      mock.setHeightSubscriptionStatus(Down({reason: ConnectFailed}))
      await Utils.delay(0)
      let whileDown = await indexer->streamMetrics
      mock.setHeightSubscriptionStatus(Live)
      t.expect((whileDown, await indexer->streamMetrics)).toEqual((
        ([("-", "0")], []),
        ([("-", "1")], []),
      ))
    },
  )

  scenario->Scenario.it(
    "Stops polling a source once the wait has been decided by another",
    ~sources=[
      {chain: 1337, methods: streaming, pollingInterval: 10},
      {chain: 1337, pollingInterval: 10},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 2_000},
    async (~t, ~indexer as _, ~source) => {
      let stuck = source(1337)
      let fast = source(1337, ~index=1)
      await reachRealtime(~sync=stuck)
      await stuck->goLive
      await fast.expectHeightCalls(fast->polls)
      stuck.setHeightSubscriptionStatus(Down({reason: Closed}))
      // The other source decides the wait while the stuck one is mid-poll.
      fast.resolveGetHeightOrThrow(102)
      await fast.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])

      stuck.resolveGetHeightOrThrow(101)
      await Utils.delay(40)
      let pollsAfterDecided = stuck->polls
      await Utils.delay(40)
      t.expect(stuck->polls).toEqual(pollsAfterDecided)
    },
  )

  scenario->Scenario.it(
    "Ignores pushed heights at or below the chain's head",
    ~sources=[{chain: 1337, methods: streaming}],
    async (~t, ~indexer as _, ~source) => {
      let mock = source(1337)
      await reachRealtime(~sync=mock)
      await mock->goLive
      mock.triggerHeightSubscription(105)
      await mock->answerQuery(~fromBlock=102, ~toBlock=105)
      mock.triggerHeightSubscription(102)
      mock.triggerHeightSubscription(103)
      mock.triggerHeightSubscription(105)
      await Utils.delay(10)
      let queriedEarly = mock.pendingItemsQueries->Array.length
      mock.triggerHeightSubscription(106)
      await mock.expectItemsQueries([{fromBlock: 106, reply: LeavePending}])
      t.expect(queriedEarly).toEqual(0)
    },
  )
})
