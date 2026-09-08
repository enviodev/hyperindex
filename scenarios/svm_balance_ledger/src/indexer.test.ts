// Live E2E test against solana.hypersync.xyz. Drives the SVM stack end-to-end:
// SvmHyperSyncSource -> Rust-side routing -> indexer.onInstruction dispatch ->
// entity writes. START_SLOT and END_SLOT pin the window config.yaml leaves open.
process.env.START_SLOT = "420650000";
process.env.END_SLOT = "420650029";

import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const START_SLOT = Number(process.env.START_SLOT);
const END_SLOT = Number(process.env.END_SLOT);

// Last write wins, so the collected rows are the state the window ended in.
const collect = (changes: readonly unknown[], entity: string): Map<string, any> => {
  const rows = new Map<string, any>();
  for (const change of changes) {
    const sets = (change as any)[entity]?.sets;
    if (sets) for (const row of sets) rows.set(row.id, row);
  }
  return rows;
};

describe("Balance ledger indexer (live)", () => {
  it(
    "reconstructs token balances from transaction deltas with no gaps",
    async () => {
      const indexer = createTestIndexer();
      // Without an explicit endBlock `process` auto-exits at the first slot
      // carrying events, which would leave most of the pinned window unread.
      const result = await indexer.process({ chains: { 7565164: { endBlock: END_SLOT } } });

      const changes = [...collect(result.changes, "BalanceChange").values()];
      const accounts = [...collect(result.changes, "TokenAccount").values()];
      const flows = [...collect(result.changes, "TxMintFlow").values()];
      const stats = collect(result.changes, "LedgerStats").get("global");

      const latestByAccount = new Map<string, any>();
      for (const change of changes) {
        const seen = latestByAccount.get(change.account);
        if (
          !seen ||
          change.slot > seen.slot ||
          (change.slot === seen.slot && change.txIndex > seen.txIndex)
        ) {
          latestByAccount.set(change.account, change);
        }
      }

      // The fold the handler no longer does: a transaction conserves only if
      // every token instruction it carried conserves. This is the same
      // derivation sql/clickhouse.sql expresses as a join.
      const nonConservingTxs = new Set(
        [...collect(result.changes, "TxTokenInstruction").values()]
          .filter((i) => !i.conserves)
          .map((i) => i.txSig),
      );
      const conserving = flows.filter((f) => !nonConservingTxs.has(f.txSig));

      expect({
        startSlot: START_SLOT,
        endSlot: END_SLOT,
        // Floors, not exact counts: the window is fixed, but what a HyperSync
        // response carries for it can shift. As of writing it reconstructs
        // 22,629 changes across 10,083 accounts and 741 mints.
        producedChanges: changes.length > 10_000,
        producedAccounts: accounts.length > 5_000,
        producedFlows: flows.length > 0,
        // The continuity check only means something for an account seen more
        // than once in the window; the busiest here is seen 191 times.
        hasRepeatedAccounts: accounts.filter((a) => a.changeCount >= 2).length > 500,
        deltasAreSigned: changes.every((c) => c.delta === c.postAmount - c.preAmount),
        // Every non-opening change's incoming balance matched what the ledger
        // carried forward: nothing that moves a token account's amount escaped
        // the matched instruction set.
        allContinuous: changes.every((c) => c.continuous),
        noGapsRecorded: accounts.every((a) => a.gapCount === 0),
        statsAgreeWithRows: stats.changes === BigInt(changes.length) && stats.gaps === 0n,
        // The reconstruction equals what the chain itself reported last.
        balancesMatchChain: accounts.every(
          (a) => a.balance === latestByAccount.get(a.id)?.postAmount,
        ),
        // Transfer-only transactions move tokens between accounts without
        // changing how many exist.
        hasConservingFlows: conserving.length > 0,
        transfersConserve: conserving.every((f) => f.sumDelta === 0n),
      }).toEqual({
        startSlot: START_SLOT,
        endSlot: END_SLOT,
        producedChanges: true,
        producedAccounts: true,
        producedFlows: true,
        hasRepeatedAccounts: true,
        deltasAreSigned: true,
        allContinuous: true,
        noGapsRecorded: true,
        statsAgreeWithRows: true,
        balancesMatchChain: true,
        hasConservingFlows: true,
        transfersConserve: true,
      });
    },
    300_000,
  );
});
