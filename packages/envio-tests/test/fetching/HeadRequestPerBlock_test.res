open Vitest

// At the head every need of a chain rides one request: each new block is asked
// for once, whatever mix of events, block handlers and transaction handlers the
// chain fetches.

let gravatar = "0x1111111111111111111111111111111111111111"

let scenario = Scenario.make(
  ~configYaml=`
name: head-request-per-block
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
        events:
          - event: "TestEvent()"
      - name: Wild
        events:
          - event: "Ping()"
`,
  ~schema=`
type Run {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Gravatar", event: "TestEvent" }, async () => {});
indexer.onEvent({ contract: "Wild", event: "Ping", wildcard: true }, async () => {});
indexer.onBlock({ name: "headers", fields: { block: ["timestamp"] } }, async () => {});
indexer.onTransaction(
  { name: "every", where: () => ({ transaction: { status: [0, 1] } }) },
  async ({ transaction, context }) => {
    context.Run.set({ id: \`\${transaction.block.number}\` });
  },
);
`,
)

describe("A chain at the head", () => {
  scenario->Scenario.it(
    "asks for each new block in one items query",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer as _, ~source) => {
      let sync = source(1337)
      sync.resolveGetHeightOrThrow(100)
      await sync.respondUpTo(100)
      let asked = []
      for height in 101 to 103 {
        sync.resolveGetHeightOrThrow(height)
        await sync.expectItemsQueries([
          {
            fromBlock: height,
            reply: Respond({items: [], latestFetchedBlockNumber: height}),
          },
        ])
        sync.repliedItemsQueries->Array.forEach(query => asked->Array.push(query.fromBlock))
      }
      t.expect(asked).toEqual([101, 102, 103])
    },
  )
})
