open Vitest

// https://github.com/enviodev/hyperindex/issues/316
// A contract with an `end_block` is fetched up to that block and no further,
// while the rest of its chain keeps going.

let gravatar = "0x1111111111111111111111111111111111111111"

let scenario = Scenario.make(
  ~configYaml=`
name: contract-end-block
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
        address: "${gravatar}"
        end_block: 50
        events:
          - event: "TestEvent()"
      - name: Wild
        events:
          - event: "Ping()"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async ({ event, context }) => {
  context.Seen.set({ id: \`\${event.block.number}\` });
});
indexer.onEvent({ contract: "Wild", event: "Ping", wildcard: true }, async () => {});
`,
)

type seen = {id: string}

let gravatarEvent = (~blockNumber): MockSource.itemMock => {
  event: "Gravatar.TestEvent",
  blockNumber,
  logIndex: 0,
  srcAddress: gravatar,
}

describe("A contract with an end block", () => {
  scenario->Scenario.it(
    "is fetched no further than its end block",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(1000)
      await sync.expectItemsQueries([
        {
          address: gravatar,
          fromBlock: 1,
          toBlock: Bounded(50),
          reply: Respond({items: [gravatarEvent(~blockNumber=40)], latestFetchedBlockNumber: 50}),
        },
        {
          where: query => query->MockSource.addresses->Array.length == 0,
          fromBlock: 1,
          reply: Respond({items: [], latestFetchedBlockNumber: 1000}),
        },
      ])
      sync.resolveGetHeightOrThrow(1100)
      await sync.expectItemsQueries([{fromBlock: 1001, reply: LeavePending}])
      let rows: array<seen> = await indexer.query("Seen")
      t.expect((
        sync.pendingItemsQueries->Array.map(query => query->MockSource.addresses),
        rows->Array.map(row => row.id),
      )).toEqual(([[]], ["40"]))
    },
  )
})
