import { indexer } from "generated";

// Minimum exercise of `indexer.onSlot` on SVM. The flat filter `{_every: 5}`
// hits the new SVM-specific decoder branch in `Main.res::extractRange`.
indexer.onSlot(
  {
    name: "SlotSampler",
    where: ({ chain }) => (chain.id === 0 ? { _every: 5 } : false),
  },
  async ({ slot, context }) => {
    context.SlotPing.set({ id: slot.toString(), slot });
  },
);
