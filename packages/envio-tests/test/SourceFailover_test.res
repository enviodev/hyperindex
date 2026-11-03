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
    "Tells the operator each time a query moves to another source",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.resolveGetHeightOrThrow(100)
      // Over to the fallback, and back.
      let attempts = [(sync, 0), (sync, 1), (sync, 2), (fallback, 3), (fallback, 4)]
      for idx in 0 to attempts->Array.length - 1 {
        let (mock, retryCount) = attempts->Array.getUnsafe(idx)
        await mock.expectItemsQueries([{fromBlock: 1, retryCount, reply: withBackoff}])
      }
      await sync.expectItemsQueries([{fromBlock: 1, retryCount: 5, reply: LeavePending}])
      t.expect(
        indexer.infoAndAboveLogs()->Array.filterMap(
          ({msg, params}) =>
            msg === "Switching data-source"
              ? Some((params->Dict.get("source"), params->Dict.get("fromBlock")))
              : None,
        ),
      ).toEqual([
        (Some(JSON.String("MockSource")), Some(JSON.Number(1.))),
        (Some(JSON.String("MockSource")), Some(JSON.Number(1.))),
      ])
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

  scenario->Scenario.it(
    "Tries the primary that failed longest ago first once every source is recovering",
    ~sources=[
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, pollingInterval: 50},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 50},
    ],
    ~sourceTiming={recoveryTimeout: 1000.},
    async (~t, ~indexer, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      sync0.resolveGetHeightOrThrow(100)
      await failOver(~failing=sync0, ~next=sync1, ~fromBlock=1, ~toBlock=100)
      // Long enough for sync0 to have recovered by the time sync1 fails.
      sync1.setAutoHeight(101)
      await indexer.advanceTime(1000)
      for retryCount in 0 to 2 {
        await sync1.expectItemsQueries([{fromBlock: 101, retryCount, reply: withBackoff}])
      }
      // sync0 fails a little after sync1, then the fallback: every source is
      // recovering, and sync1 has been at it the longest.
      await indexer.advanceTime(10)
      for retryCount in 3 to 4 {
        await sync0.expectItemsQueries([{fromBlock: 101, retryCount, reply: withBackoff}])
      }
      for retryCount in 5 to 6 {
        await fallback.expectItemsQueries([{fromBlock: 101, retryCount, reply: withBackoff}])
      }
      await sync1.expectItemsQueries([{fromBlock: 101, retryCount: 7, reply: LeavePending}])
      t.expect((sync0.pendingItemsQueries, fallback.pendingItemsQueries)).toEqual(([], []))
    },
  )

  let stopped = []
  scenario->Scenario.it(
    "Stops the indexer once a query is impossible on every source it has",
    ~sources=[{chain: 1337}],
    ~onError=errHandler => stopped->Array.push(errHandler->ErrorHandling.toExn)->ignore,
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: impossible}])
      await Scenario.waitUntil(() => stopped->Array.length > 0, ~message="the indexer to stop")
      t.expect(
        stopped->Array.map(exn => (exn->(Utils.magic: exn => {"message": string}))["message"]),
      ).toEqual([
        // Nothing was benched, so there is no reason to give beyond the logs.
        "The indexer doesn't have data-sources which can continue fetching. Please, check the error logs or reach out to the Envio team.",
      ])
    },
  )
})

let twoPartitions = Scenario.make(
  ~configYaml=`
name: source-failover-partitions
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
          - "0x0000000000000000000000000000000000000002"
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

describe("Source failover across partitions", () => {
  twoPartitions->Scenario.it(
    "Benches a source once, and says why once, when every partition finds it can't serve the selection",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    // One partition per address, so both queries fail on the source at once.
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      let fieldSelection = MockSource.Fail(
        Source.GetItemsError(
          FailedGettingFieldSelection({
            message: "The source can't serve the selected fields.",
            blockNumber: 1,
            requestStats: [],
          }),
        ),
      )
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {partitionId: "0", reply: fieldSelection},
        {partitionId: "1", reply: fieldSelection},
      ])
      await fallback.expectItemsQueries([
        {partitionId: "0", retryCount: 0, reply: LeavePending},
        {partitionId: "1", retryCount: 0, reply: LeavePending},
      ])
      t.expect(
        indexer.infoAndAboveLogs()->Array.filterMap(
          ({msg, params}) =>
            msg === "The source can't serve the selected fields."
              ? Some((params->Dict.get("source"), params->Dict.get("blockNumber")))
              : None,
        ),
      ).toEqual([(Some(JSON.String("MockSource")), Some(JSON.Number(1.)))])
    },
  )

  twoPartitions->Scenario.it(
    "Reports how many partition queries are out on the chain's sources",
    ~sources=[{chain: 1337}],
    ~maxAddrInPartition=1,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let concurrency = async () =>
        (await indexer.metric("envio_indexing_concurrency"))->Array.map(({value}) => value)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {partitionId: "0", reply: LeavePending},
        {partitionId: "1", reply: LeavePending},
      ])
      let bothOut = await concurrency()
      await sync.expectItemsQueries([
        {partitionId: "0", reply: upTo(100)},
        {partitionId: "1", reply: LeavePending},
      ])
      await indexer.advanceTime(0)
      let oneOut = await concurrency()
      t.expect((bothOut, oneOut)).toEqual((["2"], ["1"]))
    },
  )

  twoPartitions->Scenario.it(
    "Counts the time the chain spent waiting for a block apart from the time it spent querying",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let counted = async name =>
        (await indexer.metric(name))->Array.map(
          ({value}) => value->Float.fromString->Option.getOr(0.) > 0.,
        )
      // Real time: these counters time the source layer on the wall clock.
      await Utils.delay(20)
      let whileWaiting = (
        await counted("envio_indexing_source_waiting_seconds"),
        await counted("envio_indexing_source_querying_seconds"),
      )
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      // Real time: as above.
      await Utils.delay(20)
      let whileQuerying = await counted("envio_indexing_source_querying_seconds")
      t.expect((whileWaiting, whileQuerying)).toEqual((([true], [false]), [true]))
    },
  )
})
