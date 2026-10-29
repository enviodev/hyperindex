open Vitest

// A chain at head with a partition query in flight while a reorg on a sibling
// chain triggers a rollback: the epoch bump drops the in-flight response and
// prepareReorg/rollback rebuild the chain's partitions. Afterwards the chain
// must keep fetching — the incident on chain 42161 froze here: waits kept
// resolving block after block while getNextQuery never produced a query again.
let configYaml = (~name, ~extra="") =>
  `
name: ${name}${extra}
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address:
          - "0x0000000000000000000000000000000000000001"
          - "0x0000000000000000000000000000000000000002"
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let handlers = `
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
`

// The default cross-chain Counter keeps this on the global rollback path, where
// the sibling chain is rolled back along with the reorg chain.
let scenario = Scenario.make(
  ~configYaml=configYaml(~name="sibling-rollback"),
  ~schema,
  ~handlers,
)

// The same incident with a per-chain schema, where the rollback stays isolated
// to the reorg chain: the sibling keeps its progress, and must still carry on
// fetching after its in-flight response is dropped.
let perChainScenario = Scenario.make(
  ~configYaml=configYaml(
    ~name="sibling-rollback-per-chain",
    ~extra="\ndisable_default_cross_chain: true",
  ),
  ~schema,
  ~handlers,
)

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {@as("Counter") counter: counterOps}

let setCounter = (~block, ~count: bigint): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
    context.counter.set({"id": "total", "count": count})
  },
}

type tokenOps = {add: Address.t => unit}
type registerContext = {chain: {"Token": tokenOps}}

// Registers a dynamic Token address, like the factory events the incident
// chain indexed. Re-runs when the block is re-fetched after a rollback.
let registerToken = (~block): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 1,
  handler: async _ => (),
  contractRegister: async args => {
    let context = args.context->(Utils.magic: Internal.contractRegisterContext => registerContext)
    context.chain["Token"].add(
      "0x0000000000000000000000000000000000000003"->Address.unsafeFromString,
    )
  },
}

let sources: array<Scenario.sourceMock> = [
  {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes], pollingInterval: 1},
  {chain: 137, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes], pollingInterval: 1},
]

let victimProgress = async (indexer: IndexerRunner.t) =>
  (await indexer.metric("envio_progress_block"))
  ->Array.find(metric => metric.labels->Dict.get("chainId") === Some("1"))
  ->Option.map(metric => metric.value)

describe("Sibling-chain rollback with an in-flight query", () => {
  // Drives both chains to the head, leaves a victim-chain query in flight and
  // reorgs the sibling under it. Shared by the two schemas, which differ only in
  // how far the resulting rollback reaches.
  let runIncident = async (
    ~indexer: IndexerRunner.t,
    ~source: (int, ~index: int=?) => MockSource.t,
  ) => {
    let victim = source(1)
    let sibling = source(137)
    victim.resolveGetHeightOrThrow(300)
    sibling.resolveGetHeightOrThrow(300)

    // Pre-threshold queries stop at 100 (head - maxReorgDepth).
    await victim.expectItemsQueries([
      {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), reply: Respond({items: []})},
      {partitionId: "1", fromBlock: 1, toBlock: Bounded(100), reply: Respond({items: []})},
    ])
    await sibling.expectItemsQueries([
      {partitionId: "0", fromBlock: 1, toBlock: Bounded(100), reply: Respond({items: []})},
    ])
    await indexer.getBatchWritePromise()

    // Post-threshold queries reach the head. The victim's response also
    // registers a dynamic Token address at block 250, spawning a catch-up
    // partition mid-response like the incident chain's factory events. Both
    // partitions get the same response, the way the incident chain saw the
    // same factory events through every address partition.
    let victimItems = [setCounter(~block=200, ~count=1n), registerToken(~block=250)]
    await victim.expectItemsQueries([
      {
        partitionId: "0",
        fromBlock: 101,
        reply: Respond({items: victimItems, latestFetchedBlockNumber: 300}),
      },
      {
        partitionId: "1",
        fromBlock: 101,
        reply: Respond({items: victimItems, latestFetchedBlockNumber: 300}),
      },
    ])
    await sibling.expectItemsQueries([
      {
        partitionId: "0",
        fromBlock: 101,
        reply: Respond({
          items: [setCounter(~block=200, ~count=2n)],
          latestFetchedBlockNumber: 300,
        }),
      },
    ])
    await indexer.getBatchWritePromise()

    // The dynamic partition catches up to the head.
    await victim.expectItemsQueries([
      {
        partitionId: "2",
        fromBlock: 250,
        reply: Respond({items: [], latestFetchedBlockNumber: 300}),
      },
    ])
    await indexer.waitUntilReady()

    // New block on the victim chain. The first partition queries it; its
    // response lands, which schedules the tick that sends the second
    // partition's query — that one stays in flight through the rollback,
    // like partition 7 in the incident.
    // The chain re-polls at its own cadence through the rollback, so give it a
    // standing answer rather than one answer per poll.
    victim.setAutoHeight(301)
    await victim.expectItemsQueries([
      {
        partitionId: "0",
        fromBlock: 301,
        reply: Respond({items: [], latestFetchedBlockNumber: 301}),
      },
    ])
    await victim.expectItemsQueries([{partitionId: "1", fromBlock: 301, reply: LeavePending}])

    // Reorg on the sibling chain: block 300 comes back with a different hash.
    sibling.setAutoHeight(301)
    let reorgsBefore = sibling.reorgCallCount()
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
    await Scenario.waitUntil(
      () => sibling.reorgCallCount() > reorgsBefore,
      ~message="the sibling's reorg to be detected",
    )
    // The victim's in-flight responses land inside the rollback window —
    // after the reorg was detected but before the rollback applied.
    await victim.expectItemsQueries([
      {
        partitionId: "1",
        fromBlock: 301,
        reply: Respond({items: [], latestFetchedBlockNumber: 301}),
      },
      {
        partitionId: "2",
        fromBlock: 301,
        reply: Respond({items: [], latestFetchedBlockNumber: 301}),
      },
    ])
    // The depth search asks about block 200, which the source still agrees with.
    await sibling.expectBlockHashLookup({
      blockNumbers: [200],
      reply: [{blockNumber: 200, blockHash: "0x200", blockTimestamp: 200}],
    })
    await indexer.getRollbackReadyPromise()

    let progressAfterRollback = await victimProgress(indexer)

    // Both chains must resume fetching after the rollback and refetch their
    // rolled-back ranges. The victim chain is wedged if it never catches back
    // up to the head.
    victim.setAutoHeight(302)
    sibling.setAutoHeight(302)
    progressAfterRollback
  }

  scenario->Scenario.it(
    "chain keeps fetching after its in-flight response is dropped by a sibling rollback",
    ~sources,
    // Two addresses on chain 1 -> two partitions, so one partition's query
    // can stay in flight while the other's response lands.
    ~maxAddrInPartition=1,
    ~sourceTiming={reducedPollingInterval: 1},
    async (~t, ~indexer, ~source) => {
      let progressAfterRollback = await runIncident(~indexer, ~source)
      let victim = source(1)
      let sibling = source(137)

      // The victim refetches from the rolled-back block 250, re-registering the
      // pruned dynamic address when the block is re-delivered.
      await victim.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 250,
          reply: Respond({items: [registerToken(~block=250)], latestFetchedBlockNumber: 302}),
        },
      ])
      await sibling.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 201,
          reply: Respond({items: [], latestFetchedBlockNumber: 302}),
        },
      ])
      await victim.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 250,
          reply: Respond({items: [registerToken(~block=250)], latestFetchedBlockNumber: 302}),
        },
        {
          partitionId: "2",
          fromBlock: 250,
          reply: Respond({items: [registerToken(~block=250)], latestFetchedBlockNumber: 302}),
        },
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (progressAfterRollback, await victimProgress(indexer)),
        ~message="the victim chain gives back the progress the global rollback took, then catches up again",
      ).toEqual((Some("249"), Some("302")))
    },
  )

  perChainScenario->Scenario.it(
    "chain keeps fetching and is never rolled back when the reorg stays isolated",
    ~sources,
    ~maxAddrInPartition=1,
    ~sourceTiming={reducedPollingInterval: 1},
    async (~t, ~indexer, ~source) => {
      let progressAfterRollback = await runIncident(~indexer, ~source)
      let victim = source(1)
      let sibling = source(137)

      await sibling.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 201,
          reply: Respond({items: [], latestFetchedBlockNumber: 302}),
        },
      ])
      // Only the queries the rollback dropped are re-issued.
      await victim.expectItemsQueries([
        {
          partitionId: "1",
          fromBlock: 301,
          reply: Respond({items: [], latestFetchedBlockNumber: 302}),
        },
        {
          partitionId: "2",
          fromBlock: 301,
          reply: Respond({items: [], latestFetchedBlockNumber: 302}),
        },
      ])
      await victim.expectItemsQueries([
        {
          partitionId: "0",
          fromBlock: 302,
          reply: Respond({items: [], latestFetchedBlockNumber: 302}),
        },
      ])
      await indexer.waitUntilIdle()

      t.expect(
        (progressAfterRollback, await victimProgress(indexer)),
        ~message="the victim chain keeps its progress and only re-issues the query the rollback dropped",
      ).toEqual((Some("300"), Some("302")))
    },
  )
})
