// Linear GTM-5262
// Live test against solana.hypersync.xyz, driven through the user API and a
// recording proxy. The expected counts were tallied from the JSON endpoint's
// transaction rows for the same slots: 9,890 transactions over 25 blocks, of
// which 4,535 failed.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM onSlot transaction counts test",
  )

let proxyPort = 18564
let proxy = RecordingProxy.serveDuringSuite(
  ~port=proxyPort,
  ~upstream="https://solana.hypersync.xyz",
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-transaction-counts-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 460000000
    end_slot: 460000024
    hypersync_config:
      url: http://127.0.0.1:${proxyPort->Int.toString}
`,
  ~schema=`
type SlotCounts {
  id: ID!
  time: Int
  parentSlot: Int
  transactions: Int
  failed: Int
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onSlot(
  {
    name: "counts",
    fields: { block: ["time", "parentSlot", "transactionCount", "failedTransactionCount"] },
  },
  async ({ slot, block, context }) => {
    context.SlotCounts.set({
      id: \`\${slot}\`,
      time: block?.time,
      parentSlot: block?.parentSlot,
      transactions: block?.transactionCount,
      failed: block?.failedTransactionCount,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot transaction counts over live HyperSync", () => {
  it("counts every slot's transactions and the failed ones", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 7565164: { startBlock: 460000000, endBlock: 460000024 } } });

    t.expect(
      (await indexer.SlotCounts.getAll()).sort((a, b) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "460000000", time: 1792664613, parentSlot: 459999999, transactions: 418, failed: 205 },
      { id: "460000001", time: 1792664613, parentSlot: 460000000, transactions: 338, failed: 170 },
      { id: "460000002", time: 1792664614, parentSlot: 460000001, transactions: 346, failed: 168 },
      { id: "460000003", time: 1792664614, parentSlot: 460000002, transactions: 384, failed: 171 },
      { id: "460000004", time: 1792664614, parentSlot: 460000003, transactions: 362, failed: 165 },
      { id: "460000005", time: 1792664614, parentSlot: 460000004, transactions: 486, failed: 197 },
      { id: "460000006", time: 1792664614, parentSlot: 460000005, transactions: 398, failed: 174 },
      { id: "460000007", time: 1792664615, parentSlot: 460000006, transactions: 409, failed: 177 },
      { id: "460000008", time: 1792664615, parentSlot: 460000007, transactions: 292, failed: 132 },
      { id: "460000009", time: 1792664615, parentSlot: 460000008, transactions: 351, failed: 171 },
      { id: "460000010", time: 1792664615, parentSlot: 460000009, transactions: 383, failed: 172 },
      { id: "460000011", time: 1792664615, parentSlot: 460000010, transactions: 398, failed: 181 },
      { id: "460000012", time: 1792664616, parentSlot: 460000011, transactions: 340, failed: 153 },
      { id: "460000013", time: 1792664616, parentSlot: 460000012, transactions: 319, failed: 135 },
      { id: "460000014", time: 1792664616, parentSlot: 460000013, transactions: 325, failed: 148 },
      { id: "460000015", time: 1792664616, parentSlot: 460000014, transactions: 353, failed: 157 },
      { id: "460000016", time: 1792664616, parentSlot: 460000015, transactions: 191, failed: 77 },
      { id: "460000017", time: 1792664617, parentSlot: 460000016, transactions: 298, failed: 145 },
      { id: "460000018", time: 1792664617, parentSlot: 460000017, transactions: 390, failed: 177 },
      { id: "460000019", time: 1792664617, parentSlot: 460000018, transactions: 412, failed: 168 },
      { id: "460000020", time: 1792664617, parentSlot: 460000019, transactions: 827, failed: 403 },
      { id: "460000021", time: 1792664618, parentSlot: 460000020, transactions: 401, failed: 195 },
      { id: "460000022", time: 1792664618, parentSlot: 460000021, transactions: 357, failed: 175 },
      { id: "460000023", time: 1792664618, parentSlot: 460000022, transactions: 503, failed: 207 },
      { id: "460000024", time: 1792664618, parentSlot: 460000023, transactions: 609, failed: 312 },
    ]);
  });
});
`,
)

// One query reads the blocks and every transaction's slot and outcome. It
// selects no instruction column: joined to a selection matching every
// transaction, the server would return each one's instructions.
Vitest.it("asks for the blocks and each transaction's slot and outcome alone", t => {
  t.expect(JSON.Array(proxy().queries)).toEqual(
    JSON.parseOrThrow(`[
  {
    "from_slot": 460000000,
    "to_slot": 460000025,
    "instruction_calls": [],
    "transactions": [
      {
        "fee_payer": [],
        "transaction_id": [],
        "transaction_index": [],
        "success": null
      }
    ],
    "include_all_blocks": true,
    "field_selection": {
      "block": [
        "slot",
        "blockhash",
        "block_time",
        "parent_slot"
      ],
      "transaction": [
        "slot",
        "success"
      ],
      "instruction_call": [],
      "log": [],
      "account_activity": [],
      "reward": []
    },
    "max_num_instructions": null,
    "max_num_transactions": 1000000,
    "logs": [],
    "max_num_blocks": 10000,
    "max_num_logs": null,
    "account_activity": [],
    "max_num_account_activity": null
  }
]`),
  )
})
