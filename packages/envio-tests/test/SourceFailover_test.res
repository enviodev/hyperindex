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
  ~virtualTime=true,
)

let withBackoff = MockSource.Fail(
  Source.GetItemsError(
    FailedGettingItems({
      requestStats: [],
      attemptedToBlock: 100,
      retry: WithBackoff({message: "test", backoffMillis: 0}),
    }),
  ),
)

let impossible = MockSource.Fail(
  Source.GetItemsError(
    FailedGettingItems({
      requestStats: [],
      attemptedToBlock: 100,
      retry: ImpossibleForTheQuery({message: "test impossible"}),
    }),
  ),
)

let unsupported = MockSource.Fail(
  Source.GetItemsError(UnsupportedSelection({message: "test disable"})),
)

let upTo = toBlock => MockSource.Respond({items: [], latestFetchedBlockNumber: toBlock})

// Fails the query on `failing` until the schedule moves it on, which is the
// third attempt, and answers it on `next`.
let failOver = async (~failing: MockSource.t, ~next: MockSource.t, ~fromBlock, ~toBlock) => {
  for retryCount in 0 to 2 {
    await failing.expectItemsQueries([{fromBlock, retryCount, reply: withBackoff}])
  }
  await next.expectItemsQueries([{fromBlock, retryCount: 3, reply: upTo(toBlock)}])
}

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
        ~reply=Fail(Source.SourceBehindHead({blockNumber: 1, requestStats: []})),
        ~waits=[100, 200, 400, 800, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 50],
      )
      await fallback.expectItemsQueries([{retryCount: 13, reply: LeavePending}])
      await sync.expectNewHeightCalls(1)
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
      await fallback.expectHeightCalls(1)
      fallback.resolveGetHeightOrThrow(100)
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
      await sync0.expectHeightCalls(1)
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
