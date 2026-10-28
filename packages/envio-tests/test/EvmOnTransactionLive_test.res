// Live test against eth.hypersync.xyz: a transaction handler on a busy
// mainnet wallet over a short range, so every row must be from that wallet
// and there must be some.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live EVM onTransaction test",
  )

let wallet = "0x28C6c06298d514Db089934071355E5743bf21d60"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: evm-ontransaction-live
chains:
  - id: 1
    start_block: 23500000
    end_block: 23500009
`,
  ~schema=`
type Seen {
  id: ID!
  from: String!
  to: String!
  value: BigInt!
  status: Int!
  timestamp: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onTransaction(
  {
    name: "hot-wallet",
    where: () => ({ transaction: { from: ["${wallet}"] } }),
    fields: { transaction: ["value", "status"], block: ["timestamp"] },
  },
  async ({ transaction, block, context }) => {
    context.Seen.set({
      id: transaction.hash,
      from: transaction.from ?? "none",
      to: transaction.to ?? "none",
      value: transaction.value,
      status: transaction.status ?? -1,
      timestamp: block.timestamp,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("onTransaction over live HyperSync", () => {
  it("runs on every transaction the wallet sent in the range", { timeout: 60_000 }, async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: 23500000, endBlock: 23500009 } } });
    const rows = await indexer.Seen.getAll();
    t.expect({
      atLeastOne: rows.length > 0,
      senders: [...new Set(rows.map((row) => row.from.toLowerCase()))],
      hashes: rows.every((row) => /^0x[0-9a-f]{64}$/.test(row.id)),
      timestamps: rows.every((row) => row.timestamp > 1_700_000_000),
      statuses: [...new Set(rows.map((row) => row.status))].every((s) => s === 0 || s === 1),
    }).toEqual({
      atLeastOne: true,
      senders: ["${wallet}".toLowerCase()],
      hashes: true,
      timestamps: true,
      statuses: true,
    });
  });
});
`,
)
