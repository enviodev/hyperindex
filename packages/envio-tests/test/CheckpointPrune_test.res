open Vitest

// A checkpoint a reorg can no longer reach is pruned, whether or not Postgres
// keeps the entity's history to prune beside it, which on the ClickHouse leg it
// doesn't.

let schema = `
type Counter {
  id: ID!
  count: BigInt!
}
`

let configYaml = `
name: checkpoint-prune
rollback_on_reorg: true
contracts:
  - name: Token
    events:
      - event: Transfer(uint256 count)
chains:
  - id: 100
    rpc:
      url: https://rpc100.example.test
      for: sync
    start_block: 110
    max_reorg_depth: 15
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`

let handlers = `
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Counter.set({ id: "total", count: event.params.count });
});
`

let scenario = Scenario.make(~supervised=false, ~schema, ~configYaml, ~handlers)

external toUnknown: bigint => unknown = "%identity"

let setCounter = (~block, ~count: bigint): MockSource.itemMock => {
  event: "Token.Transfer",
  blockNumber: block,
  logIndex: 0,
  params: dict{"count": count->toUnknown},
}

describe("Checkpoint pruning", () => {
  scenario->Scenario.it(
    "Drops the checkpoints below the chain's safe one",
    ~sources=[{chain: 100, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~reorgThresholdReadyTolerance=0,
    async (~t, ~indexer, ~source) => {
      let source = source(100)
      await Scenario.resolveInitialHeight(~source, ~head=120)
      await source.expectItemsQueries([
        {
          fromBlock: 110,
          toBlock: Unbounded,
          reply: Respond({
            items: [setCounter(~block=111, ~count=1n), setCounter(~block=112, ~count=2n)],
            latestFetchedBlockNumber: 112,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      // Block 115 is now safe: 111 and 112 fall out of reach, 112 staying as the
      // anchor of what is above it.
      source.setAutoHeight(130)
      await source.expectItemsQueries([
        {
          coversBlock: 113,
          reply: Respond({
            items: [setCounter(~block=120, ~count=3n)],
            latestFetchedBlockNumber: 130,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await indexer.waitUntilIdle()

      t.expect(
        (await indexer.queryCheckpoints())->Array.map(({id, blockNumber}) => (id, blockNumber)),
      ).toEqual([(2n, 112), (3n, 120), (4n, 130)])
    },
  )
})
