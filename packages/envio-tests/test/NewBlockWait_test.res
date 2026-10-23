open Vitest

// How a chain waits for its next block: which sources it polls, how often, and
// who it recruits when they all go quiet.
let configYaml = `
name: new-block-wait
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
`
let schema = `
type Gravatar {
  id: ID!
  owner: String!
}
`
let scenario = Scenario.make(~configYaml, ~schema)

let polls = (mock: MockSource.t) => mock.getHeightOrThrowCalls->Array.length

let upTo = toBlock => MockSource.Respond({items: [], latestFetchedBlockNumber: toBlock})

// Backfills the chain to `head` on `sync`, which is where a realtime wait starts.
let backfill = async (~sync: MockSource.t, ~head=100) => {
  sync.resolveGetHeightOrThrow(head)
  await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(head)}])
}

let hasLog = (indexer: IndexerRunner.t, msg) =>
  indexer.allLogsAsJson()->Array.some(line => line->Dict.get("msg") == Some(String(msg)))

let waitForLog = (indexer, msg) =>
  Scenario.waitUntil(() => indexer->hasLog(msg), ~message=`the log "${msg}"`)

describe("Waiting for the first height", () => {
  scenario->Scenario.it(
    "Polls only the sync sources for the first height",
    ~sources=[
      {chain: 1337},
      {chain: 1337, sourceFor: Realtime},
      {chain: 1337, sourceFor: Fallback},
    ],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      await sync.expectHeightCalls(1)
      await Utils.delay(20)
      let (livePolls, fallbackPolls) = (live->polls, fallback->polls)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect((livePolls, fallbackPolls)).toEqual((0, 0))
    },
  )

  scenario->Scenario.it(
    "Polls every sync source at once and takes the first height to arrive",
    ~sources=[{chain: 1337}, {chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      await sync0.expectHeightCalls(1)
      await sync1.expectHeightCalls(1)
      // The higher height arrives second, so it loses.
      sync1.resolveGetHeightOrThrow(2)
      sync0.resolveGetHeightOrThrow(3)
      await sync1.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(await indexer.metric("envio_indexing_known_height")).toEqual([
        {value: "2", labels: dict{"chainId": "1337"}},
      ])
    },
  )

  scenario->Scenario.it(
    "Polls each source at its own interval until a new block arrives, then stops",
    ~sources=[{chain: 1337, pollingInterval: 5}, {chain: 1337, pollingInterval: 10_000}],
    async (~t, ~indexer as _, ~source) => {
      let fast = source(1337)
      let slow = source(1337, ~index=1)
      // No block yet: every answer leaves the wait where it was.
      fast.setAutoHeight(0)
      slow.setAutoHeight(0)
      await fast.expectHeightCalls(4)
      let slowPolls = slow->polls

      fast.setAutoHeight(101)
      await fast.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      let pollsAtAnswer = (fast->polls, slow->polls)
      await Utils.delay(50)
      t.expect((slowPolls, (fast->polls, slow->polls))).toEqual((1, pollsAtAnswer))
    },
  )

  scenario->Scenario.it(
    "Backs a failing height poll off further each time, starting over after an answer",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    ~sourceTiming={
      getHeightRetryInterval: SourceManager.makeGetHeightRetryInterval(
        ~initialRetryInterval=4,
        ~backoffMultiplicative=2,
        ~maxRetryInterval=10,
      ),
    },
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let calls = ref(0)
      let next = async answer => {
        calls := calls.contents + 1
        await sync.expectHeightCalls(calls.contents)
        answer()
      }
      let fail = () => sync.rejectGetHeightOrThrow("ERROR")
      await next(fail)
      await next(fail)
      await next(fail)
      await next(() => sync.resolveGetHeightOrThrow(0))
      await next(fail)
      await next(() => sync.resolveGetHeightOrThrow(101))
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])

      t.expect(
        indexer.allLogsAsJson()->Array.filterMap(
          line =>
            switch line->Dict.get("msg") {
            | Some(String(msg)) =>
              msg
              ->String.match(/^Height retrieval from MockSource source .*Retrying in (\d+)ms\.$/)
              ->Option.flatMap(match => match->Array.get(1)->Option.flatMap(x => x))
            | _ => None
            },
        ),
      ).toEqual(["4", "8", "10", "4"])
    },
  )

  scenario->Scenario.it(
    "Recruits the fallback once the first height stalls, and slows every poll down",
    ~sources=[
      {chain: 1337, pollingInterval: 1},
      {chain: 1337, sourceFor: Fallback, pollingInterval: 1},
    ],
    ~sourceTiming={newBlockStallTimeout: 50, stalledPollingInterval: 10_000},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      sync.setAutoHeight(0)
      await sync.expectHeightCalls(3)
      let fallbackPollsBeforeStall = fallback->polls

      await indexer->waitForLog(
        "No new blocks detected within 0s. Continuing polling with secondary RPC sources from the configuration.",
      )
      await fallback.expectHeightCalls(1)
      let syncPollsAtStall = sync->polls
      await Utils.delay(50)
      let syncPollsAfterStall = sync->polls

      fallback.resolveGetHeightOrThrow(101)
      // The fallback's height is taken, but the query goes to sync, which
      // never failed one.
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect((
        fallbackPollsBeforeStall,
        syncPollsAfterStall - syncPollsAtStall <= 1,
        fallback.pendingItemsQueries,
      )).toEqual((0, true, []))
    },
  )

  scenario->Scenario.it(
    "Keeps polling the only source past the stall",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    ~sourceTiming={newBlockStallTimeout: 20, stalledPollingInterval: 5},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.setAutoHeight(0)
      await indexer->waitForLog(
        "No new blocks detected within 0s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync",
      )
      await sync.expectHeightCalls(sync->polls + 1)
      sync.setAutoHeight(101)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(sync.pendingItemsQueries->Array.length).toEqual(1)
    },
  )
})

