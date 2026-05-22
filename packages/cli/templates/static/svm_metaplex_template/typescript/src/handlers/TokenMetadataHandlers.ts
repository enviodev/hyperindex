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

indexer.onInstruction(
  { program: "TokenMetadata", instruction: "CreateMetadataAccountV3" },
  async ({ event, context }) => {
    const { accounts } = event.instruction;
    // Token Metadata's CreateMetadataAccountV3 instruction layout (Metaplex):
    //   0 = metadata account (PDA)
    //   1 = mint
    //   2 = mint authority
    //   3 = payer
    //   4 = update authority
    const metadataPda = accounts[0];
    if (metadataPda === undefined) return;
    const mint = accounts[1] ?? "";
    const updateAuthority = accounts[4];
    const txSig = event.transaction?.signatures[0];

    context.log.info(
      `Create: slot=${event.slot} mint=${mint.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    context.TokenMetadataAccount.set({
      id: metadataPda,
      mint,
      updateAuthority,
      lastUpdatedSlot: event.slot,
      updateCount: 0,
      createdAtSlot: event.slot,
      lastTxSignature: txSig,
    });
    await bumpStats(context, "create");
  },
);

indexer.onInstruction(
  { program: "TokenMetadata", instruction: "UpdateMetadataAccountV2" },
  async ({ event, context }) => {
    const { accounts } = event.instruction;
    const metadataPda = accounts[0];
    if (metadataPda === undefined) return;
    const updateAuthority = accounts[1];
    const txSig = event.transaction?.signatures[0];

    context.log.info(
      `Update: slot=${event.slot} metadata=${metadataPda.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    const existing = await context.TokenMetadataAccount.get(metadataPda);
    if (existing) {
      context.TokenMetadataAccount.set({
        ...existing,
        updateAuthority,
        lastUpdatedSlot: event.slot,
        updateCount: existing.updateCount + 1,
        lastTxSignature: txSig,
      });
    } else {
      context.TokenMetadataAccount.set({
        id: metadataPda,
        mint: "",
        updateAuthority,
        lastUpdatedSlot: event.slot,
        updateCount: 1,
        createdAtSlot: event.slot,
        lastTxSignature: txSig,
      });
    }
    await bumpStats(context, "update");
  },
);
