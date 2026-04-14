import { indexer } from "generated";

// Minimum exercise of `indexer.onSlot` on SVM. The `{slot: {_every: 5}}`
// filter hits the SVM-specific decoder branch in `Main.res::extractRange`.
indexer.onSlot(
  {
    name: "SlotSampler",
    where: ({ chain }) => (chain.id === 0 ? { slot: { _every: 5 } } : false),
  },
  async ({ slot, context }) => {
    context.SlotPing.set({ id: slot.toString(), slot });
  },
);
