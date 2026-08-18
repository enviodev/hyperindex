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

// `params` is what the `idl:` entry in config.yaml buys: accounts arrive
// named instead of positional, and the instruction's Borsh args arrive
// decoded. It is absent only if the program has no IDL attached.
indexer.onInstruction(
  { program: "TokenMetadata", instruction: "CreateMetadataAccountV3" },
  async ({ instruction, context }) => {
    const params = instruction.params;
    if (params === undefined) return;
    const { metadata, mint, updateAuthority } = params.accounts;
    const { name, symbol, uri } = params.args.data;
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Create: slot=${instruction.block.slot} mint=${mint.slice(0, 8)}.. name=${name} tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

    context.TokenMetadataAccount.set({
      id: metadata,
      mint,
      updateAuthority,
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
  { program: "TokenMetadata", instruction: "UpdateMetadataAccountV2" },
  async ({ instruction, context }) => {
    const params = instruction.params;
    if (params === undefined) return;
    const { metadata } = params.accounts;
    // Every arg of this instruction is optional: the program only writes the
    // ones that are present.
    const { data, newUpdateAuthority } = params.args;
    const txSig = instruction.transaction.signature;

    context.log.info(
      `Update: slot=${instruction.block.slot} metadata=${metadata.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
    );

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
      lastTxSignature: txSig,
    });
    await bumpStats(context, "update");
  },
);
