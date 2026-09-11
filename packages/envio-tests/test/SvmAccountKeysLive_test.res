// Live test against solana.hypersync.xyz over a pinned slot window holding a
// single Kamino Lend call. The transaction is a v0 (versioned) one, so most of
// its accounts — including the Kamino program itself, at resolved index 28 —
// arrive through Address Lookup Tables rather than the static key list. An
// account index addresses the resolved list, so the static list alone makes
// index-based access point at the wrong account, silently.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM account keys test",
  )

let klendProgramId = "KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-account-keys-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 445900010
    end_slot: 445900020
programs:
  - name: KaminoLend
    program_id: ${klendProgramId}
    instructions:
      - name: refreshObligationFarmsForReserve
        discriminator: "0x02da8aeb4fc91966"
`,
  ~schema=`
type Accounts {
  id: ID!
  keyCount: Int!
  firstKey: String!
  programIsPresent: Boolean!
  programIndex: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "KaminoLend",
    instruction: "refreshObligationFarmsForReserve",
    fields: { transaction: ["signature", "accountKeys"] },
  },
  async ({ instruction, context }) => {
    const tx = instruction.transaction;
    context.Accounts.set({
      id: tx.signature,
      keyCount: tx.accountKeys.length,
      firstKey: tx.accountKeys[0] ?? "",
      programIsPresent: tx.accountKeys.includes("${klendProgramId}"),
      programIndex: tx.accountKeys.indexOf("${klendProgramId}"),
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM account keys (live)", () => {
  it("resolves lookup-table addresses into accountKeys", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 7565164: { endBlock: 445900020 } } });
    const all = await indexer.Accounts.getAll();
    // 11 static keys and 22 from the lookup tables. The first key stays the
    // static one, so indexes into the head of the list are unmoved.
    t.expect(all).toEqual([
      {
        id: "2DEzF4JEWLE5zmD4QhkCiiALaXS4qbvN1o5c6jz9Ex4jXFTJMoQwhDg7ZHH2wr35QiXYZgcWMzNqt8u6hTq5YB1B",
        keyCount: 33,
        firstKey: "7YtaMGNj4gwMFH7X5U48kvsA1pEJ7GxYn7maY216rGmM",
        programIsPresent: true,
        programIndex: 28,
      },
    ]);
  });
});
`,
)
