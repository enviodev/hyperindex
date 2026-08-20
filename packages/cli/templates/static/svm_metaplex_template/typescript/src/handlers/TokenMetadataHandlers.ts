/*
 * Metaplex Token Metadata demo handler.
 * See https://docs.envio.dev for a thorough guide on indexer features.
 */
import { indexer, type ProgramStats } from "envio";

const STATS_ID = "metaplex-token-metadata";

async function bumpStats(
  context: {
    ProgramStats: {
      get: (id: string) => Promise<ProgramStats | undefined>;
      set: (e: ProgramStats) => void;
    };
  },
  kind: "create" | "update",
) {
  const prev = await context.ProgramStats.get(STATS_ID);
  const next: ProgramStats =
    prev === undefined
      ? {
          id: STATS_ID,
          totalInstructions: 1,
          createCount: kind === "create" ? 1 : 0,
          updateCount: kind === "update" ? 1 : 0,
        }
      : {
          ...prev,
          totalInstructions: prev.totalInstructions + 1,
          createCount: prev.createCount + (kind === "create" ? 1 : 0),
          updateCount: prev.updateCount + (kind === "update" ? 1 : 0),
        };
  context.ProgramStats.set(next);
}

const metaplexFields = {
  instruction: ["accountArguments"],
  transaction: ["signature"],
} as const;

indexer.onInstruction(
  { program: "TokenMetadata", instruction: "CreateMetadataAccountV3", fields: metaplexFields },
  async ({ instruction, context }) => {
    const { accountArguments } = instruction;
    const metadataPda = accountArguments[0];
    if (metadataPda === undefined) return;
    const mint = accountArguments[1] ?? "";
    const updateAuthority = accountArguments[4];
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Create: slot=${instruction.block.slot} mint=${mint.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    context.TokenMetadataAccount.set({
      id: metadataPda,
      mint,
      updateAuthority,
      lastUpdatedSlot: instruction.block.slot,
      updateCount: 0,
      createdAtSlot: instruction.block.slot,
      lastTxSignature: txSig,
    });
    await bumpStats(context, "create");
  },
);

indexer.onInstruction(
  { program: "TokenMetadata", instruction: "UpdateMetadataAccountV2", fields: metaplexFields },
  async ({ instruction, context }) => {
    const { accountArguments } = instruction;
    const metadataPda = accountArguments[0];
    if (metadataPda === undefined) return;
    const updateAuthority = accountArguments[1];
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Update: slot=${instruction.block.slot} metadata=${metadataPda.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    const existing = await context.TokenMetadataAccount.get(metadataPda);
    if (existing) {
      context.TokenMetadataAccount.set({
        ...existing,
        updateAuthority,
        lastUpdatedSlot: instruction.block.slot,
        updateCount: existing.updateCount + 1,
        lastTxSignature: txSig,
      });
    } else {
      context.TokenMetadataAccount.set({
        id: metadataPda,
        mint: "",
        updateAuthority,
        lastUpdatedSlot: instruction.block.slot,
        updateCount: 1,
        createdAtSlot: instruction.block.slot,
        lastTxSignature: txSig,
      });
    }
    await bumpStats(context, "update");
  },
);
