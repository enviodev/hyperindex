let programId = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let payerPk = "So11111111111111111111111111111111111111112"
let authorityPk = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
let skippedPk = "Sysvar1nstructions1111111111111111111111111"
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
    start_slot: 0
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

  // Positional accounts are what a call actually carries, so an item written
  // that way has to spell an absent optional the way chain does: the id of the
  // program being invoked, sitting in the slot.
  it("reads the program id in an optional slot of a positional item as absent", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        7565164: {
          simulate: [
            {
              program: "Swapper",
              instruction: "swap",
              slot: 1,
              accountArguments: ["${payerPk}", "${programId}", "${skippedPk}", "${mintPk}"],
            },
            {
              program: "Swapper",
              instruction: "swap",
              slot: 2,
              accountArguments: ["${payerPk}", "${authorityPk}", "${skippedPk}", "${mintPk}"],
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

  // An item names the accounts it has something to say about, not every slot
  // the layout declares.
  it("stands the program id in for a slot the item does not name", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
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
    });
    t.expect(await indexer.Swap.getOrThrow("1")).toEqual({
      id: "1",
      payer: "${programId}",
      authority: "absent",
      mint: "${mintPk}",
    });
  });
});
`,
)
