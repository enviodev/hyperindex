open Vitest

// Repro: a multichain indexer never enters the reorg threshold.
//
// Entry is a one-time whole-indexer transition that requires EVERY chain to
// satisfy `isReadyToEnterReorgThreshold` at the same batch-completion check
// (BatchProcessing.res `Array.every`). Without a tolerance, a chain that reached
// its lagged head is un-readied the moment its head advances by a block. With
// more than one live chain the head of some chain is always advancing, so the
// conjunction is never observed and the indexer sits below the threshold forever.
// The reorg-threshold ready tolerance closes this: a chain stays ready while
// within `tolerance` blocks of the lagged head, so a small head advance during
// the cross-chain handoff no longer defers entry.
let schema = `
type Gravatar {
  id: ID!
  owner: String!
}
`

// Two chains, each lagging maxReorgDepth (200) below head before the
// threshold. Head starts at 1000, so the pre-threshold head is 800.
let multichain = Scenario.make(
  ~configYaml=`
name: enter-reorg-threshold-multichain
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 100
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_lag: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_lag: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema,
)

let singleChain = Scenario.make(
  ~configYaml=`
name: enter-reorg-threshold-single
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    block_lag: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema,
)

// Queries are serialized by the cross-chain budget waterfall, so a chain's
// height re-poll only lands after the other chain releases the budget.
let waitNewHeightPoll = async (sourceMock: MockSource.t, ~after) => {
  let attempts = ref(0)
  while sourceMock.getHeightOrThrowCalls->Array.length <= after && attempts.contents < 1000 {
    attempts := attempts.contents + 1
    await Utils.delay(0)
  }
  if sourceMock.getHeightOrThrowCalls->Array.length <= after {
    JsError.throwWithMessage("Timed out waiting for a new getHeightOrThrow poll")
  }
}

describe("PIN: multichain indexer enters the reorg threshold", () => {
  multichain->Scenario.it(
    "a chain whose head advances after reaching its lagged head still lets the indexer enter the threshold",
    ~sources=[
      {chain: 100, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
      {chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]},
    ],
    ~reorgThresholdReadyTolerance=100,
    ~reducedPollingInterval=1,
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      let chainA = source(100)
      let chainB = source(1337)
      await Utils.delay(0)
      let initialHeightPolls = chainA.getHeightOrThrowCalls->Array.length
      chainA.resolveGetHeightOrThrow(1000)
      chainB.resolveGetHeightOrThrow(1000)
      await Utils.delay(0)
      await Utils.delay(0)

      // Chain A wins the initial priority tie and fetches to its pre-threshold
      // head (block 800), seeding a density signal from its events.
      await MockSource.waitItemsQuery(chainA)
      t.expect(
        chainA.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="chain A first fetches from its start block",
      ).toEqual([1])
      let densitySeed: array<MockSource.itemMock> = Array.fromInitializer(
        ~length=100,
        i => {
          MockSource.blockNumber: 1 + i * 3,
          logIndex: 0,
        },
      )
      chainA.resolveGetItemsOrThrow(
        densitySeed,
        ~latestFetchedBlockNumber=800,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      // Chain A is now at its lagged head with an empty buffer — momentarily
      // ready. Chain B has not responded, so the entry check fails here.
      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="cannot enter while chain B is still backfilling",
      ).toEqual([{value: "0", labels: Dict.make()}])

      // Chain A's head advances while it idles at its lagged head, so its frontier
      // (800) now trails the lagged head (801). Without a tolerance this would
      // un-ready chain A and defer entry; the 100-block tolerance keeps it ready.
      // (Chain A cannot re-query 801 yet — chain B holds the shared fetch budget.)
      await waitNewHeightPoll(chainA, ~after=initialHeightPolls)
      chainA.resolveGetHeightOrThrow(1001)
      await Utils.delay(0)
      await Utils.delay(0)

      // Chain B now reaches its own pre-threshold head and produces a batch,
      // triggering the whole-indexer entry check.
      await MockSource.waitItemsQuery(chainB)
      t.expect(
        chainB.getItemsOrThrowCalls->Array.map(call => call.payload["fromBlock"]),
        ~message="chain B first fetches from its start block",
      ).toEqual([1])
      chainB.resolveGetItemsOrThrow(
        [{MockSource.blockNumber: 800, logIndex: 0}],
        ~latestFetchedBlockNumber=800,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      // Both chains are within the tolerance of their lagged heads, so the indexer
      // enters — even though chain A's head advanced past its frontier before
      // chain B caught up.
      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="the indexer enters the threshold with both chains within the tolerance of head",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )

  singleChain->Scenario.it(
    "enters while still within the configured tolerance of the lagged head",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~reorgThresholdReadyTolerance=100,
    ~reducedPollingInterval=1,
    ~targetBufferSize=100,
    async (~t, ~indexer, ~source) => {
      let source = source(1337)

      source.resolveGetHeightOrThrow(1000)
      await MockSource.waitItemsQuery(source)
      // max_reorg_depth holds the chain 200 blocks below head before the
      // threshold, so it queries up to block 800.
      t.expect(
        source.getItemsOrThrowCalls->Array.map(call => call.payload["toBlock"]),
        ~message="pre-threshold query stops at the lagged head",
      ).toEqual([Some(800)])

      // Respond 50 blocks short of the lagged head (750 < 800) — within the
      // 100-block tolerance, so the chain enters despite not reaching 800 exactly.
      source.resolveGetItemsOrThrow(
        [{MockSource.blockNumber: 750, logIndex: 0}],
        ~latestFetchedBlockNumber=750,
        ~knownHeight=1000,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        await indexer.metric("envio_reorg_threshold"),
        ~message="enters within the tolerance below the lagged head",
      ).toEqual([{value: "1", labels: Dict.make()}])
    },
  )
})
