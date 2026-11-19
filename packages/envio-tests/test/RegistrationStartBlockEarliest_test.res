// Every registration of this contract is held back, each to its own block, so
// the contract-wide gate has to open at the earliest of them, not the latest.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: registration-start-block-earliest
contracts:
  - name: Pair
    events:
      - event: Swap()
      - event: Sync()
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Pair
        address: "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC"
`,
  ~schema=`
type Seen {
  id: ID!
  event: String!
  block: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Pair", event: "Swap", where: { block: { number: { _gte: 100 } } } },
  async ({ event, context }) => {
    context.Seen.set({ id: \`swap-\${event.block.number}\`, event: "swap", block: event.block.number });
  },
);

indexer.onEvent(
  { contract: "Pair", event: "Sync", where: { block: { number: { _gte: 50 } } } },
  async ({ event, context }) => {
    context.Seen.set({ id: \`sync-\${event.block.number}\`, event: "sync", block: event.block.number });
  },
);
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const pair = "0xa2F6E6029638cCb484A2ccb6414499aD3e825CaC" as const;

const pairEvent = (event: "Swap" | "Sync", blockNumber: number) => ({
  contract: "Pair",
  event,
  params: {},
  srcAddress: pair,
  block: { number: blockNumber },
} as const);

describe("a contract whose every registration has a start block", () => {
  it("opens its address gate at the earliest of them", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 300,
          simulate: [pairEvent("Sync", 70), pairEvent("Swap", 150)],
        },
      },
    });

    t.expect(
      (await indexer.Seen.getAll()).map((seen) => \`\${seen.event}@\${seen.block}\`).sort(),
    ).toEqual(["swap@150", "sync@70"]);
  });
});
`,
)
