open Vitest

// Every chain has a safe block of its own — its head less its reorg depth —
// below which a rollback can no longer reach. A schema whose chains can't have
// written each other's rows prunes each chain's history down to that chain's own
// safe checkpoint, instead of holding every chain at the lowest one any of them
// has reached. A chain whose head barely moves has a safe checkpoint that barely
// moves with it, and used to pin every sibling's history in place.

type counter = {
  id: string,
  count: bigint,
  @as("chainId") chainId: int,
}

type counterOps = {set: {"id": string, "count": bigint} => unit}
type handlerContext = {@as("Counter") counter: counterOps}

let asContext = (context: Internal.handlerContext) =>
  context->(Utils.magic: Internal.handlerContext => handlerContext)

let chainYaml = (chainId, ~startBlock, ~maxReorgDepth) =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: ${startBlock->Int.toString}
    max_reorg_depth: ${maxReorgDepth->Int.toString}
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

// `laggingChainId` is the chain that never reaches a safe checkpoint. The chains
// are visited in ascending id order, so putting it either side of chain 100
// covers both orders a fold over them can see.
let makeConfigYaml = (name, ~laggingChainId) =>
  `
name: ${name}
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100, ~startBlock=110, ~maxReorgDepth=15)}${chainYaml(
      laggingChainId,
      ~startBlock=1,
      ~maxReorgDepth=200,
    )}
`

let scenario = Scenario.make(
  ~schema,
  ~configYaml=makeConfigYaml("per-chain-prune", ~laggingChainId=1337),
)

let crossChainSchema =
  schema ++ `
type Total @crossChain {
  id: ID!
  count: BigInt!
}
`

// One cross-chain entity couples the chains: a reorg on the chain furthest
// behind can reach a row any chain wrote, so none may prune past its safe point.
let crossChainScenario = Scenario.make(
  ~schema=crossChainSchema,
  ~configYaml=makeConfigYaml("per-chain-prune-cross-chain", ~laggingChainId=1337),
)

// The same, with the lagging chain visited first.
let crossChainLaggingFirstScenario = Scenario.make(
  ~schema=crossChainSchema,
  ~configYaml=makeConfigYaml("per-chain-prune-cross-chain-lagging-first", ~laggingChainId=5),
)

let methods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

let setCounter = (~block, ~count: bigint): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->asContext
    context.counter.set({"id": "total", "count": count})
  },
}

let counterHistory = (indexer: IndexerRunner.t): promise<array<Change.t<counter>>> =>
  indexer.queryHistory("Counter")

// Checkpoints are pruned on the same bound as the history they anchor, so the
// two are read together — as (id, chain) pairs, the only part a prune changes.
let checkpointsByChain = async (indexer: IndexerRunner.t) =>
  (await indexer.queryCheckpoints())->Array.map(({id, chainId}) => (id, chainId->ChainId.toInt))

let startAt = async (~t: Vitest.testContext, ~source: MockSource.t, ~head) => {
  await Utils.delay(0)
  t.expect(
    source.getHeightOrThrowCalls->Array.length,
    ~message="should have called getHeightOrThrow to get initial height",
  ).toEqual(1)
  source.resolveGetHeightOrThrow(head)
  await Utils.delay(0)
  await Utils.delay(0)
}

// Both chains index inside their reorg threshold from the first block they
// fetch, so neither starts with a checkpoint at the threshold boundary. The
// lagging chain's reorg depth reaches below its own head, so it never has a safe
// checkpoint at all — the case that used to pin every sibling's history in
// place. Chain 100's head then runs on to 130, which leaves its blocks 111 and
// 112 below its own safe block and its block 120 above it.
let driveChain100Ahead = async (~t, ~indexer: IndexerRunner.t, ~source100, ~lagging) => {
  let _ = await Promise.all2((
    startAt(~t, ~source=source100, ~head=120),
    startAt(~t, ~source=lagging, ~head=110),
  ))

  source100.MockSource.resolveGetItemsOrThrow(
    [setCounter(~block=111, ~count=1n), setCounter(~block=112, ~count=2n)],
    ~latestFetchedBlockNumber=112,
  )
  lagging.MockSource.resolveGetItemsOrThrow(
    [setCounter(~block=5, ~count=20n)],
    ~latestFetchedBlockNumber=110,
  )
  await indexer.getBatchWritePromise()

  source100.setAutoHeight(130)
  source100.resolveGetItemsOrThrow(
    [setCounter(~block=120, ~count=3n)],
    ~filter=MockSource.coveringBlock(113),
    ~latestFetchedBlockNumber=130,
  )
  await indexer.getBatchWritePromise()
  await indexer.waitUntilIdle()
}

