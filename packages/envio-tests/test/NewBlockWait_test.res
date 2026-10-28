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
let scenario = Scenario.make(~configYaml, ~schema, ~virtualTime=true)

let upTo = toBlock => MockSource.Respond({items: [], latestFetchedBlockNumber: toBlock})

// Backfills the chain to `head` on `sync`, which is where a realtime wait starts.
let backfill = async (~sync: MockSource.t, ~head=100) => {
  sync.resolveGetHeightOrThrow(head)
  await sync.expectItemsQueries([{fromBlock: 1, reply: upTo(head)}])
}

let hasLog = (indexer: IndexerRunner.t, msg) =>
  indexer.allLogsAsJson()->Array.some(line => line->Dict.get("msg") == Some(String(msg)))

let recruitedFallback = "No new blocks detected within 0s. Continuing polling with secondary RPC sources from the configuration."
let slowedDown = "No new blocks detected within 0s. Polling will continue at a reduced rate. For better reliability, refer to our RPC fallback guide: https://docs.envio.dev/docs/HyperIndex/rpc-sync"

describe("Waiting for the first height", () => {
  scenario->Scenario.it(
    "Polls only the sync sources for the first height",
    ~sources=[
      {chain: 1337},
      {chain: 1337, sourceFor: Realtime},
      {chain: 1337, sourceFor: Fallback},
    ],
    async (~t as _, ~indexer, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      await sync.expectNewHeightCalls(1)
      await indexer.advanceTime(20)
      await live.expectNewHeightCalls(0)
      await fallback.expectNewHeightCalls(0)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
    },
  )

  scenario->Scenario.it(
    "Polls every sync source at once and takes the first height to arrive",
    ~sources=[{chain: 1337}, {chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync0 = source(1337)
      let sync1 = source(1337, ~index=1)
      await sync0.expectNewHeightCalls(1)
      await sync1.expectNewHeightCalls(1)
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
    async (~t as _, ~indexer, ~source) => {
      let fast = source(1337)
      let slow = source(1337, ~index=1)
      // No block yet: every answer leaves the wait where it was.
      fast.setAutoHeight(0)
      slow.setAutoHeight(0)
      await fast.expectNewHeightCalls(1)
      await slow.expectNewHeightCalls(1)
      await indexer.advanceTime(15)
      await fast.expectNewHeightCalls(3)
      await slow.expectNewHeightCalls(0)

      fast.setAutoHeight(101)
      await indexer.advanceTime(5)
      await fast.expectNewHeightCalls(1)
      await fast.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await indexer.advanceTime(50)
      await fast.expectNewHeightCalls(0)
      await slow.expectNewHeightCalls(0)
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
      let fail = () => sync.rejectGetHeightOrThrow("ERROR")
      // Each answer, and how long the poll after it is due.
      let steps = [(fail, 4), (fail, 8), (fail, 10), (() => sync.resolveGetHeightOrThrow(0), 1)]
      await sync.expectNewHeightCalls(1)
      for index in 0 to steps->Array.length - 1 {
        let (answer, wait) = steps->Array.getUnsafe(index)
        answer()
        await indexer.advanceTime(wait - 1)
        await sync.expectNewHeightCalls(0)
        await indexer.advanceTime(1)
        await sync.expectNewHeightCalls(1)
      }
      fail()
      await indexer.advanceTime(4)
      await sync.expectNewHeightCalls(1)
      sync.resolveGetHeightOrThrow(101)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(indexer->RealtimeChain.heightRetryIntervals).toEqual(["4", "8", "10", "4"])
    },
  )

  scenario->Scenario.it(
    "Keeps polling a healthy source at its own interval while another one's polls fail",
    ~sources=[{chain: 1337, pollingInterval: 1}, {chain: 1337, pollingInterval: 1}],
    ~sourceTiming={
      getHeightRetryInterval: SourceManager.makeGetHeightRetryInterval(
        ~initialRetryInterval=4,
        ~backoffMultiplicative=2,
        ~maxRetryInterval=10,
      ),
    },
    async (~t, ~indexer, ~source) => {
      let failing = source(1337)
      let healthy = source(1337, ~index=1)
      healthy.setAutoHeight(0)
      await failing.expectNewHeightCalls(1)
      await healthy.expectNewHeightCalls(1)
      for index in 0 to 3 {
        failing.rejectGetHeightOrThrow("ERROR")
        let wait = [4, 8, 10, 10]->Array.getUnsafe(index)
        await indexer.advanceTime(wait)
        await failing.expectNewHeightCalls(1)
        // One a millisecond, whatever the other source's backoff.
        await healthy.expectNewHeightCalls(wait)
      }

      healthy.setAutoHeight(101)
      await indexer.advanceTime(1)
      await healthy.expectNewHeightCalls(1)
      await healthy.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await indexer.advanceTime(50)
      await failing.expectNewHeightCalls(0)
      await healthy.expectNewHeightCalls(0)
      t.expect(indexer->RealtimeChain.heightRetryIntervals).toEqual(["4", "8", "10", "10"])
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
      await sync.expectNewHeightCalls(1)
      await indexer.advanceTime(49)
      await sync.expectNewHeightCalls(49)
      await fallback.expectNewHeightCalls(0)
      let recruitedEarly = indexer->hasLog(recruitedFallback)

      await indexer.advanceTime(1)
      await sync.expectNewHeightCalls(1)
      await fallback.expectNewHeightCalls(1)
      await indexer.advanceTime(50)
      await sync.expectNewHeightCalls(0)

      fallback.resolveGetHeightOrThrow(101)
      // The fallback's height is taken, but the query goes to sync, which
      // never failed one.
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      await indexer.advanceTime(50)
      await sync.expectNewHeightCalls(0)
      await fallback.expectNewHeightCalls(0)
      t.expect((
        recruitedEarly,
        indexer->hasLog(recruitedFallback),
        fallback.pendingItemsQueries,
      )).toEqual((false, true, []))
    },
  )

  scenario->Scenario.it(
    "Keeps polling the only source past the stall",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    ~sourceTiming={newBlockStallTimeout: 20, stalledPollingInterval: 5},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.setAutoHeight(0)
      await sync.expectNewHeightCalls(1)
      await indexer.advanceTime(20)
      await sync.expectNewHeightCalls(20)
      let warned = indexer->hasLog(slowedDown)
      await indexer.advanceTime(5)
      await sync.expectNewHeightCalls(1)
      sync.setAutoHeight(101)
      await indexer.advanceTime(5)
      await sync.expectNewHeightCalls(1)
      await sync.expectItemsQueries([{fromBlock: 1, reply: LeavePending}])
      t.expect(warned).toBe(true)
    },
  )

  scenario->Scenario.it(
    "Slows the only source down to the stalled interval past the stall",
    ~sources=[{chain: 1337, pollingInterval: 1}],
    ~sourceTiming={newBlockStallTimeout: 20, stalledPollingInterval: 500},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.setAutoHeight(0)
      await sync.expectNewHeightCalls(1)
      await indexer.advanceTime(20)
      await sync.expectNewHeightCalls(20)
      await indexer.advanceTime(499)
      await sync.expectNewHeightCalls(0)
      await indexer.advanceTime(1)
      await sync.expectNewHeightCalls(1)
      t.expect(indexer->hasLog(slowedDown)).toBe(true)
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
      await sync.expectNewHeightCalls(2)
      await indexer.advanceTime(9_999)
      await sync.expectNewHeightCalls(0)
      await indexer.advanceTime(1)
      await sync.expectNewHeightCalls(1)
      t.expect(
        indexer->hasLog(
          "Waiting for new blocks with reduced polling (10s) until the indexer enters realtime mode.",
        ),
      ).toBe(true)
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
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      let fallback = source(1337, ~index=2)
      await backfill(~sync)
      await live.expectNewHeightCalls(1)
      // Answers whatever poll sync still has out from the backfill, so any
      // poll it takes from here on is one the realtime wait asked for.
      sync.setAutoHeight(100)
      await sync.expectNewHeightCalls(2)
      await indexer.advanceTime(199)
      await sync.expectNewHeightCalls(0)
      await fallback.expectNewHeightCalls(0)
      live.resolveGetHeightOrThrow(100)

      await indexer.advanceTime(1)
      await sync.expectNewHeightCalls(1)
      await fallback.expectNewHeightCalls(1)
      fallback.resolveGetHeightOrThrow(101)
      // Live never failed a query, so it takes this one whoever found the block.
      await live.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      // Ending the wait wakes sync's loop, and the backfill's last wait, still
      // waiting on sync for a block above 100, asks once more.
      await sync.expectNewHeightCalls(1)
      t.expect((sync.pendingItemsQueries, fallback.pendingItemsQueries)).toEqual(([], []))
    },
  )

  scenario->Scenario.it(
    "Keeps the sync source primary when no live source is configured",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Fallback}],
    async (~t as _, ~indexer, ~source) => {
      let sync = source(1337)
      let fallback = source(1337, ~index=1)
      await backfill(~sync)
      await sync.expectNewHeightCalls(2)
      await indexer.advanceTime(20)
      await fallback.expectNewHeightCalls(0)
      sync.resolveGetHeightOrThrow(101)
      await sync.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
    },
  )

  scenario->Scenario.it(
    "Resumes realtime on the live source after a restart",
    ~sources=[{chain: 1337}, {chain: 1337, sourceFor: Realtime}],
    async (~t as _, ~indexer, ~source) => {
      let sync = source(1337)
      let live = source(1337, ~index=1)
      await backfill(~sync)
      await indexer.getBatchWritePromise()
      await live.expectNewHeightCalls(1)
      await sync.expectNewHeightCalls(2)

      let _ = await indexer.restart()
      await live.expectNewHeightCalls(1)
      await indexer.advanceTime(20)
      await sync.expectNewHeightCalls(0)
      live.resolveGetHeightOrThrow(101)
      await live.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
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
  ~virtualTime=true,
)

describe("Waiting across a sibling's rollback", () => {
  siblingScenario->Scenario.it(
    "Keeps one wait however often the sibling's progress dispatches the chain again",
    ~sources=[
      {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
      {chain: 137, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
    ],
    ~sourceTiming={reducedPollingInterval: 20},
    async (~t, ~indexer, ~source) => {
      let waiting = source(1)
      let sibling = source(137)
      // Its fetchable head sits a reorg depth below the 300 it knows.
      waiting.resolveGetHeightOrThrow(300)
      sibling.resolveGetHeightOrThrow(10_000)
      await waiting.expectItemsQueries([{fromBlock: 1, toBlock: Bounded(100), reply: upTo(100)}])
      waiting.setAutoHeight(300)
      // Spans two of the waiting chain's 40ms stall windows.
      for step in 1 to 6 {
        await sibling.expectItemsQueries([{reply: upTo(step * 100)}])
        await indexer.advanceTime(20)
      }
      t.expect(
        indexer.allLogsAsJson()->Array.filter(
          line =>
            line->Dict.get("chainId") == Some(Number(1.)) &&
              switch line->Dict.get("msg") {
              | Some(String(msg)) => msg->String.startsWith("No new blocks detected")
              | _ => false
              },
        ),
      ).toHaveLength(1)
    },
  )

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
      await indexer.advanceTime(20)
      t.expect((
        waiting.heightSubscriptionCalls->Array.length,
        waiting.pendingItemsQueries->Array.length,
      )).toEqual((1, 1))
    },
  )
})

// A contract registered at the head spawns a partition whose query reports a
// head newer than the source's last height poll.
let registeringScenario = Scenario.make(
  ~configYaml=`
name: new-block-wait-registration
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
      - name: NftFactory
        events:
          - event: "SimpleNftCreated(string name, string symbol, uint256 maxSupply, address contractAddress)"
`,
  ~schema,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async () => {});
`,
  ~virtualTime=true,
)

type contractOps = {add: Address.t => unit}
type registerContext = {chain: {"NftFactory": contractOps}}

let registeringAt = (~blockNumber): MockSource.itemMock => {
  blockNumber,
  logIndex: 0,
  handler: async _ => (),
  contractRegister: async args =>
    (
      args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    ).chain["NftFactory"].add(
      "0x1111111111111111111111111111111111111111"->Address.unsafeFromString,
    ),
}

describe("Catching up a contract registered at the head", () => {
  registeringScenario->Scenario.it(
    "Takes the head the new partition's query reports as the source's own",
    ~sources=[{chain: 1337, pollingInterval: 10_000}],
    ~sourceTiming={newBlockStallTimeout: 20_000},
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({items: [registeringAt(~blockNumber=100)], latestFetchedBlockNumber: 100}),
        },
      ])
      await sync.expectItemsQueries([
        {
          partitionId: "1",
          reply: Respond({items: [], latestFetchedBlockNumber: 100, knownHeight: 105}),
        },
      ])
      await sync.expectItemsQueries([{fromBlock: 101, reply: LeavePending}])
      await sync.expectNewHeightCalls(1)
      t.expect(
        (await indexer.metric("envio_source_known_height"))->Array.map(({value}) => value),
      ).toEqual(["105"])
    },
  )
})
