// Live test against solana.hypersync.xyz, driven through the user API. The
// expected fields were read from a public Solana RPC, which reports slots
// 420650428-431 as skipped. `dense` runs on every slot of a window holding
// them; `sparse` runs every 3000 slots from a skipped one, so the source reads
// its slots one at a time and the first has no block. Past its last slot no
// handler runs, which the source answers for without a query: one selecting
// nothing would return every instruction.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM onSlot fields test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-onslot-fields-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 420650000
    end_slot: 420656500
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
    name: "dense",
    where: () => ({ slot: { _gte: 420650425, _lte: 420650434 } }),
    fields,
  },
  record("dense"),
);

indexer.onSlot(
  {
    name: "sparse",
    where: () => ({ slot: { _gte: 420650429, _every: 3000 } }),
    fields,
  },
  record("sparse"),
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
      { id: "dense:420650425", time: 1779146096, hash: "H6TScZZXsNGDRvAXxx7FvNQeRxToRqj4jVMazAfcyVmt", height: 398739822 },
      { id: "dense:420650426", time: 1779146096, hash: "E7d4Tu3RsbdDyiHCC5JkZ4nKkbDruoP6Rwz3aqRmZFYD", height: 398739823 },
      { id: "dense:420650427", time: 1779146096, hash: "EbeqZvY83aatAKRBZXdqbUmXrWidyFW7ZqAwe7DjGZ79", height: 398739824 },
      skipped("dense:420650428"),
      skipped("dense:420650429"),
      skipped("dense:420650430"),
      skipped("dense:420650431"),
      { id: "dense:420650432", time: 1779146099, hash: "EbhUuLTzov2S4ptRXFa34dq3q4Lk73ThisPeRG6NCKTB", height: 398739825 },
      { id: "dense:420650433", time: 1779146099, hash: "5Lyd7QCHPrx9GMYBn9ug54CZKEvKNc3wopxG4CStJBbV", height: 398739826 },
      { id: "dense:420650434", time: 1779146099, hash: "B768zjRUPR5MYVd2K6ZBRxZPAN7hqbX1PA2gzdBujVQU", height: 398739827 },
      skipped("sparse:420650429"),
      { id: "sparse:420653429", time: 1779147288, hash: "5cTVTyCTkVstswG5VZEzo9exzeRiKgwMwT3nKkJXkX3i", height: 398742818 },
      { id: "sparse:420656429", time: 1779148477, hash: "HicGSUAisvsxPgj854WpPVpAmejdgb6Dv9FYuJ1dyVog", height: 398745813 },
    ]);
  });
});
`,
)
