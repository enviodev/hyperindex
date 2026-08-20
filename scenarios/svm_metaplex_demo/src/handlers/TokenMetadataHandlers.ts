import { indexer, type TokenMetadataAccount, type ProgramStats } from "envio";

const STATS_ID = "metaplex-token-metadata";

async function bumpStats(
  context: { ProgramStats: { get: (id: string) => Promise<ProgramStats | undefined>; set: (e: ProgramStats) => void } },
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
  instruction: ["args", "accounts"],
  transaction: ["signature"],
  block: ["time"],
} as const;

indexer.onInstruction(
  { program: "TokenMetadata", instruction: "CreateMetadataAccountV3", fields: metaplexFields },
  async ({ instruction, context }) => {
    const args = instruction.args;
    if (!args) {
      console.warn("CreateMetadataAccountV3: no decoded payload");
      return;
    }
    const metadataPda = instruction.accounts.metadata.address;
    const mint = instruction.accounts.mint.address;
    const updateAuthority = instruction.accounts.update_authority.address;
    const txSig = instruction.transaction.signature;

    console.log(
      `[Create] slot=${instruction.block.slot} name='${args.data.name}' symbol='${args.data.symbol}' mint=${mint.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    context.TokenMetadataAccount.set({
      id: metadataPda,
      mint,
      updateAuthority,
      lastUpdatedSlot: instruction.block.slot,
      lastUpdatedTime: instruction.block.time,
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
    const args = instruction.args;
    if (!args) {
      console.warn("UpdateMetadataAccountV2: no decoded payload");
      return;
    }
    const metadataPda = instruction.accounts.metadata.address;
    const updateAuthority = args.update_authority ?? instruction.accounts.update_authority.address;
    const txSig = instruction.transaction.signature;

    console.log(
      `[Update] slot=${instruction.block.slot} metadata=${metadataPda.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    const existing = await context.TokenMetadataAccount.get(metadataPda);
    if (existing) {
      context.TokenMetadataAccount.set({
        ...existing,
        updateAuthority,
        lastUpdatedSlot: instruction.block.slot,
        lastUpdatedTime: instruction.block.time,
        updateCount: existing.updateCount + 1,
        lastTxSignature: txSig,
      });
    } else {
      // Metadata account existed before our `start_block`; record the update
      // without claiming a `mint` or `createdAtSlot` we don't actually know.
      context.TokenMetadataAccount.set({
        id: metadataPda,
        mint: "",
        updateAuthority,
        lastUpdatedSlot: instruction.block.slot,
        lastUpdatedTime: instruction.block.time,
        updateCount: 1,
        createdAtSlot: instruction.block.slot,
        lastTxSignature: txSig,
      });
    }
    await bumpStats(context, "update");
  },
);
