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
  {
    program: "TokenMetadata",
    instruction: "CreateMetadataAccountV3",
    fields: {
      instruction: ["accounts", "args"],
      transaction: ["signature"],
    },
  },
  async ({ instruction, context }) => {
    const args = instruction.args;
    if (args === undefined) return;
    const { metadata, mint, updateAuthority } = instruction.accounts;
    const { name, symbol, uri } = args.data;
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Create: slot=${instruction.block.slot} mint=${mint.address.slice(0, 8)}.. name=${name} tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    context.TokenMetadataAccount.set({
      id: metadata.address,
      mint: mint.address,
      updateAuthority: updateAuthority.address,
      name,
      symbol,
      uri,
      lastUpdatedSlot: instruction.block.slot,
      updateCount: 0,
      createdAtSlot: instruction.block.slot,
      lastTxSignature: txSig,
    });
    await bumpStats(context, "create");
  },
);

indexer.onInstruction(
  {
    program: "TokenMetadata",
    instruction: "UpdateMetadataAccountV2",
    fields: {
      instruction: ["accounts", "args"],
      transaction: ["signature"],
    },
  },
  async ({ instruction, context }) => {
    const args = instruction.args;
    if (args === undefined) return;
    const metadata = instruction.accounts.metadata.address;
    const { data, newUpdateAuthority } = args;

    const existing = await context.TokenMetadataAccount.get(metadata);
    context.TokenMetadataAccount.set({
      id: metadata,
      mint: existing?.mint ?? "",
      updateAuthority: newUpdateAuthority ?? existing?.updateAuthority,
      name: data?.name ?? existing?.name,
      symbol: data?.symbol ?? existing?.symbol,
      uri: data?.uri ?? existing?.uri,
      lastUpdatedSlot: instruction.block.slot,
      updateCount: (existing?.updateCount ?? 0) + 1,
      createdAtSlot: existing?.createdAtSlot ?? instruction.block.slot,
      lastTxSignature: instruction.transaction.signature,
    });
    await bumpStats(context, "update");
  },
);
