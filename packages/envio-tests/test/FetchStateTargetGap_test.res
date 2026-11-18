open Vitest

// Chain 2 anchors cross-chain alignment whenever its frontier progress is the
// lowest, and then chain 1 may target no further than 20% of its own range past
// chain 2's progress. That lets the test move chain 1's target block back and
// forth by moving chain 2.
let scenario = Scenario.make(
  ~configYaml=`
name: fetch-state-target-gap
rollback_on_reorg: false
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
    end_block: 1000
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 2
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
)

type issuedQuery = {
  fromBlock: int,
  toBlock: MockSource.toBlock,
}

// The queries issued since the last call, in arrival order.
let takeNewQueries = (mock: MockSource.t, ~seen: array<MockSource.pendingItemsQuery>) => {
  mock
  ->MockSource.takeNewPendingItemsQueries(~seen)
  ->Array.map((query): issuedQuery => {fromBlock: query.fromBlock, toBlock: query.toBlock})
}

let respondWithItemPerBlock = (~fromBlock, ~toBlock): MockSource.reply => Respond({
  items: Array.fromInitializer(~length=toBlock - fromBlock + 1, index => {
    MockSource.blockNumber: fromBlock + index,
    logIndex: 0,
  }),
  latestFetchedBlockNumber: toBlock,
})

describe("FetchState target containment over the indexer loop", () => {
  scenario->Scenario.it(
    "defers a gap past the target block, then fills it once the target reaches it",
    ~sources=[{chain: 1}, {chain: 2}],
    ~targetBufferSize=100_000,
    // The steps below stage the two chains' progress against each other.
    ~supervised=false,
    async (~t, ~indexer as _, ~source) => {
      let leader = source(1)
      let anchor = source(2)
      let leaderSeen = []
      let anchorSeen = []
      leader.resolveGetHeightOrThrow(1000)
      anchor.resolveGetHeightOrThrow(1000)
      await anchor.expectItemsQueries([
        {fromBlock: 1, reply: Respond({items: [], latestFetchedBlockNumber: 200})},
      ])
      await anchor.expectItemsQueries([{fromBlock: 201, reply: LeavePending}])
      // Two responses of one item per block, the second over 50 blocks, give
      // chain 1 90-block chunks. It is behind chain 2, so nothing clamps it and
      // its chunks run to its end block.
      await leader.expectItemsQueries([
        {fromBlock: 1, reply: respondWithItemPerBlock(~fromBlock=1, ~toBlock=100)},
      ])
      await leader.expectItemsQueries([
        {fromBlock: 101, reply: respondWithItemPerBlock(~fromBlock=101, ~toBlock=150)},
      ])
      await leader.expectItemsQueries([
        {fromBlock: 961, reply: LeavePending},
        {reply: LeavePending},
      ])
      let chunks = leader->takeNewQueries(~seen=leaderSeen)
      // Reaching 240 puts chain 1 ahead of chain 2 at 200, which now clamps it
      // to block 400. The chunk at 511 then stops at 550, leaving a gap at
      // 551..600 past that target.
      await leader.expectItemsQueries([
        {fromBlock: 151, reply: respondWithItemPerBlock(~fromBlock=151, ~toBlock=240)},
      ])
      await leader.expectItemsQueries([
        {fromBlock: 511, reply: respondWithItemPerBlock(~fromBlock=511, ~toBlock=550)},
      ])
      // Chain 2 moving to 230, still behind chain 1, only lifts the target to 430.
      await anchor.expectItemsQueries([
        {fromBlock: 201, reply: Respond({items: [], latestFetchedBlockNumber: 230})},
      ])
      await anchor.expectItemsQueries([{fromBlock: 231, reply: LeavePending}])
      let whileClamped = {
        "leader": leader->takeNewQueries(~seen=leaderSeen),
        "anchor": anchor->takeNewQueries(~seen=anchorSeen),
      }
      // Chain 2 passing chain 1 lifts the clamp entirely.
      await anchor.expectItemsQueries([
        {fromBlock: 231, reply: Respond({items: [], latestFetchedBlockNumber: 500})},
      ])
      await leader.expectItemsQueries([{fromBlock: 551, reply: LeavePending}])
      t.expect((chunks, whileClamped, leader->takeNewQueries(~seen=leaderSeen))).toEqual((
        Array.concat(
          Array.fromInitializer(
            ~length=9,
            index => {
              fromBlock: 151 + index * 90,
              toBlock: Bounded(240 + index * 90),
            },
          ),
          [{fromBlock: 961, toBlock: Bounded(1000)}],
        ),
        {
          "leader": [],
          "anchor": [{fromBlock: 231, toBlock: Unbounded}],
        },
        [{fromBlock: 551, toBlock: Bounded(600)}],
      ))
    },
  )
})
