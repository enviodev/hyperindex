// Regression: an onSlot-only indexer (no contracts, no event partitions) used
// to get stuck after resuming from a checkpoint. On resume the buffer started
// empty and nothing repopulated it, so getNextQuery never produced work and the
// indexer never advanced past the resumed progress block. Migrated from
// scenarios/svm_test.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot
ecosystem: svm
chains:
  - rpc: https://api.mainnet-beta.solana.com
    start_block: 0
`,
  ~schema=`
type SlotPing {
  id: ID!
  slot: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

// The \`{slot: {_every: 5}}\` filter hits the SVM-specific decoder branch in
// \`extractRange\`.
indexer.onSlot(
  {
    name: "SlotSampler",
    where: ({ chain }) => (chain.id === 0 ? { slot: { _every: 5 } } : false),
  },
  async ({ slot, context }) => {
    context.SlotPing.set({ id: slot.toString(), slot });
  },
);

// No-\`where\` registration — exercises the branch where the handler registers
// on every configured chain.
indexer.onSlot({ name: "SlotPingDefault" }, async () => {});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot-only indexer", () => {
  it("keeps progressing after a resume", async (t) => {
    const indexer = createTestIndexer();

    // Initial run up to slot 9.
    await indexer.process({ chains: { 0: { startBlock: 0, endBlock: 9 } } });

    // Resume from slot 10 up to 19. Before the fix this run got stuck and
    // produced no new SlotPing entities.
    await indexer.process({ chains: { 0: { startBlock: 10, endBlock: 19 } } });

    const slots = (await indexer.SlotPing.getAll()).map((ping) => ping.slot);
    t.expect([...slots].sort((a, b) => a - b)).toEqual([0, 5, 10, 15]);
  });
});
`,
)
