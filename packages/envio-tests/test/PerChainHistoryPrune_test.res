open Vitest

// Every chain has a safe block of its own — its head less its reorg depth —
// below which a rollback can no longer reach. A schema whose chains can't have
// written each other's rows prunes each chain's history down to that chain's own
// safe checkpoint, instead of holding every chain at the lowest one any of them
// has reached.

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

// Every chain reaches a safe checkpoint of its own, so the prune carries a bound
// per chain. Three of them rather than two: a pair of bounds can be crossed and
// still look right, while three cannot.
let manyBoundsScenario = Scenario.make(
  ~schema,
  ~configYaml=`
name: per-chain-prune-many-bounds
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100, ~startBlock=110, ~maxReorgDepth=15)}${chainYaml(
      200,
      ~startBlock=210,
      ~maxReorgDepth=15,
    )}${chainYaml(300, ~startBlock=310, ~maxReorgDepth=15)}
`,
)

// A chain with no reorg depth can't be rolled back, so with no cross-chain
// entity to let a sibling's rollback reach its rows, it has no history to keep
// and everything it has committed is safe to prune.
let zeroDepthScenario = Scenario.make(
  ~schema,
  ~configYaml=`
name: per-chain-prune-zero-depth
rollback_on_reorg: true
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:${chainYaml(100, ~startBlock=110, ~maxReorgDepth=15)}${chainYaml(
      1337,
      ~startBlock=1,
      ~maxReorgDepth=0,
    )}
`,
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

// Both chains index inside their reorg threshold from the first block they
// fetch, so neither starts with a checkpoint at the threshold boundary. The
// lagging chain's reorg depth reaches below its own head, so it never has a safe
// checkpoint at all. Chain 100's head then runs on to 130, which leaves its
// blocks 111 and 112 below its own safe block and its block 120 above it.
let driveChain100Ahead = async (~t, ~indexer: IndexerRunner.t, ~source100, ~lagging) => {
  let _ = await Promise.all2((
    Scenario.resolveInitialHeight(~t, ~source=source100, ~head=120),
    Scenario.resolveInitialHeight(~t, ~source=lagging, ~head=110),
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
          counterSet(~checkpointId=1n, ~chain=1337, ~count=20n),
          // The anchor: chain 100's last state at or below its own safe block.
          counterSet(~checkpointId=2n, ~chain=100, ~count=2n),
          counterSet(~checkpointId=3n, ~chain=100, ~count=3n),
        ],
        [(2n, 100), (1n, 1337), (2n, 1337), (3n, 100), (4n, 100)],
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

  // Every chain prunes, to a different checkpoint each — the case where several
  // bounds reach the database in one statement. The chains are given different
  // numbers of blocks on purpose, so their safe checkpoints land on different
  // ids: bounds crossed between chains would survive a symmetric setup.
  manyBoundsScenario->Scenario.it(
    "Holds each chain to its own bound when several chains prune at once",
    ~sources=[{chain: 100, methods}, {chain: 200, methods}, {chain: 300, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      // Each chain runs a hundred blocks apart from the next, with its own
      // number of events below its safe block.
      let chains = [
        (100, [(111, 1n), (112, 2n)], (120, 3n)),
        (200, [(211, 11n), (212, 12n), (213, 13n)], (220, 14n)),
        (300, [(311, 21n)], (320, 22n)),
      ]

      let _ = await chains
      ->Array.map(
        ((chain, _, _)) =>
          Scenario.resolveInitialHeight(~t, ~source=source(chain), ~head=chain + 20),
      )
      ->Promise.all

      // Each chain stops fetching at its own last event, so no chain picks up a
      // gap checkpoint the others don't and their safe ids stay distinct.
      let lastBackfillBlock = backfill =>
        backfill->Array.reduce(0, (highest, (block, _)) => Pervasives.max(highest, block))

      chains->Array.forEach(
        ((chain, backfill, _)) =>
          source(chain).resolveGetItemsOrThrow(
            backfill->Array.map(((block, count)) => setCounter(~block, ~count)),
            ~latestFetchedBlockNumber=lastBackfillBlock(backfill),
          ),
      )
      await indexer.getBatchWritePromise()

      chains->Array.forEach(
        ((chain, backfill, (block, count))) => {
          source(chain).setAutoHeight(chain + 30)
          source(chain).resolveGetItemsOrThrow(
            [setCounter(~block, ~count)],
            ~filter=MockSource.coveringBlock(lastBackfillBlock(backfill) + 1),
            ~latestFetchedBlockNumber=chain + 30,
          )
        },
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      let checkpoints = await checkpointsByChain(indexer)
      let history = (await counterHistory(indexer))->Array.map(
        change =>
          switch change {
          | Set({checkpointId, entity}) => (checkpointId, entity.chainId, entity.count)
          | Delete({checkpointId}) => (checkpointId, 0, 0n)
          },
      )
      let forChain = chain => (
        checkpoints->Array.filterMap(((id, rowChain)) => rowChain === chain ? Some(id) : None),
        history->Array.filterMap(
          ((id, rowChain, count)) => rowChain === chain ? Some((id, count)) : None,
        ),
      )

      t.expect(
        (forChain(100), forChain(200), forChain(300)),
        ~message="Each chain kept its own anchor and dropped only what its own safe block put out of reach",
      ).toEqual((
        // Two blocks below its safe block, so chain 100 is bounded at id 2.
        ([2n, 3n, 4n], [(2n, 2n), (3n, 3n)]),
        // Three, so chain 200 is bounded at 3.
        ([3n, 4n, 5n], [(3n, 13n), (4n, 14n)]),
        // One, so chain 300 is bounded at 1 and keeps everything it has.
        ([1n, 2n, 3n], [(1n, 21n), (2n, 22n)]),
      ))
    },
  )

  // A prune runs once per interval, so the one after the restart is the one
  // observed: it sees both chains' committed rows with a fresh interval.
  zeroDepthScenario->Scenario.it(
    "Writes no history for a chain with no reorg depth and prunes its checkpoints as they commit",
    ~sources=[{chain: 100, methods}, {chain: 1337, methods}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source100 = source(100)
      let source1337 = source(1337)
      await driveChain100Ahead(~t, ~indexer, ~source100, ~lagging=source1337)

      source1337.setAutoHeight(115)
      source1337.resolveGetItemsOrThrow(
        [setCounter(~block=113, ~count=21n)],
        ~filter=MockSource.coveringBlock(111),
        ~latestFetchedBlockNumber=115,
      )
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      source100.setAutoHeight(140)
      let restarted = await indexer.restart()

      source100.resolveGetItemsOrThrow(
        [setCounter(~block=135, ~count=4n)],
        ~filter=MockSource.coveringBlock(131),
        ~latestFetchedBlockNumber=140,
      )
      await restarted.getBatchWritePromise()
      await restarted.waitUntilIdle()

      t.expect(
        await Promise.all2((counterHistory(restarted), checkpointsByChain(restarted))),
        ~message="Chain 1337 wrote no history and kept only its latest committed checkpoint; chain 100 pruned to its own safe checkpoint",
      ).toEqual((
        [
          counterSet(~checkpointId=3n, ~chain=100, ~count=3n),
          counterSet(~checkpointId=5n, ~chain=100, ~count=4n),
        ],
        [(3n, 100), (4n, 100), (4n, 1337), (5n, 100), (6n, 100)],
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
