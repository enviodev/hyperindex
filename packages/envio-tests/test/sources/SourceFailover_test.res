open Vitest

// Which of a chain's sources an items query lands on, as sources fail, get
// excluded for one query, or are benched for good.
let scenario = Scenario.make(
  ~configYaml=`
name: source-failover
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

let withBackoff = MockSource.Fail(Source.Backoff({message: "test", backoffMillis: 0}))

let impossible = MockSource.Fail(Source.WrongSourceForQuery({message: "test impossible"}))

let unsupported = MockSource.Fail(Source.Unusable({message: "test disable"}))

let upTo = toBlock => MockSource.Respond({items: [], latestFetchedBlockNumber: toBlock})

// Fails the query on `failing` until the schedule moves it on, which is the
// third attempt, and answers it on `next`.
let failOver = async (~failing: MockSource.t, ~next: MockSource.t, ~fromBlock, ~toBlock) => {
  for retryCount in 0 to 2 {
    await failing.expectItemsQueries([{fromBlock, retryCount, reply: withBackoff}])
  }
  await next.expectItemsQueries([{fromBlock, retryCount: 3, reply: upTo(toBlock)}])
}

// What an operator is told about a source by name, such as it falling behind.
let sourceLogs = (indexer: IndexerRunner.t) =>
  indexer.infoAndAboveLogs()->Array.filterMap(({msg}) =>
    msg->String.startsWith("MockSource ") ? Some(msg) : None
  )

// How many times items queries moved to another source.
let switchCount = (indexer: IndexerRunner.t) =>
  indexer.infoAndAboveLogs()->Array.filter(({msg}) => msg == "Switching data-source")->Array.length

let gravatar = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
let secondGravatar = "0x1111111111111111111111111111111111111111"

// Two addresses, one group each, so one query can still be in flight on a
// source while the other group's wait holds it.
let twoGroupScenario = Scenario.make(
  ~configYaml=`
name: source-failover-two-groups
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
        address:
          - "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
          - "0x1111111111111111111111111111111111111111"
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

describe("Source failover", () => {
  scenario->Scenario.it(
    "Retries on same source twice before switching, then alternates every second retry",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      // Back to sync once the fallback has had its two attempts: sync failed
      // longest ago, so it is the closest to recovering.
      let attempts = [(sync, 0), (sync, 1), (sync, 2), (fallback, 3), (fallback, 4)]
      for idx in 0 to attempts->Array.length - 1 {
        let (mock, retryCount) = attempts->Array.getUnsafe(idx)
        await mock.expectItemsQueries([{fromBlock: 1, retryCount, reply: withBackoff}])
      }
      await sync.expectItemsQueries([{fromBlock: 1, retryCount: 5, reply: LeavePending}])
      t.expect(fallback.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Keeps retrying a source behind the head for about 10 seconds before failing over",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      // 100ms doubling to a 1s cap: about 10s on the source before the 13th
      // attempt moves to the fallback, paced only by the 50ms floor. A replica
      // only briefly behind its siblings must not be traded away within a few
      // retries.
      let early = await Scenario.failThroughBackoff(
        ~indexer,
        ~source=sync,
        ~alsoWatching=[fallback],
        ~reply=Fail(Source.BehindHead({blockNumber: 1})),
        ~waits=[100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 50],
      )
      await fallback.expectItemsQueries([{retryCount: 13, reply: LeavePending}])
      // The first height, and the poll the hold starts on failing over.
      await sync.expectNewHeightCalls(2)
      t.expect((
        early,
        indexer.allLogsAsJson()->Array.filterMap(
          line =>
            switch line->Dict.get("backOffMilliseconds") {
            | Some(Number(ms)) => Some(ms)
            | _ => None
            },
        ),
      )).toEqual((
        [],
        [100., 200., 400., 800., 1000., 1000., 1000., 1000., 1000., 1000., 1000., 1000., 1000.],
      ))
    },
  )

  // https://github.com/enviodev/hyperindex/issues/1829
  scenario->Scenario.it(
    "Keeps a source that fell behind off queries until its own height moves",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={
      recoveryTimeout: 200.,
      newBlockStallTimeoutRealtime: 10,
      stalledPollingInterval: 50,
      reducedPollingInterval: 1_000,
    },
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      // Sync stops following the chain at 100. The fallback, recruited once the
      // wait stalls, is a single block ahead: too little to tell a stopped
      // source from a block sync hasn't polled yet, so sync takes the query.
      sync.setAutoHeight(100)
      fallback.setAutoHeight(101)
      await indexer.advanceTime(10)
      let early = await Scenario.failThroughBackoff(
        ~indexer,
        ~source=sync,
        ~alsoWatching=[fallback],
        ~reply=Fail(Source.BehindHead({blockNumber: 150})),
        ~waits=[100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 50],
      )
      await fallback.expectItemsQueries([{fromBlock: 101, retryCount: 13, reply: upTo(101)}])

      // Long past the recovery timeout, but sync's height is still 100.
      await indexer.advanceTime(200)
      fallback.setAutoHeight(102)
      await indexer.advanceTime(50)
      await fallback.expectItemsQueries([{fromBlock: 102, reply: upTo(102)}])

      // One block is enough, short of the block it couldn't serve: the source
      // is following its chain again.
      sync.setAutoHeight(101)
      await indexer.advanceTime(1_000)
      fallback.setAutoHeight(103)
      await indexer.advanceTime(50)
      await sync.expectItemsQueries([{fromBlock: 103, reply: LeavePending}])
      t.expect((
        early,
        fallback.pendingItemsQueries,
        indexer->sourceLogs,
        indexer->switchCount,
      )).toEqual((
        [],
        [],
        [
          "MockSource is still catching up to block 150. This is a delay on the provider's side; indexing will continue automatically, using another data source if one is configured.",
        ],
        2,
      ))
    },
  )

  scenario->Scenario.it(
    "Holds a source a stalled wait finds more than a block behind, without querying it, until its height moves",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={
      newBlockStallTimeoutRealtime: 10,
      stalledPollingInterval: 50,
      reducedPollingInterval: 1_000,
    },
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      sync.setAutoHeight(100)
      fallback.setAutoHeight(102)
      await indexer.advanceTime(10)
      await fallback.expectItemsQueries([{fromBlock: 101, reply: upTo(102)}])
      fallback.setAutoHeight(103)
      await indexer.advanceTime(50)
      await fallback.expectItemsQueries([{fromBlock: 103, reply: upTo(103)}])

      sync.setAutoHeight(104)
      await indexer.advanceTime(1_000)
      fallback.setAutoHeight(104)
      await indexer.advanceTime(50)
      await sync.expectItemsQueries([{fromBlock: 104, reply: LeavePending}])
      t.expect((
        sync.pendingItemsQueries->Array.map(query => query.fromBlock),
        indexer->sourceLogs,
        indexer->switchCount,
      )).toEqual(([104], [], 2))
    },
  )

  scenario->Scenario.it(
    "Keeps a held source off queries while it moves but stays more than 200 blocks behind",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={
      newBlockStallTimeoutRealtime: 10,
      stalledPollingInterval: 50,
      reducedPollingInterval: 1_000,
    },
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      sync.setAutoHeight(100)
      fallback.setAutoHeight(400)
      await indexer.advanceTime(10)
      await fallback.expectItemsQueries([{fromBlock: 101, reply: upTo(400)}])

      // Resyncing: it moves, but is still 250 blocks behind.
      sync.setAutoHeight(150)
      await indexer.advanceTime(1_000)
      fallback.setAutoHeight(401)
      await indexer.advanceTime(50)
      await fallback.expectItemsQueries([{fromBlock: 401, reply: upTo(401)}])

      // Within 200 blocks of the head.
      sync.setAutoHeight(250)
      await indexer.advanceTime(1_000)
      fallback.setAutoHeight(402)
      await indexer.advanceTime(50)
      await sync.expectItemsQueries([{fromBlock: 402, reply: LeavePending}])
      t.expect((indexer->sourceLogs, indexer->switchCount)).toEqual(([], 2))
    },
  )

  // https://github.com/enviodev/hyperindex/issues/1829
  twoGroupScenario->Scenario.it(
    "Keeps a source held when a query sent before the hold succeeds",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~maxAddrInPartition=1,
    ~sourceTiming={newBlockStallTimeout: 10, reducedPollingInterval: 1_000},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      // Sync never answers the first height; the fallback, recruited once that
      // stalls, reports 2000.
      fallback.setAutoHeight(2000)
      await indexer.advanceTime(10)
      // Sync stopped at 1000. The second address's first range stays in flight
      // on it.
      await sync.expectItemsQueries([
        {fromBlock: 1, address: gravatar, reply: upTo(1000)},
        {fromBlock: 1, address: secondGravatar, reply: LeavePending},
      ])
      let waits = [100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 50]
      for retryCount in 0 to waits->Array.length - 1 {
        await sync.expectItemsQueries([
          {
            address: gravatar,
            retryCount,
            reply: Fail(Source.BehindHead({blockNumber: 1001})),
          },
        ])
        await indexer.advanceTime(waits->Array.getUnsafe(retryCount))
      }
      await fallback.expectItemsQueries([{fromBlock: 1001, retryCount: 13, reply: upTo(2000)}])

      // The range it was sent before the hold is one it can serve, which shows
      // nothing about the head.
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(1000)}])
      await fallback.expectItemsQueries([{fromBlock: 1001, reply: LeavePending}])
      t.expect(sync.pendingItemsQueries).toEqual([])
    },
  )

  twoGroupScenario->Scenario.it(
    "Doesn't hold a source that was benched while its query was in flight",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~maxAddrInPartition=1,
    ~sourceTiming={reducedPollingInterval: 100},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectNewHeightCalls(1)
      await sync.expectItemsQueries([
        {fromBlock: 1, address: gravatar, reply: LeavePending},
        {fromBlock: 1, address: secondGravatar, reply: LeavePending},
      ])
      let behindHead = MockSource.Fail(Source.BehindHead({blockNumber: 1}))
      let waits = [100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000]
      let gravatarQuery =
        sync.pendingItemsQueries
        ->Array.find(
          query =>
            query->MockSource.addresses->Array.map(Address.toString) == [
                gravatar->String.toLowerCase,
              ],
        )
        ->Option.getOrThrow
      (gravatarQuery->MockSource.control).fail(
        Source.BehindHead({blockNumber: 1}),
        ~requestStats=[],
      )
      await indexer.advanceTime(waits->Array.getUnsafe(0))
      for retryCount in 1 to waits->Array.length - 1 {
        await sync.expectItemsQueries([{retryCount, reply: behindHead}])
        await indexer.advanceTime(waits->Array.getUnsafe(retryCount))
      }
      // The attempt that fails the source over is in flight when the second
      // address's query benches the source.
      await sync.expectItemsQueries([{retryCount: 12, reply: LeavePending}])
      await sync.expectItemsQueries([
        {
          address: secondGravatar,
          retryCount: 0,
          reply: Fail(Source.Unusable({message: "test disable"})),
        },
      ])
      await fallback.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await sync.expectItemsQueries([{retryCount: 12, reply: behindHead}])
      await indexer.advanceTime(50)
      await fallback.expectItemsQueries([{retryCount: 13, reply: LeavePending}])

      // Nothing waits on a benched source, so nothing polls it.
      await indexer.advanceTime(500)
      await sync.expectNewHeightCalls(0)
      t.expect(sync.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Keeps retrying a held fallback once the sync source is benched",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: unsupported}])
      // The fallback is held once it has been behind the head through the
      // window, and there is no other source left to try.
      let early = await Scenario.failThroughBackoff(
        ~indexer,
        ~source=fallback,
        ~reply=Fail(Source.BehindHead({blockNumber: 1})),
        ~waits=[100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000],
      )
      await fallback.expectItemsQueries([{fromBlock: 1, retryCount: 13, reply: LeavePending}])
      t.expect((early, sync.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Moves a query between held sources rather than retrying the same one",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 10, stalledPollingInterval: 50},
    async (~t, ~indexer, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      sync0.resolveGetHeightOrThrow(100)
      sync1.setAutoHeight(100)
      await sync0.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      // Both sync sources stop at 100; the stalled wait recruits the fallback
      // two blocks ahead and holds them both.
      sync0.setAutoHeight(100)
      fallback.setAutoHeight(102)
      await indexer.advanceTime(10)
      // The one source still working can't serve the query.
      await fallback.expectItemsQueries([{fromBlock: 101, reply: impossible}])
      let early = await Scenario.failThroughBackoff(
        ~indexer,
        ~source=sync0,
        ~alsoWatching=[sync1],
        ~reply=Fail(Source.BehindHead({blockNumber: 101})),
        ~waits=[100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000],
      )
      await sync1.expectItemsQueries([{fromBlock: 101, retryCount: 13, reply: LeavePending}])
      t.expect((early, sync0.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Keeps a held source's last failure when it moves but stays far behind",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={
      newBlockStallTimeoutRealtime: 10,
      stalledPollingInterval: 50,
      reducedPollingInterval: 1_000,
    },
    async (~t, ~indexer, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      sync0.resolveGetHeightOrThrow(100)
      sync1.setAutoHeight(100)
      await sync0.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      // Both sync sources stop at 100, far behind the fallback's 1000, which
      // holds them both. The fallback can't serve the query.
      sync0.setAutoHeight(100)
      fallback.setAutoHeight(1000)
      await indexer.advanceTime(10)
      await fallback.expectItemsQueries([{fromBlock: 101, reply: impossible}])

      let behindHead = MockSource.Fail(Source.BehindHead({blockNumber: 101}))
      // Which held source each attempt lands on, and the backoff after it. The
      // last resort takes the one that failed longest ago.
      let attempts = [
        (sync0, 100),
        (sync0, 200),
        (sync0, 400),
        (sync0, 800),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync0, 1000),
        (sync1, 2000),
        (sync1, 4000),
        (sync0, 8000),
        (sync0, 16000),
      ]
      for retryCount in 0 to attempts->Array.length - 1 {
        let (mock, wait) = attempts->Array.getUnsafe(retryCount)
        await mock.expectItemsQueries([{fromBlock: 101, retryCount, reply: behindHead}])
        if retryCount === attempts->Array.length - 1 {
          // Sync0 has just failed, after sync1 did. It moves, but is still 899
          // blocks behind, so it stays held.
          sync0.setAutoHeight(101)
        }
        await indexer.advanceTime(wait)
      }
      await sync1.expectItemsQueries([{fromBlock: 101, retryCount: 17, reply: LeavePending}])
      t.expect(sync0.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Stays on a healthy primary however short the recovery timeout",
    ~sources=[
      {chain: 1337, pollingInterval: 1},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 1},
    ],
    ~sourceTiming={recoveryTimeout: 0.},
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      for head in 101 to 105 {
        sync.setAutoHeight(head)
        await sync.expectItemsQueries([{fromBlock: head, reply: upTo(head)}])
      }
      t.expect(fallback.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Stays on a healthy live source in realtime however short the recovery timeout",
    ~sources=[
      {chain: 1337, pollingInterval: 1},
      {chain: 1337, sourceFor: Realtime, pollingInterval: 1},
    ],
    ~sourceTiming={recoveryTimeout: 0.},
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])
      sync.setAutoHeight(100)
      for head in 101 to 105 {
        live.setAutoHeight(head)
        await live.expectItemsQueries([{fromBlock: head, reply: upTo(head)}])
      }
      t.expect(sync.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Queries the primary right after a fallback answered the wait, since it never failed",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    // Recruits the fallback for the very first wait.
    ~sourceTiming={newBlockStallTimeout: 0},
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      await Scenario.resolveInitialHeight(~source=fallback, ~head=100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(fallback.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Goes back to a failed primary only once the recovery timeout has passed, every time it fails",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={recoveryTimeout: 200.},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      // A new head reaches the chain on the next poll.
      let newHead = async head => {
        [sync, fallback]->Array.forEach(mock => mock.setAutoHeight(head))
        await indexer.advanceTime(50)
      }
      sync.resolveGetHeightOrThrow(100)
      await failOver(~failing=sync, ~next=fallback, ~fromBlock=1, ~toBlock=100)

      // Sync is still within its recovery timeout.
      await newHead(101)
      await fallback.expectItemsQueries([{fromBlock: 101, reply: upTo(101)}])

      await indexer.advanceTime(200)
      await newHead(102)
      // A success clears the failure, so failing again starts a fresh recovery
      // timeout rather than counting from the first one.
      await failOver(~failing=sync, ~next=fallback, ~fromBlock=102, ~toBlock=102)

      await newHead(103)
      await fallback.expectItemsQueries([{fromBlock: 103, reply: upTo(103)}])

      await indexer.advanceTime(200)
      await newHead(104)
      await sync.expectItemsQueries([{fromBlock: 104, reply: LeavePending}])
      t.expect(fallback.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Keeps querying the source that answered the wait over an earlier one of the same rank",
    ~sources=[{chain: 1337}, {chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      await sync0.expectNewHeightCalls(1)
      sync1.resolveGetHeightOrThrow(100)
      await sync1.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(sync0.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Moves a query its source can't serve on to another one, without benching that source",
    ~sources=[{chain: 1337}, {chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      sync0.resolveGetHeightOrThrow(100)
      await sync0.expectItemsQueries([{fromBlock: 1, reply: impossible}])
      await sync1.expectItemsQueries([{fromBlock: 1, retryCount: 0, reply: upTo(100)}])

      // sync1 answered last, so the next query starts there. When it can't
      // serve that one, sync0 can still take it: an impossible query is no
      // failure of the source's.
      sync1.setAutoHeight(101)
      await sync1.expectItemsQueries([{fromBlock: 101, reply: impossible}])
      await sync0.expectItemsQueries([{fromBlock: 101, retryCount: 0, reply: LeavePending}])
      t.expect(sync1.pendingItemsQueries).toEqual([])
    },
  )

  scenario->Scenario.it(
    "Excludes every source a query is impossible on, one after another",
    ~sources=[{chain: 1337}, {chain: 1337}, {chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      let sync2 = source(1337, ~index=2)
      sync0.resolveGetHeightOrThrow(100)
      await sync0.expectItemsQueries([{fromBlock: 1, reply: impossible}])
      await sync1.expectItemsQueries([{fromBlock: 1, reply: impossible}])
      await sync2.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect((sync0.pendingItemsQueries, sync1.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Falls back to a secondary source once every primary is excluded",
    ~sources=[{chain: 1337}, {chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t, ~indexer as _, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      sync0.resolveGetHeightOrThrow(100)
      await sync0.expectItemsQueries([{fromBlock: 1, reply: impossible}])
      await sync1.expectItemsQueries([{fromBlock: 1, reply: impossible}])
      await fallback.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect((sync0.pendingItemsQueries, sync1.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Keeps realtime on the remaining live source when one is benched, and on sync once both are",
    ~sources=[
      {chain: 1337},
      {chain: 1337, sourceFor: Realtime},
      {chain: 1337, sourceFor: Realtime},
    ],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let live0 = source(1337, ~index=1)
      let live1 = source(1337, ~index=2)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])

      live0.setAutoHeight(101)
      await live0.expectItemsQueries([{fromBlock: 101, reply: unsupported}])
      await live1.expectItemsQueries([{fromBlock: 101, reply: upTo(101)}])

      live1.setAutoHeight(102)
      await live1.expectItemsQueries([{fromBlock: 102, reply: unsupported}])
      await sync.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])
      t.expect((live0.pendingItemsQueries, live1.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Keeps realtime on the live source after the sync source is benched",
    ~sources=[
      {chain: 1337},
      {chain: 1337, sourceFor: Realtime},
      {chain: 1337, sourceFor: Fallback},
    ],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      sync.resolveGetHeightOrThrow(100)
      // Live sources play no part in a backfill, so the fallback takes over.
      await sync.expectItemsQueries([{fromBlock: 1, reply: unsupported}])
      await fallback.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])

      live.setAutoHeight(101)
      await live.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect((sync.pendingItemsQueries, fallback.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Doesn't poll a benched source as a stall fallback",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Realtime}],
    ~sourceTiming={newBlockStallTimeoutRealtime: 5},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(100)}])

      live.setAutoHeight(101)
      await live.expectItemsQueries([{fromBlock: 101, reply: unsupported}])
      await sync.expectItemsQueries([{fromBlock: 101, reply: upTo(101)}])
      await live.expectNewHeightCalls(1)

      // Several stall windows of the realtime wait that follows.
      await indexer.advanceTime(50)
      await live.expectNewHeightCalls(0)
      // The stall did run, and found nothing left to recruit.
      t.expect(
        indexer.allLogsAsJson()->Array.some(
          line =>
            line->Dict.get("msg") ==
              Some(
                String(
                  "No new blocks detected within 0s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync",
                ),
              ),
        ),
      ).toBe(true)
    },
  )
})
