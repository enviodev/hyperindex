let programId = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let payerPk = "So11111111111111111111111111111111111111112"
let authorityPk = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
let mintPk = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"

let _ = InternalTestIndexer.fromUserApi(
  ~schema=`
type Swap {
  id: ID!
  payer: String!
  authority: String!
  mint: String!
}
`,
  ~configYaml=`
name: svm-optional-accounts-simulate
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: ${programId}
          instructions:
            - name: swap
              discriminator: "0x09"
              args: []
              accounts:
                - payer
                - ?authority
                - _
                - mint
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    fields: { instruction: ["accounts"] },
  },
  async ({ instruction, context }) => {
    context.Swap.set({
      id: instruction.block.slot.toString(),
      payer: instruction.accounts.payer.address,
      authority: instruction.accounts.authority?.address ?? "absent",
      mint: instruction.accounts.mint.address,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM optional accounts through simulate", () => {
  it("leaves an omitted optional account off the payload", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "Swapper",
              instruction: "swap",
              slot: 1,
              accounts: {
                payer: { address: "${payerPk}" },
                mint: { address: "${mintPk}" },
              },
            },
            {
              program: "Swapper",
              instruction: "swap",
              slot: 2,
              accounts: {
                payer: { address: "${payerPk}" },
                authority: { address: "${authorityPk}" },
                mint: { address: "${mintPk}" },
              },
            },
          ],
        },
      },
    });
    t.expect([await indexer.Swap.getOrThrow("1"), await indexer.Swap.getOrThrow("2")]).toEqual([
      { id: "1", payer: "${payerPk}", authority: "absent", mint: "${mintPk}" },
      { id: "2", payer: "${payerPk}", authority: "${authorityPk}", mint: "${mintPk}" },
    ]);
  });

  it("refuses a simulated item that leaves out a required account", async (t) => {
    const indexer = createTestIndexer();
    await t
      .expect(
        indexer.process({
          chains: {
            7565164: {
              simulate: [
                {
                  program: "Swapper",
                  instruction: "swap",
                  slot: 1,
                  accounts: { mint: { address: "${mintPk}" } },
                },
              ],
            },
          },
        }),
      )
      .rejects.toThrow(
        'simulate: instruction "swap" on program "Swapper" declares the account "payer", and the simulated item leaves it out. Add it to "accounts", or mark the slot optional with "?payer" in config.yaml.',
      );
  });
});
`,
)