describe("Waiting for a new block during backfill", () => {
  scenario->Scenario.it(
    "Polls at the reduced interval while the chain is held back from realtime",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    ~sourceTiming={reducedPollingInterval: 10_000},
    ~holdRealtime=true,
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      await backfill(~sync)
      sync.setAutoHeight(100)
      await indexer->waitForLog(
        "Waiting for new blocks with reduced polling (10s) until the indexer enters realtime mode.",
      )
      await Utils.delay(10)
      let pollsAtWait = sync->polls
      await Utils.delay(50)
      t.expect(sync->polls).toEqual(pollsAtWait)
    },
  )
})

describe("Waiting for a new block in realtime", () => {
  scenario->Scenario.it(
    "Polls the live source alone, recruits the others once it stalls, and still queries live",
    ~sources=[
      {chain: 1337, pollingInterval: 1},
      {chain: 1337, sourceFor: Realtime},
      {chain: 1337, sourceFor: Fallback},
    ],
    ~sourceTiming={newBlockStallTimeoutRealtime: 200},
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      await backfill(~sync)
      await live.expectHeightCalls(1)
      // Answers whatever poll sync still has out from the backfill, so any
      // poll it takes from here on is one the realtime wait asked for.
      sync.setAutoHeight(100)
      let syncPolls = sync->polls
      await Utils.delay(50)
      let beforeStall = (sync->polls - syncPolls, fallback->polls)
      live.resolveGetHeightOrThrow(100)

      await sync.expectHeightCalls(syncPolls + 1)
      await fallback.expectHeightCalls(1)
      fallback.resolveGetHeightOrThrow(101)
      // Live never failed a query, so it takes this one whoever found the block.
      await live.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect((beforeStall, sync.pendingItemsQueries, fallback.pendingItemsQueries)).toEqual((
        (0, 0),
        [],
        [],
      ))
    },
  )

  scenario->Scenario.it(
    "Keeps the sync source primary when no live source is configured",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      await backfill(~sync)
      await sync.expectHeightCalls(2)
      await Utils.delay(20)
      let fallbackPolls = fallback->polls
      sync.resolveGetHeightOrThrow(101)
      await sync.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(fallbackPolls).toEqual(0)
    },
  )

  scenario->Scenario.it(
    "Resumes realtime on the live source after a restart",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Realtime}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      await backfill(~sync)
      await indexer.getBatchWritePromise()
      await live.expectHeightCalls(1)
      let syncPolls = sync->polls
      let livePolls = live->polls

      let _ = await indexer.restart()
      await live.expectHeightCalls(livePolls + 1)
      await Utils.delay(20)
      let syncPollsAfterRestart = sync->polls
      live.resolveGetHeightOrThrow(101)
      await live.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      t.expect(syncPollsAfterRestart).toEqual(syncPolls)
    },
  )
})

