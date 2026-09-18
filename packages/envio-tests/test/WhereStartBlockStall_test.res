// The frontier pin of WildcardStartBlockStall_test, through an address partition:
// a `where` block filter on the contract's only registration lifts the
// selection's start block far above the address's own, so the partition's
// cursor skips ahead while its frontier stays at the chain start, out of the
// cold target range, and the chain never queries.
// https://github.com/enviodev/hyperindex/issues/1650
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: where-start-block-stall
contracts:
  - name: Ledger
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Ledger
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Ledger", event: "Transfer", where: { block: { number: { _gte: 50000 } } } },
  async ({ event, context }) => {
    context.Seen.set({ id: \`\${event.block.number}\` });
  },
);
`,
  ~test=`
import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const ledger = "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3" as const;
const owner = "0x3333333333333333333333333333333333333333" as const;
const zero = "0x0000000000000000000000000000000000000000" as const;

describe("a registration whose start block is far past the chain start", () => {
  it("is fetched from its start block instead of stalling the chain", async () => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100_000,
          simulate: [
            {
              contract: "Ledger",
              event: "Transfer",
              params: { from: zero, to: owner, amount: 1n },
              srcAddress: ledger,
              block: { number: 60_000 },
            },
          ],
        },
      },
    });
    expect(await indexer.Seen.getAll()).toEqual([{ id: "60000" }]);
  });
});
`,
)
