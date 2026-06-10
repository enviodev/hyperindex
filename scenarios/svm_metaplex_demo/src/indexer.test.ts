// Live E2E test against `solana.hypersync.xyz`. Drives the SVM stack
// end-to-end: HyperSyncSolanaSource → EventRouter → `indexer.onInstruction`
// dispatch → entity writes. `config.yaml` interpolates `ENVIO_METAPLEX_END_BLOCK`
// into `end_block` to pin a finite window here; the live demo leaves it unset
// for continuous tailing.
//
// If this test starts failing for "no instructions returned", first verify
// the window is still served by HyperSync:
//   curl -s -X POST https://solana.hypersync.xyz/query/arrow \
//     -H 'content-type: application/json' \
//     -d '{"from_slot":417950000,"to_slot":417950500,"instructions":[{"program_id":["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"]}]}' \
//   | wc -c
// A non-trivial byte count means the window is still indexed.
const START_SLOT = 417_950_000;
const END_SLOT = 417_950_500;

// Must be set before importing `envio`: config is loaded and interpolated on use.
process.env.ENVIO_METAPLEX_END_BLOCK = String(END_SLOT);

import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM Metaplex indexer (live)", () => {
  it(
    "indexes Token Metadata instructions for a pinned window",
    async () => {
      const indexer = createTestIndexer();
      const result = await indexer.process({ chains: { 0: {} } });

      // Collect every write across the per-batch checkpoints flushed during
      // the run. Shape:
      // `result.changes = [{ TokenMetadataAccount: {sets: [...]}, ... }, ...]`
      const tokenChanges: any[] = [];
      const statsChanges: any[] = [];
      let totalInstructionsAcrossBatches = 0;
      for (const change of result.changes) {
        const tma = (change as any).TokenMetadataAccount;
        if (tma?.sets) tokenChanges.push(...tma.sets);
        const ps = (change as any).ProgramStats;
        if (ps?.sets) statsChanges.push(...ps.sets);
        totalInstructionsAcrossBatches += (change as any).eventsProcessed ?? 0;
      }
      const finalStats = statsChanges[statsChanges.length - 1];

      // One shape assertion. The numbers themselves can drift if the
      // archived window's contents change — the *shape* of the result
      // (real Metaplex activity, both instruction kinds firing, counter
      // consistency) is what we're locking in.
      const summary = {
        startSlot: START_SLOT,
        endSlot: END_SLOT,
        producedTokenAccounts: tokenChanges.length > 0,
        producedStatsRow: finalStats !== undefined,
        finalStatsHasCreates: (finalStats?.createCount ?? 0) > 0,
        totalsMatchHandlerInvocations:
          (finalStats?.totalInstructions ?? 0) ===
          (finalStats?.createCount ?? 0) + (finalStats?.updateCount ?? 0),
        anyInstructionsProcessed: totalInstructionsAcrossBatches > 0,
      };

      expect(summary).toEqual({
        startSlot: START_SLOT,
        endSlot: END_SLOT,
        producedTokenAccounts: true,
        producedStatsRow: true,
        finalStatsHasCreates: true,
        totalsMatchHandlerInvocations: true,
        anyInstructionsProcessed: true,
      });
    },
    120_000,
  );
});
