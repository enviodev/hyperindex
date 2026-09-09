open Vitest

// `context.chain` inside a running handler: the id resolves to the chain the
// item came from, not whichever chain the batch happens to start on, and
// `isRealtime` only flips once every chain in the indexer is at its head.

let scenario = Scenario.make(
  ~configYaml=`
name: handler-chain-info
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
  - id: 137
    rpc:
      url: https://rpc137.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000002"
`,
  ~schema=`
type Seen {
  id: ID!
  chainId: Int!
  isRealtime: Boolean!
}
`,
)

type seen = {id: string, chainId: int, isRealtime: bool}
type seenOps = {set: seen => unit}
type chainInfo = {id: int, isRealtime: bool}
type seenContext = {@as("Seen") seen: seenOps, chain: chainInfo}

let recordChain = (~block, ~label): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args => {
    let context = args.context->(Utils.magic: Internal.handlerContext => seenContext)
    context.seen.set({
      id: label,
      chainId: context.chain.id,
      isRealtime: context.chain.isRealtime,
    })
  },
}

let sortById = (rows: array<seen>) =>
  rows->Array.toSorted((a, b) => String.compare(a.id, b.id))

describe("context.chain inside a handler", () => {
  scenario->Scenario.it(
    "resolves the item's own chain, and reports realtime only once every chain is at head",
    ~sources=[{chain: 1}, {chain: 137}],
    ~reducedPollingInterval=1,
    async (~t, ~indexer, ~source) => {
      let chain1 = source(1)
      let chain137 = source(137)

      chain1.resolveGetHeightOrThrow(300)
      chain137.resolveGetHeightOrThrow(300)

      // Both chains stop short of their head, so neither is ready and the
      // handlers see a backfilling indexer.
      await MockSource.waitItemsQuery(chain1)
      chain1.resolveGetItemsOrThrow(
        [recordChain(~block=10, ~label="backfill-1")],
        ~latestFetchedBlockNumber=100,
      )
      await MockSource.waitItemsQuery(chain137)
      chain137.resolveGetItemsOrThrow(
        [recordChain(~block=20, ~label="backfill-137")],
        ~latestFetchedBlockNumber=100,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        (await (indexer.query("Seen"): promise<array<seen>>))->sortById,
        ~message="each handler reads its own chain id, and no chain is at head yet",
      ).toEqual([
        {id: "backfill-1", chainId: 1, isRealtime: false},
        {id: "backfill-137", chainId: 137, isRealtime: false},
      ])

      // Both chains reach their head, so the indexer is realtime for whatever
      // it processes next.
      await MockSource.waitItemsQuery(chain1)
      chain1.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await MockSource.waitItemsQuery(chain137)
      chain137.resolveGetItemsOrThrow([], ~latestFetchedBlockNumber=300)
      await indexer.waitUntilReady()

      // A chain at its head only fetches again once the head moves.
      chain1.resolveGetHeightOrThrow(301)
      await MockSource.waitItemsQuery(chain1)
      chain1.resolveGetItemsOrThrow(
        [recordChain(~block=301, ~label="realtime-1")],
        ~latestFetchedBlockNumber=301,
        ~knownHeight=301,
      )
      await indexer.getBatchWritePromise()

      t.expect(
        (await (indexer.query("Seen"): promise<array<seen>>))->sortById,
        ~message="with every chain at head the handler sees isRealtime",
      ).toEqual([
        {id: "backfill-1", chainId: 1, isRealtime: false},
        {id: "backfill-137", chainId: 137, isRealtime: false},
        {id: "realtime-1", chainId: 1, isRealtime: true},
      ])
    },
  )
})
