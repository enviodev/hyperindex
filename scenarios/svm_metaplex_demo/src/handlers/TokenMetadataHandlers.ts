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

indexer.onInstruction(
  { program: "TokenMetadata", instruction: "CreateMetadataAccountV3" },
  async ({ instruction, context }) => {
    const params = instruction.params;
    if (!params) {
      // The IDL covers discriminator 0x21, so a miss means the on-chain layout
      // drifted from the checked-in IDL. Surface it rather than write a
      // half-decoded row.
      context.log.warn("CreateMetadataAccountV3: instruction did not match the IDL");
      return;
    }
    const { args, accounts } = params;
    const metadataPda = accounts.metadata;
    const mint = accounts.mint;
    const updateAuthority = accounts.updateAuthority;
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Create: slot=${instruction.block.slot} name='${args.data.name}' symbol='${args.data.symbol}' mint=${mint.slice(0, 8)}..`,
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
  { program: "TokenMetadata", instruction: "UpdateMetadataAccountV2" },
  async ({ instruction, context }) => {
    const params = instruction.params;
    if (!params) {
      context.log.warn("UpdateMetadataAccountV2: instruction did not match the IDL");
      return;
    }
    const { args, accounts } = params;
    const metadataPda = accounts.metadata;
    // The instruction can reassign the update authority; when it doesn't, the
    // signing authority is still the current one.
    const updateAuthority = args.newUpdateAuthority ?? accounts.updateAuthority;
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Update: slot=${instruction.block.slot} metadata=${metadataPda.slice(0, 8)}..`,
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