let counterSet = (~checkpointId, ~chain, ~count): Change.t<counter> => Set({
  checkpointId,
  entityId: "total"->EntityId.unsafeOfString,
  entity: {id: "total", count, chainId: chain},
})

describe("Per-chain history pruning", () => {
  scenario->Scenario.it(
    "Prunes a chain down to its own safe checkpoint while a sibling's head sits still",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      await driveChain100Ahead(~t, ~indexer, ~source100=source(100), ~lagging=source(1337))

      t.expect(
        await Promise.all2((counterHistory(indexer), checkpointsByChain(indexer))),
        ~message="Chain 100 dropped what its own safe block put out of reach, keeping the anchor; chain 1337 kept everything, having nothing safe yet",
      ).toEqual((
        [
          // The anchor: chain 100's last state at or below its own safe block.
          counterSet(~checkpointId=2n, ~chain=100, ~count=2n),
          counterSet(~checkpointId=3n, ~chain=1337, ~count=20n),
          counterSet(~checkpointId=5n, ~chain=100, ~count=3n),
        ],
        [(2n, 100), (3n, 1337), (4n, 1337), (5n, 100), (6n, 100)],
      ))
    },
  )

  // Chain 100's rows are all still reachable by a rollback the lagging chain's
  // reorg would cause, so none of them may be pruned. The two cases differ only
  // in which chain is visited first, which the checkpoint ids follow.
  crossChainScenario->Scenario.it(
    "Holds every chain at the lowest safe checkpoint when one entity is cross-chain",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      await driveChain100Ahead(~t, ~indexer, ~source100=source(100), ~lagging=source(1337))

      t.expect(
        await Promise.all2((counterHistory(indexer), checkpointsByChain(indexer))),
        ~message="Nothing is pruned while chain 1337 has nothing safe yet",
      ).toEqual((
        [
          counterSet(~checkpointId=1n, ~chain=100, ~count=1n),
          counterSet(~checkpointId=2n, ~chain=100, ~count=2n),
          counterSet(~checkpointId=3n, ~chain=1337, ~count=20n),
          counterSet(~checkpointId=5n, ~chain=100, ~count=3n),
        ],
        [(1n, 100), (2n, 100), (3n, 1337), (4n, 1337), (5n, 100), (6n, 100)],
      ))
    },
  )

  // The same, with the lagging chain visited before the one that does have a
  // safe checkpoint. The bound is the lowest of the two either way, never
  // whichever chain the fold happened to see last.
  crossChainLaggingFirstScenario->Scenario.it(
    "Holds every chain at the lowest safe checkpoint when the lagging chain comes first",
    ~sources=[{chain: 5, methods}, {chain: 100, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      await driveChain100Ahead(~t, ~indexer, ~source100=source(100), ~lagging=source(5))

      t.expect(
        await Promise.all2((counterHistory(indexer), checkpointsByChain(indexer))),
        ~message="Nothing is pruned while chain 5 has nothing safe yet",
      ).toEqual((
        [
          counterSet(~checkpointId=1n, ~chain=5, ~count=20n),
          counterSet(~checkpointId=3n, ~chain=100, ~count=1n),
          counterSet(~checkpointId=4n, ~chain=100, ~count=2n),
          counterSet(~checkpointId=5n, ~chain=100, ~count=3n),
        ],
        [(1n, 5), (2n, 5), (3n, 100), (4n, 100), (5n, 100), (6n, 100)],
      ))
    },
  )
})
