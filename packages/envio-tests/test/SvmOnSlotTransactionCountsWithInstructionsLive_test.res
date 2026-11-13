// Linear GTM-5262
// Live test against solana.hypersync.xyz, driven through the user API and a
// recording proxy. A slot handler counts transactions beside an instruction
// handler, whose selection would narrow a transaction selection in the same
// query to the four transactions extending an address lookup table. The
// expected counts were tallied from the JSON endpoint's transaction rows.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM onSlot transaction counts test",
  )

let proxyPort = 18566
let proxy = RecordingProxy.serveDuringSuite(
  ~port=proxyPort,
  ~upstream="https://solana.hypersync.xyz",
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-transaction-counts-with-instructions-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 460000000
    end_slot: 460000024
    hypersync_config:
      url: http://127.0.0.1:${proxyPort->Int.toString}
programs:
  - name: AddressLookupTable
    program_id: AddressLookupTab1e1111111111111111111111111
    instructions:
      - name: extend
        discriminator: "0x02000000"
`,
  ~schema=`
type SlotCounts {
  id: ID!
  transactions: Int
  failed: Int
}

type Extend {
  id: ID!
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

indexer.onInstruction(
  {
    program: "AddressLookupTable",
    instruction: "extend",
    fields: { transaction: ["transactionIndex"] },
  },
  async ({ instruction, context }) => {
    context.Extend.set({
      id: \`\${instruction.block.slot}:\${instruction.transaction.transactionIndex}\`,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onSlot transaction counts beside instructions over live HyperSync", () => {
  it("counts every transaction of a slot, not the ones the instructions matched", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 7565164: { startBlock: 460000000, endBlock: 460000024 } } });

    t.expect({
      extends: (await indexer.Extend.getAll()).map((call) => call.id).sort(),
      counts: (await indexer.SlotCounts.getAll()).sort((a, b) => a.id.localeCompare(b.id)),
    }).toEqual({
      extends: ["460000004:298", "460000007:17", "460000023:415", "460000023:469"],
      counts: [
        { id: "460000000", transactions: 418, failed: 205 },
        { id: "460000001", transactions: 338, failed: 170 },
        { id: "460000002", transactions: 346, failed: 168 },
        { id: "460000003", transactions: 384, failed: 171 },
        { id: "460000004", transactions: 362, failed: 165 },
        { id: "460000005", transactions: 486, failed: 197 },
        { id: "460000006", transactions: 398, failed: 174 },
        { id: "460000007", transactions: 409, failed: 177 },
        { id: "460000008", transactions: 292, failed: 132 },
        { id: "460000009", transactions: 351, failed: 171 },
        { id: "460000010", transactions: 383, failed: 172 },
        { id: "460000011", transactions: 398, failed: 181 },
        { id: "460000012", transactions: 340, failed: 153 },
        { id: "460000013", transactions: 319, failed: 135 },
        { id: "460000014", transactions: 325, failed: 148 },
        { id: "460000015", transactions: 353, failed: 157 },
        { id: "460000016", transactions: 191, failed: 77 },
        { id: "460000017", transactions: 298, failed: 145 },
        { id: "460000018", transactions: 390, failed: 177 },
        { id: "460000019", transactions: 412, failed: 168 },
        { id: "460000020", transactions: 827, failed: 403 },
        { id: "460000021", transactions: 401, failed: 195 },
        { id: "460000022", transactions: 357, failed: 175 },
        { id: "460000023", transactions: 503, failed: 207 },
        { id: "460000024", transactions: 609, failed: 312 },
      ],
    });
  });
});
`,
)

// The slot handler's partition and the instructions' are fetched side by side,
// so the queries are compared in a fixed order rather than as they arrived.
Vitest.it("counts the transactions in a query apart from the instructions", t => {
  let queries =
    proxy().queries->Array.toSorted((a, b) => String.compare(JSON.stringify(a), JSON.stringify(b)))
  t.expect(JSON.Array(queries)).toEqual(
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
        "block_time"
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
    "max_num_blocks": 5000,
    "max_num_logs": null,
    "account_activity": [],
    "max_num_account_activity": null
  },
  {
    "from_slot": 460000000,
    "to_slot": 460000025,
    "instruction_calls": [
      {
        "executing_account": [
          "AddressLookupTab1e1111111111111111111111111"
        ],
        "d1": [],
        "d2": [],
        "d4": [
          "0x02000000"
        ],
        "d8": [],
        "a0": [],
        "a1": [],
        "a2": [],
        "a3": [],
        "a4": [],
        "a5": [],
        "a6": [],
        "a7": [],
        "a8": [],
        "a9": [],
        "is_inner": null,
        "tx_success": true
      }
    ],
    "transactions": [],
    "include_all_blocks": false,
    "field_selection": {
      "block": [
        "slot",
        "blockhash",
        "block_time"
      ],
      "transaction": [],
      "instruction_call": [
        "slot",
        "transaction_index",
        "instruction_address",
        "executing_account",
        "data",
        "is_inner",
        "tx_success"
      ],
      "log": [],
      "account_activity": [],
      "reward": []
    },
    "max_num_instructions": 5000,
    "max_num_transactions": null,
    "logs": [],
    "max_num_blocks": null,
    "max_num_logs": null,
    "account_activity": [],
    "max_num_account_activity": null
  }
]`),
  )
})
