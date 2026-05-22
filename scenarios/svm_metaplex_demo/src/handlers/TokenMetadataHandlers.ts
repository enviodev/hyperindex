import { indexer, type TokenMetadataAccount, type ProgramStats } from "envio";

const STATS_ID = "metaplex-token-metadata";

// Shapes of the Borsh-decoded args we expect. Until the typed-args codegen
// lands (Stage 7b chunk 4), `event.instruction.decoded.args` is `unknown`
// and we narrow with these.
type DataV2 = {
  name: string;
  symbol: string;
  uri: string;
  seller_fee_basis_points: number;
  creators: Array<{ address: string; verified: boolean; share: number }> | null;
};
type CreateMetadataAccountV3Args = {
  data: DataV2;
  is_mutable: boolean;
};
type UpdateMetadataAccountV2Args = {
  data: DataV2 | null;
  update_authority: string | null;
};

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
  async ({ event, context }) => {
    const decoded = event.instruction.decoded;
    if (!decoded) {
      // Bundled Metaplex schema should always match disc 0x21 — surface
      // mismatches loudly so the upstream decoder regression is obvious.
      console.warn("CreateMetadataAccountV3: no decoded payload");
      return;
    }
    const args = decoded.args as CreateMetadataAccountV3Args;
    const metadataPda = decoded.accounts.metadata;
    if (metadataPda === undefined) return;
    const mint = decoded.accounts.mint ?? "";
    const updateAuthority = decoded.accounts.update_authority;
    const txSig = event.transaction?.signatures[0];

    console.log(
      `[Create] slot=${event.slot} name='${args.data.name}' symbol='${args.data.symbol}' mint=${mint.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
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
    const decoded = event.instruction.decoded;
    if (!decoded) {
      console.warn("UpdateMetadataAccountV2: no decoded payload");
      return;
    }
    const args = decoded.args as UpdateMetadataAccountV2Args;
    const metadataPda = decoded.accounts.metadata;
    if (metadataPda === undefined) return;
    const updateAuthority = args.update_authority ?? decoded.accounts.update_authority;
    const txSig = event.transaction?.signatures[0];

    console.log(
      `[Update] slot=${event.slot} metadata=${metadataPda.slice(0, 8)}.. tx=${(txSig ?? "?").slice(0, 8)}..`,
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
      // Metadata account existed before our `start_block`; record the update
      // without claiming a `mint` or `createdAtSlot` we don't actually know.
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
