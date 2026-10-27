// Live test against solana.hypersync.xyz, driven through the user API and a
// recording proxy. The expected fields were read from a public Solana RPC,
// which reports slots 420650429 and 420656316 as skipped. `sparse` runs every
// 3000 slots from a skipped one, so the source reads its slots one at a time
// and the first has no block. `dense` runs on every slot of a window holding a
// skipped slot; within 1000 slots of it the page reads the whole range.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM onSlot fields test",
  )

let proxyPort = 18560
let proxy = RecordingProxy.serveDuringSuite(
  ~port=proxyPort,
  ~upstream="https://solana.hypersync.xyz",
)

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-fields-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 420650000
    end_slot: 420656500
    hypersync_config:
      url: http://127.0.0.1:${proxyPort->Int.toString}
`,
  ~schema=`
type SeenSlot {
  id: ID!
  time: Int
  hash: String
  height: Int
}
`,
  ~handlers=`
import { indexer, type SvmOnSlotHandler } from "envio";

const fields = { block: ["time", "hash", "height"] } as const;

const record =
  (name: string): SvmOnSlotHandler<typeof fields> =>
  async ({ slot, block, context }) => {
    context.SeenSlot.set({
      id: \`\${name}:\${slot}\`,
      time: block?.time,
      hash: block?.hash,
      height: block?.height,
    });
  };

indexer.onSlot(
  {
    name: "sparse",
    where: () => ({ slot: { _gte: 420650429, _every: 3000 } }),
    fields,
  },
  record("sparse"),
);

indexer.onSlot(
  {
    name: "dense",
    where: () => ({ slot: { _gte: 420656310, _lte: 420656320 } }),
    fields,
  },
  record("dense"),
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const skipped = (id: string) => ({ id, time: undefined, hash: undefined, height: undefined });

describe("onSlot fields over live HyperSync", () => {
  it("runs on every slot, with the block where the slot produced one", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 7565164: { startBlock: 420650000, endBlock: 420656500 } } });

    t.expect(
      (await indexer.SeenSlot.getAll()).sort((a, b) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "dense:420656310", time: 1779148428, hash: "Hfmh7LLy5WhrjcTghWoANwaZ3cm1Gi5pwKHLSi6eman9", height: 398745695 },
      { id: "dense:420656311", time: 1779148428, hash: "gpEQdfmRNgXUu1ncXhDECpRud9LQDbsd1LiAz6XQvCA", height: 398745696 },
      { id: "dense:420656312", time: 1779148428, hash: "9rFPBd1vqgmysciM8SqcY6kPuZrjFGEnTtFZvfURzfaK", height: 398745697 },
      { id: "dense:420656313", time: 1779148429, hash: "BxfLojKqWdR1JJTxAQMQgoEeZm5AfW6j8qQ9NwvecHDz", height: 398745698 },
      { id: "dense:420656314", time: 1779148430, hash: "6hQ3iTaCjnUGKeBacEkP2iAkqQEf3EwaCa5VxkmSMQq1", height: 398745699 },
      { id: "dense:420656315", time: 1779148431, hash: "3MvDjWsZsznF957jDvT5MQxJWp9fZaR7T7f8LbL7bH1p", height: 398745700 },
      skipped("dense:420656316"),
      { id: "dense:420656317", time: 1779148433, hash: "FBtXpWBnWcZok5Hk8XSUXSBeqqtcH18rxnVm3UsnG3Ph", height: 398745701 },
      { id: "dense:420656318", time: 1779148433, hash: "4EvEiPbB522gJ3Pzb5vbXvBbc8NmuRRWQSArqRzZmEYw", height: 398745702 },
      { id: "dense:420656319", time: 1779148433, hash: "4bdnrw7haFGK6k6UXUmMEYvutpfT3Xk6MqdyBQ9Ykyjb", height: 398745703 },
      { id: "dense:420656320", time: 1779148434, hash: "3D1kcG8K5mDTzPUpfE963bhk8Pu1RQFaTktCvcEL8hSV", height: 398745704 },
      skipped("sparse:420650429"),
      { id: "sparse:420653429", time: 1779147288, hash: "5cTVTyCTkVstswG5VZEzo9exzeRiKgwMwT3nKkJXkX3i", height: 398742818 },
      { id: "sparse:420656429", time: 1779148477, hash: "HicGSUAisvsxPgj854WpPVpAmejdgb6Dv9FYuJ1dyVog", height: 398745813 },
    ]);
  });
});
`,
)

// The source's own queries, as the server received them: a slot-by-slot read
// of each sparse slot, the first of them skipped, then the dense window's range
// to the end. Account activity is selected out, as nothing reads it.
Vitest.it("sends the queries the read plan names", t => {
  t.expect(JSON.Array(proxy().queries)).toEqual(
    JSON.parseOrThrow(`[
  {
    "from_slot": 420650429,
    "to_slot": 420650430,
    "instruction_calls": [],
    "transactions": [],
    "include_all_blocks": true,
    "field_selection": {
      "block": [
        "slot",
        "blockhash",
        "block_time",
        "block_height"
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
    "max_num_instructions": 10000,
    "max_num_transactions": null,
    "logs": [],
    "max_num_blocks": null,
    "max_num_logs": null,
    "account_activity": [
      {
        "kind": [],
        "account": [],
        "transaction_id": [
          "1111111111111111111111111111111111111111111111111111111111111111"
        ],
        "mint": [],
        "owner": [],
        "program_id": [],
        "is_signer": null,
        "is_writable": null,
        "is_fee_payer": null,
        "from_lookup_table": null
      }
    ],
    "max_num_account_activity": null
  },
  {
    "from_slot": 420653429,
    "to_slot": 420653430,
    "instruction_calls": [],
    "transactions": [],
    "include_all_blocks": true,
    "field_selection": {
      "block": [
        "slot",
        "blockhash",
        "block_time",
        "block_height"
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
    "max_num_instructions": 2,
    "max_num_transactions": null,
    "logs": [],
    "max_num_blocks": null,
    "max_num_logs": null,
    "account_activity": [
      {
        "kind": [],
        "account": [],
        "transaction_id": [
          "1111111111111111111111111111111111111111111111111111111111111111"
        ],
        "mint": [],
        "owner": [],
        "program_id": [],
        "is_signer": null,
        "is_writable": null,
        "is_fee_payer": null,
        "from_lookup_table": null
      }
    ],
    "max_num_account_activity": null
  },
  {
    "from_slot": 420656310,
    "to_slot": 420656501,
    "instruction_calls": [],
    "transactions": [],
    "include_all_blocks": true,
    "field_selection": {
      "block": [
        "slot",
        "blockhash",
        "block_time",
        "block_height"
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
    "max_num_instructions": null,
    "max_num_transactions": null,
    "logs": [],
    "max_num_blocks": null,
    "max_num_logs": null,
    "account_activity": [
      {
        "kind": [],
        "account": [],
        "transaction_id": [
          "1111111111111111111111111111111111111111111111111111111111111111"
        ],
        "mint": [],
        "owner": [],
        "program_id": [],
        "is_signer": null,
        "is_writable": null,
        "is_fee_payer": null,
        "from_lookup_table": null
      }
    ],
    "max_num_account_activity": null
  }
]`),
  )
})
