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

// No-`where` registration — exercises the `None` branch in
// `Main.res::onBlockFn` (where `result` defaults to `true` and the handler
// registers on every configured chain). Lives in svm_test rather than
// test_codegen because test_codegen's simulate tests deep-equal
// `result.changes` and a default-fires-everywhere handler would pollute
// every block. svm_test has no such assertions, so registration here
// covers the otherwise-untested code path without breaking other tests.
indexer.onSlot({ name: "SlotPingDefault" }, async () => {});
