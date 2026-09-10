let feePayerAddr = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let blockhash = "So11111111111111111111111111111111111111112"
let altWritable = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
let altReadonly = "11111111111111111111111111111111"
let signature = "5j7s6NiJS3JAkvgkoc18WVAsiSaci2pxB2A6ueCJP4tprA2TFg9wSyTLeYouxPBJEMzJinENTkpA52YStRW5Dia7"

let _ = InternalTestIndexer.fromUserApi(
  ~schema=`
type SimTx {
  id: ID!
  slot: Int!
  signature: String!
  allSignatures: [String!]!
  feePayer: String!
  success: Boolean!
  err: String
  fee: BigInt!
  computeUnitsConsumed: BigInt!
  accountKeys: [String!]!
  loadedAddressesWritable: [String!]!
  loadedAddressesReadonly: [String!]!
  recentBlockhash: String!
  version: String!
}
`,
  ~configYaml=`
name: svm-simulate-transaction
ecosystem: svm
chains:
  - id: solana
    start_slot: 100
programs:
  - name: Swapper
    program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
    instructions:
      - name: swap
        discriminator: "0x09"
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    fields: {
      transaction: [
        "signature",
        "allSignatures",
        "feePayer",
        "success",
        "err",
        "fee",
        "computeUnitsConsumed",
        "accountKeys",
        "loadedAddressesWritable",
        "loadedAddressesReadonly",
        "recentBlockhash",
        "version",
      ],
    },
  },
  async ({ instruction, context }) => {
    const tx = instruction.transaction;
    context.SimTx.set({
      id: "tx",
      slot: instruction.block.slot,
      signature: tx.signature,
      allSignatures: tx.allSignatures,
      feePayer: tx.feePayer,
      success: tx.success,
      err: tx.err,
      fee: tx.fee,
      computeUnitsConsumed: tx.computeUnitsConsumed ?? 0n,
      accountKeys: tx.accountKeys,
      loadedAddressesWritable: tx.loadedAddressesWritable,
      loadedAddressesReadonly: tx.loadedAddressesReadonly,
      recentBlockhash: tx.recentBlockhash,
      version: tx.version ?? "",
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const feePayerAddr = "${feePayerAddr}";
const blockhash = "${blockhash}";
const signature = "${signature}";
const altWritable = "${altWritable}";
const altReadonly = "${altReadonly}";

describe("SVM simulate transaction fields", () => {
  // A top-level \`slot\` is the documented way to place an SVM simulate item; it
  // also has to widen the processed range, or the item falls outside it and
  // never reaches the handler.
  it("routes an item placed by top-level slot and carries its transaction fields", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "Swapper",
              instruction: "swap",
              slot: 142,
              transaction: {
                signature,
                allSignatures: [signature],
                feePayer: feePayerAddr,
                success: true,
                fee: 5000n,
                computeUnitsConsumed: 1234n,
                accountKeys: [feePayerAddr],
                loadedAddressesWritable: [altWritable],
                loadedAddressesReadonly: [altReadonly],
                recentBlockhash: blockhash,
                version: "legacy",
              },
            },
          ],
        },
      },
    });

    t.expect(await indexer.SimTx.getOrThrow("tx")).toEqual({
      id: "tx",
      slot: 142,
      signature,
      allSignatures: [signature],
      feePayer: feePayerAddr,
      success: true,
      err: undefined,
      fee: 5000n,
      computeUnitsConsumed: 1234n,
      accountKeys: [feePayerAddr],
      loadedAddressesWritable: [altWritable],
      loadedAddressesReadonly: [altReadonly],
      recentBlockhash: blockhash,
      version: "legacy",
    });
  });
});
`,
)
