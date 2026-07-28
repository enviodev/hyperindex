// Two `onEvent` registrations for the same contract event, one unrestricted and
// one held back by `where.block.number._gte`. The chain's address gate is
// contract-wide, so an unrestricted sibling has to keep it open from the chain
// start while the restricted registration still ignores everything before its
// own block.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: event-start-block
contracts:
  - name: Counter
    events:
      - event: Bump(uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Counter
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Seen {
  id: ID!
  handler: String!
  block: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Counter", event: "Bump" }, async ({ event, context }) => {
  context.Seen.set({
    id: \`all-\${event.block.number}\`,
    handler: "all",
    block: event.block.number,
  });
});

indexer.onEvent(
  { contract: "Counter", event: "Bump", where: { block: { number: { _gte: 100 } } } },
  async ({ event, context }) => {
    context.Seen.set({
      id: \`gte100-\${event.block.number}\`,
      handler: "gte100",
      block: event.block.number,
    });
  },
);
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const bump = (blockNumber: number) => ({
  contract: "Counter",
  event: "Bump",
  params: { value: BigInt(blockNumber) },
  srcAddress: "0x1111111111111111111111111111111111111111",
  block: { number: blockNumber },
} as const);

describe("per-event startBlock alongside an unrestricted sibling", () => {
  it("gives the unrestricted handler pre-100 events and starts the filtered one at 100", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { startBlock: 0, endBlock: 200, simulate: [bump(50), bump(100), bump(150)] } },
    });

    const seen = await indexer.Seen.getAll();
    t.expect(
      seen
        .map((s) => \`\${s.handler}@\${s.block}\`)
        .sort(),
    ).toEqual(["all@100", "all@150", "all@50", "gte100@100", "gte100@150"]);
  });
});
`,
)
