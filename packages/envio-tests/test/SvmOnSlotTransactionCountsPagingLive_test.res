// Linear GTM-5262
// Live test against solana.hypersync.xyz. The server ends a counting page near
// 197,000 transactions, about 486 slots, so 1,000 slots take several pages. A
// slot split or repeated across two pages would change the totals. The expected
// values were tallied from the JSON endpoint's transaction rows for the same
// slots.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM onSlot transaction counts test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-transaction-counts-paging-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 460000000
    end_slot: 460000999
`,
  ~schema=`
type SlotCounts {
  id: ID!
  transactions: Int
  failed: Int
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onSlot(
  { name: "counts", fields: { block: ["transactionCount", "failedTransactionCount"] } },
  async ({ slot, block, context }) => {
    context.SlotCounts.set({
      id: \`\${slot}\`,
      transactions: block?.transactionCount,
      failed: block?.failedTransactionCount,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot transaction counts across HyperSync pages", () => {
  it("counts every transaction of 1,000 slots once", { timeout: 120_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 7565164: { startBlock: 460000000, endBlock: 460000999 } } });

    const rows = await indexer.SlotCounts.getAll();
    const byId = Object.fromEntries(rows.map((row) => [row.id, row]));
    const counted = rows.filter((row) => row.transactions !== undefined);
    t.expect({
      slots: rows.length,
      skipped: rows.filter((row) => row.transactions === undefined).map((row) => row.id).sort(),
      transactions: counted.reduce((sum, row) => sum + row.transactions!, 0),
      failed: counted.reduce((sum, row) => sum + row.failed!, 0),
      firstPageEnd: byId["460000485"],
      secondPageStart: byId["460000486"],
    }).toEqual({
      slots: 1000,
      skipped: ["460000985", "460000986", "460000987"],
      transactions: 379433,
      failed: 164305,
      firstPageEnd: { id: "460000485", transactions: 267, failed: 74 },
      secondPageStart: { id: "460000486", transactions: 197, failed: 51 },
    });
  });
});
`,
)