describe("Chain sources", () => {
  Async.it("Refuses to start a chain without a sync source", async t => {
    let failure = try {
      await scenario->Scenario.run(
        ~sources=[{chain: 1337, sourceFor: Fallback}],
        async (~indexer as _, ~source as _) => (),
      )
      None
    } catch {
    // The run appends where its logs went.
    | JsExn(exn) => exn->JsExn.message->Option.flatMap(msg => msg->String.split("\n")->Array.get(0))
    }
    t.expect(failure).toEqual(
      Some("Invalid configuration, no data-source for historical sync provided"),
    )
  })
})

// A rollback starts a fresh wait on every chain without cancelling the one it
// supersedes, so a chain waiting at the head while its sibling rolls back has
// two waits on the same source.
let siblingScenario = Scenario.make(
  ~configYaml=`
name: new-block-wait-sibling-rollback
disable_default_cross_chain: true
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema,
)

describe("Waiting across a sibling's rollback", () => {
  siblingScenario->Scenario.it(
    "Subscribes once and fetches the next block once",
    ~sources=[
      {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #createHeightSubscription]},
      {
        chain: 137,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        pollingInterval: 1,
      },
    ],
    async (~t, ~indexer, ~source) => {
      let waiting = source(1)
      let sibling = source(137)
      waiting.resolveGetHeightOrThrow(300)
      sibling.resolveGetHeightOrThrow(300)
      await waiting.expectItemsQueries([{fromBlock: 1, toBlock: Bounded(100), reply: upTo(100)}])
      await sibling.expectItemsQueries([{fromBlock: 1, toBlock: Bounded(100), reply: upTo(100)}])
      await indexer.getBatchWritePromise()
      await waiting.expectItemsQueries([{fromBlock: 101, reply: upTo(300)}])
      await sibling.expectItemsQueries([{fromBlock: 101, reply: upTo(300)}])
      await indexer.waitUntilReady()
      await Scenario.waitUntil(
        () => waiting.heightSubscriptionCalls->Array.length > 0,
        ~message="the height subscription",
      )

      // The sibling finds block 300 re-orged and rolls back.
      sibling.setAutoHeight(301)
      await sibling.expectItemsQueries([
        {
          fromBlock: 301,
          reply: Respond({
            items: [],
            latestFetchedBlockNumber: 301,
            prevRangeLastBlock: {blockNumber: 300, blockHash: "0x300a"},
          }),
        },
      ])
      await indexer.getRollbackReadyPromise()
      // No stored block to look up, so it refetches from the threshold.
      await sibling.expectItemsQueries([{fromBlock: 102, reply: LeavePending}])

      waiting.setHeightSubscriptionStatus(Live)
      waiting.setAutoHeight(300)
      waiting.triggerHeightSubscription(301)
      await waiting.expectItemsQueries([{fromBlock: 301, reply: LeavePending}])
      await Utils.delay(20)
      t.expect((
        waiting.heightSubscriptionCalls->Array.length,
        waiting.pendingItemsQueries->Array.length,
      )).toEqual((1, 1))
    },
  )
})
