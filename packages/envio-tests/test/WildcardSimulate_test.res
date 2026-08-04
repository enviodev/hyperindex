// A wildcard-registered event has no configured address, so simulate routes it
// to its handler whatever srcAddress the item carries. Migrated from
// scenarios/test_codegen.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: wildcard-simulate
contracts:
  - name: EventFiltersTest
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: EventFiltersTest
`,
  ~schema=`
type Transferred {
  id: ID!
  amount: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "EventFiltersTest", event: "Transfer", wildcard: true },
  async ({ event, context }) => {
    context.Transferred.set({ id: event.srcAddress, amount: event.params.amount });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const whitelisted = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const;
const zero = "0x0000000000000000000000000000000000000000" as const;
const unconfigured = "0x1234567890123456789012345678901234567890" as const;

const transfer = {
  contract: "EventFiltersTest",
  event: "Transfer",
  params: { from: zero, to: whitelisted, amount: 0n },
} as const;

describe("wildcard simulate", () => {
  it("routes to the handler regardless of srcAddress", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: { 1: { startBlock: 1, endBlock: 100, simulate: [{ ...transfer, srcAddress: unconfigured }] } },
    });

    t.expect({
      changes: result.changes,
      stored: await indexer.Transferred.getAll(),
    }).toEqual({
      changes: [
        { block: 1, chainId: 1, eventsProcessed: 1, Transferred: { sets: [{ id: unconfigured, amount: 0n }] } },
      ],
      stored: [{ id: unconfigured, amount: 0n }],
    });
  });

  // simulate only requires srcAddress to start with "0x" — a placeholder like
  // "0xfoo" is accepted, unlike a real address which must be valid 20-byte hex.
  it("accepts a non-address placeholder srcAddress starting with 0x", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { startBlock: 1, endBlock: 100, simulate: [{ ...transfer, srcAddress: "0xfoo" }] } },
    });

    t.expect(await indexer.Transferred.getAll()).toEqual([{ id: "0xfoo", amount: 0n }]);
  });
});
`,
)
