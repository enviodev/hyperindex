open Vitest

// A chain at head with a partition query in flight while a reorg on a sibling
// chain triggers a rollback: the epoch bump drops the in-flight response and
// prepareReorg/rollback rebuild the chain's partitions. Afterwards the chain
// must keep fetching — the incident on chain 42161 froze here: waits kept
// resolving block after block while getNextQuery never produced a query again.
let scenario = Scenario.make(
  ~configYaml=`
name: sibling-rollback
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
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async () => {});
`,
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
      "0x0000000000000000000000000000000000000003"->Address.Evm.fromStringOrThrow,
    )
  },
}

describe("Sibling-chain rollback with an in-flight query", () => {
  scenario->Scenario.it(
    "chain keeps fetching after its in-flight response is dropped by a sibling rollback",
    ~sources=[
      {chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes], pollingInterval: 1},
      {
        chain: 137,
        methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes],
        pollingInterval: 1,
      },
    ],
    // Two addresses on chain 1 -> two partitions, so one partition's query
    // can stay in flight while the other's response lands.
    ~maxAddrInPartition=1,
    ~reducedPollingInterval=1,
    async (~t, ~indexer, ~source) => {
      let victim = source(1)
      let sibling = source(137)
      await indexer.settle()
      victim.resolveGetHeightOrThrow(300)
      sibling.resolveGetHeightOrThrow(300)
      await indexer.settle()

      // Drive both chains to head 300 through the reorg-threshold transition,
      // resolving every query as it appears.
      let drainTo = async (source: MockSource.t, ~latest, ~items=[]) => {
        await Scenario.waitQuery(~indexer, ~source)
        source.resolveGetItemsOrThrow(items, ~latestFetchedBlockNumber=latest)
        await indexer.settle()
      }

      // Pre-threshold queries stop at 100 (head - maxReorgDepth).
      await drainTo(victim, ~latest=100)
      await drainTo(sibling, ~latest=100)
      await indexer.settle()

      // Post-threshold queries reach the head. The victim's response also
      // registers a dynamic Token address at block 250, spawning a catch-up
      // partition mid-response like the incident chain's factory events.
      await drainTo(
        victim,
        ~latest=300,
        ~items=[setCounter(~block=200, ~count=1n), registerToken(~block=250)],
      )
      await drainTo(sibling, ~latest=300, ~items=[setCounter(~block=200, ~count=2n)])
      // Serve the dynamic partition's catch-up queries until the chain is quiet.
      let attempts = ref(0)
      while attempts.contents < 200 {
        attempts := attempts.contents + 1
        if victim.getItemsOrThrowCalls->Array.length > 0 {
          victim.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
        }
        await indexer.settle()
      }
      await indexer.settle()
      await indexer.waitUntilReady()

      // New block on the victim chain. The first partition queries it; its
      // response lands, which schedules the tick that sends the second
      // partition's query — that one stays in flight through the rollback,
      // like partition 7 in the incident.
      victim.resolveGetHeightOrThrow(301)
      let attempts = ref(0)
      while victim.getItemsOrThrowCalls->Array.length === 0 && attempts.contents < 1000 {
        attempts := attempts.contents + 1
        try victim.resolveGetHeightOrThrow(301) catch {
        | _ => ()
        }
        await indexer.settle()
      }
      victim.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=301)
      let attempts = ref(0)
      while victim.getItemsOrThrowCalls->Array.length === 0 && attempts.contents < 1000 {
        attempts := attempts.contents + 1
        await indexer.settle()
      }
      t.expect(
        victim.getItemsOrThrowCalls->Array.length,
        ~message="the second victim partition should now be querying the new head block",
      ).toEqual(1)

      // Reorg on the sibling chain: block 300 comes back with a different hash.
      try sibling.resolveGetHeightOrThrow(301) catch {
      | _ => ()
      }
      let attempts = ref(0)
      while sibling.getItemsOrThrowCalls->Array.length === 0 && attempts.contents < 1000 {
        attempts := attempts.contents + 1
        try sibling.resolveGetHeightOrThrow(301) catch {
        | _ => ()
        }
        await indexer.settle()
      }
      sibling.resolveGetItemsOrThrow(
        [],
        ~latestFetchedBlockNumber=301,
        ~prevRangeLastBlock={blockNumber: 300, blockHash: "0x300a"},
      )
      await indexer.settle()
      // The victim's in-flight response lands inside the rollback window —
      // after the reorg was detected but before the rollback applied.
      switch victim.getItemsOrThrowCalls->Array.length {
      | 0 => ()
      | _ => victim.resolveGetItemsOrThrow([], ~resolveAt=#last, ~latestFetchedBlockNumber=301)
      }
      // The rollback target usually comes from the recorded safe checkpoints;
      // serve getBlockHashes only if the depth search asks for it.
      let attempts = ref(0)
      while sibling.getBlockHashesCalls->Array.length === 0 && attempts.contents < 100 {
        attempts := attempts.contents + 1
        await indexer.settle()
      }
      if sibling.getBlockHashesCalls->Array.length > 0 {
        sibling.resolveGetBlockHashes([
          {blockNumber: 100, blockHash: "0x100", blockTimestamp: 100},
          {blockNumber: 200, blockHash: "0x200", blockTimestamp: 200},
        ])
      }
      await indexer.settle()

      // The rollback dropped the victim's pending query bookkeeping; its
      // response arrives now, carrying the old epoch, and is discarded.
      switch victim.getItemsOrThrowCalls->Array.length {
      | 0 => ()
      | _ => victim.resolveGetItemsOrThrow([], ~resolveAt=#last, ~latestFetchedBlockNumber=301)
      }
      await indexer.settle()

      // Both chains must resume fetching after the rollback and refetch their
      // rolled-back ranges — including re-registering the pruned dynamic
      // address when block 250 is re-delivered. The victim chain is wedged if
      // it never catches back up to the head.
      let victimMaxFromBlock = ref(0)
      let attempts = ref(0)
      while victimMaxFromBlock.contents < 302 && attempts.contents < 3000 {
        attempts := attempts.contents + 1
        victim.getItemsOrThrowCalls
        ->Utils.Array.copy
        ->Array.forEach(
          call => {
            let fromBlock = call.payload["fromBlock"]
            let toBlock = call.payload["toBlock"]->Option.getOr(302)
            if fromBlock > victimMaxFromBlock.contents {
              victimMaxFromBlock := fromBlock
            }
            let latest = Pervasives.min(toBlock, 302)
            call.resolve(
              fromBlock <= 250 && 250 <= latest ? [registerToken(~block=250)] : [],
              ~latestFetchedBlockNumber=latest,
            )
          },
        )
        if sibling.getItemsOrThrowCalls->Array.length > 0 {
          sibling.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=302)
        }
        try victim.resolveGetHeightOrThrow(302) catch {
        | _ => ()
        }
        try sibling.resolveGetHeightOrThrow(302) catch {
        | _ => ()
        }
        await Utils.delay(1)
      }

      t.expect(
        victimMaxFromBlock.contents >= 302,
        ~message="the victim chain should catch back up to the head after the sibling rollback",
      ).toBe(true)
    },
  )
})
