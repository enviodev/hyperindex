// Linear GTM-5262
// A slot handler selects counts of the slot's stored transactions, which leave
// out votes, beside the block's own fields. A block that stored none counts
// zero, where a skipped slot has no block to count on.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-transaction-counts
ecosystem: svm
chains:
  - id: solana
    rpc: https://api.mainnet-beta.solana.com
    start_slot: 0
`,
  ~schema=`
type SlotCounts {
  id: ID!
  time: Int
  transactions: Int
  failed: Int
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onSlot(
  { name: "counts", fields: { block: ["time", "transactionCount", "failedTransactionCount"] } },
  async ({ slot, block, context }) => {
    // @ts-expect-error - a skipped slot has no block
    const _count = () => block.transactionCount;
    // @ts-expect-error - parentSlot is not selected
    const _parentSlot: number | undefined = block?.parentSlot;
    const transactions: number | undefined = block?.transactionCount;
    const failed: number | undefined = block?.failedTransactionCount;
    context.SlotCounts.set({ id: \`\${slot}\`, time: block?.time, transactions, failed });
  },
);

indexer.onSlot({ name: "time", fields: { block: ["time"] } }, async ({ block }) => {
  // @ts-expect-error - transactionCount is not selected
  const _count: number | undefined = block?.transactionCount;
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot transaction counts", () => {
  it("counts the transactions of every slot that has a block", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          startBlock: 0,
          endBlock: 3,
          simulate: [
            { block: { slot: 1, time: 1_700_000_001, transactionCount: 9, failedTransactionCount: 4 } },
            { block: { slot: 3, time: 1_700_000_003, transactionCount: 0, failedTransactionCount: 0 } },
          ],
        },
      },
    });
    t.expect(
      (await indexer.SlotCounts.getAll()).sort((a, b) => Number(a.id) - Number(b.id)),
    ).toEqual([
      { id: "0", time: undefined, transactions: undefined, failed: undefined },
      { id: "1", time: 1_700_000_001, transactions: 9, failed: 4 },
      { id: "2", time: undefined, transactions: undefined, failed: undefined },
      { id: "3", time: 1_700_000_003, transactions: 0, failed: 0 },
    ]);
  });
});
`,
)
