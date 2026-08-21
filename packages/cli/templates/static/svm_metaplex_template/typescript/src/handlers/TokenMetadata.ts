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
      instruction: ["accounts"],
      transaction: ["signature"],
    },
  },
  async ({ instruction, context }) => {
    context.TokenMetadataAccount.set({
      id: instruction.accounts.metadata.address,
      mint: instruction.accounts.mint.address,
      updateAuthority: instruction.accounts.update_authority.address,
      lastUpdatedSlot: instruction.block.slot,
      updateCount: 0,
      createdAtSlot: instruction.block.slot,
      lastTxSignature: instruction.transaction.signature,
    });
    await bumpStats(context, "create");
  },
);

indexer.onInstruction(
  {
    program: "TokenMetadata",
    instruction: "UpdateMetadataAccountV2",
    fields: {
      instruction: ["accounts"],
      transaction: ["signature"],
    },
  },
  async ({ instruction, context }) => {
    const account = await context.TokenMetadataAccount.getOrCreate({
      id: instruction.accounts.metadata.address,
      mint: "",
      updateAuthority: instruction.accounts.update_authority.address,
      lastUpdatedSlot: instruction.block.slot,
      updateCount: 0,
      createdAtSlot: instruction.block.slot,
      lastTxSignature: instruction.transaction.signature,
    });
    context.TokenMetadataAccount.set({
      ...account,
      updateAuthority: instruction.accounts.update_authority.address,
      lastUpdatedSlot: instruction.block.slot,
      updateCount: account.updateCount + 1,
      lastTxSignature: instruction.transaction.signature,
    });
    await bumpStats(context, "update");
  },
);
