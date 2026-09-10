// Live test against solana.hypersync.xyz over a pinned slot window holding a
// single Kamino Lend call. The transaction is a v0 (versioned) one, so most of
// its accounts — including the Kamino program itself — arrive through Address
// Lookup Tables and are absent from the static `accountKeys`. That absence is
// the whole point of the fields: it is silent, so the test pins it.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM loaded-addresses test",
  )

let klendProgramId = "KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-loaded-addresses-live
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
  staticCount: Int!
  writableCount: Int!
  readonlyCount: Int!
  programIsStatic: Boolean!
  programIsLoaded: Boolean!
  firstWritable: String!
  allCount: Int!
  allMatchesConcatenation: Boolean!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "KaminoLend",
    instruction: "refreshObligationFarmsForReserve",
    fields: {
      transaction: [
        "signature",
        "accountKeys",
        "loadedAddressesWritable",
        "loadedAddressesReadonly",
        "allAccountKeys",
      ],
    },
  },
  async ({ instruction, context }) => {
    const tx = instruction.transaction;
    context.Accounts.set({
      id: tx.signature,
      staticCount: tx.accountKeys.length,
      writableCount: tx.loadedAddressesWritable.length,
      readonlyCount: tx.loadedAddressesReadonly.length,
      programIsStatic: tx.accountKeys.includes("${klendProgramId}"),
      programIsLoaded: tx.loadedAddressesReadonly.includes("${klendProgramId}"),
      firstWritable: tx.loadedAddressesWritable[0] ?? "",
      allCount: tx.allAccountKeys.length,
      allMatchesConcatenation:
        tx.allAccountKeys.join(",") ===
        [
          ...tx.accountKeys,
          ...tx.loadedAddressesWritable,
          ...tx.loadedAddressesReadonly,
        ].join(","),
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM loaded addresses (live)", () => {
  it("resolves ALT addresses that the static account keys omit", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 7565164: { endBlock: 445900020 } } });
    const all = await indexer.Accounts.getAll();
    t.expect(all).toEqual([
      {
        id: "2DEzF4JEWLE5zmD4QhkCiiALaXS4qbvN1o5c6jz9Ex4jXFTJMoQwhDg7ZHH2wr35QiXYZgcWMzNqt8u6hTq5YB1B",
        staticCount: 11,
        writableCount: 11,
        readonlyCount: 11,
        programIsStatic: false,
        programIsLoaded: true,
        firstWritable: "2Eff8Udy2G2gzNcf2619AnTx3xM4renEv4QrHKjS1o9N",
        allCount: 33,
        allMatchesConcatenation: true,
      },
    ]);
  });
});
`,
)
