import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

// `start_slot` from config.yaml. Simulated instructions are placed by slot and
// only run when the slot is inside the configured range.
const START_SLOT = 445_000_000;
const SOLANA = 7565164;

const USDC = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";
const WSOL = "So11111111111111111111111111111111111111112";

const SOURCE = "3emsAVdmGKERbHjmGfQ6oZ1e35dkf5z6TmFZBrwMiWmC";
const DESTINATION = "7VHUFJHWu2CuExkJcJrzhQPJ2oygupTWkL2A2For4BmE";
const AUTHORITY = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM";
const SIGNATURE =
  "5j7s6NiJS3JAkvgkoc18WVAsiSaci2pxB2A6ueCJP4tprA2TFg9wSyTLeYouxPBJEMzJinENTkpA52YStRW5Dia7";

describe("USDC transfers", () => {
  it("stores a transferChecked of the tracked mint", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        [SOLANA]: {
          simulate: [
            {
              program: "SplToken",
              instruction: "transferChecked",
              slot: START_SLOT,
              path: [1, 0],
              args: { amount: 250_000n, decimals: 6 },
              accounts: {
                source: { address: SOURCE },
                mint: { address: USDC },
                destination: { address: DESTINATION },
                authority: { address: AUTHORITY },
              },
              block: { time: 1_800_000_000 },
              transaction: { signature: SIGNATURE, transactionIndex: 4 },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Transfer.getAll()).toEqual([
      {
        id: `${START_SLOT}-4-1.0`,
        amount: 250_000n,
        source: SOURCE,
        destination: DESTINATION,
        signer: AUTHORITY,
        txSignature: SIGNATURE,
        slot: START_SLOT,
        timestamp: 1_800_000_000,
        checked: true,
        chainId: SOLANA,
      },
    ]);
  });

  it("resolves a plain transfer's mint from token balances, and drops other mints", async (t) => {
    const indexer = createTestIndexer();

    const transfer = (mint: string, transactionIndex: number) => ({
      program: "SplToken" as const,
      instruction: "transfer" as const,
      slot: START_SLOT,
      path: [0],
      args: { amount: 1_000n },
      accounts: {
        source: { address: SOURCE },
        destination: { address: DESTINATION },
        authority: { address: AUTHORITY },
      },
      block: { time: 1_800_000_000 },
      transaction: {
        signature: SIGNATURE,
        transactionIndex,
        // The source was opened by this very transaction, so only the
        // destination reports a balance — the case reading both accounts exists
        // to cover.
        accountActivities: [{ address: DESTINATION, token: { mint } }],
      },
    });

    await indexer.process({
      chains: { [SOLANA]: { simulate: [transfer(USDC, 0), transfer(WSOL, 1)] } },
    });

    t.expect(await indexer.Transfer.getAll()).toEqual([
      {
        id: `${START_SLOT}-0-0`,
        amount: 1_000n,
        source: SOURCE,
        destination: DESTINATION,
        signer: AUTHORITY,
        txSignature: SIGNATURE,
        slot: START_SLOT,
        timestamp: 1_800_000_000,
        checked: false,
        chainId: SOLANA,
      },
    ]);
  });
});
