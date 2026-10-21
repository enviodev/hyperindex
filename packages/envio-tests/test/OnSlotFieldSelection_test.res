// A slot handler names the block fields it reads with the same `fields`
// option. Only a slot that produced a block has them, so a handler selecting
// fields runs on those slots alone — in a simulation, the slots given a block.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-fields
ecosystem: svm
chains:
  - id: solana
    rpc: https://api.mainnet-beta.solana.com
    start_slot: 0
`,
  ~schema=`
type SlotBlock {
  id: ID!
  time: Int!
  hash: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onSlot(
  { name: "blocks", fields: { block: ["time", "hash"] } },
  async ({ slot, block, context }) => {
    // @ts-expect-error - only time and hash are selected
    const _height: number = block.height;
    context.SlotBlock.set({ id: \`\${slot}\`, time: block.time, hash: block.hash });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot field selection", () => {
  it("hands the handler the selected fields of each slot's block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          startBlock: 0,
          endBlock: 4,
          simulate: [
            { block: { slot: 1, time: 1_700_000_001, hash: "slot1" } },
            { block: { slot: 3, time: 1_700_000_003, hash: "slot3" } },
          ],
        },
      },
    });
    t.expect(
      (await indexer.SlotBlock.getAll()).sort((a, b) => a.time - b.time),
    ).toEqual([
      { id: "1", time: 1_700_000_001, hash: "slot1" },
      { id: "3", time: 1_700_000_003, hash: "slot3" },
    ]);
  });
});
`,
)
