// A slot handler names the block fields it reads with the same `fields`
// option. Selecting fields doesn't change which slots it runs on: a slot the
// chain skipped produced no block, so there the handler gets none — in a
// simulation, every slot not given a block.
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
  time: Int
  hash: String
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onSlot(
  { name: "blocks", fields: { block: ["time", "hash"] } },
  async ({ slot, block, context }) => {
    // @ts-expect-error - a skipped slot has no block
    const _time = () => block.time;
    // @ts-expect-error - only time and hash are selected
    const _height: number | undefined = block?.height;
    context.SlotBlock.set({ id: \`\${slot}\`, time: block?.time, hash: block?.hash });
  },
);

// The slot is the handler's own argument, so selecting only it selects no block.
indexer.onSlot({ name: "slots", fields: { block: ["slot"] } }, async (args) => {
  // @ts-expect-error - no block field beyond the slot is selected
  args.block;
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot field selection", () => {
  it("runs on every slot, with the selected fields where the slot has a block", async (t) => {
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
      (await indexer.SlotBlock.getAll()).sort((a, b) => Number(a.id) - Number(b.id)),
    ).toEqual([
      { id: "0", time: undefined, hash: undefined },
      { id: "1", time: 1_700_000_001, hash: "slot1" },
      { id: "2", time: undefined, hash: undefined },
      { id: "3", time: 1_700_000_003, hash: "slot3" },
      { id: "4", time: undefined, hash: undefined },
    ]);
  });
});
`,
)
