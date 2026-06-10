// Live E2E test against solana.hypersync.xyz. Drives the SVM stack end-to-end:
// HyperSyncSolanaSource -> EventRouter -> indexer.onInstruction dispatch ->
// entity writes. The slot window is pinned in config.test.yaml.
process.env.ENVIO_CONFIG = "config.test.yaml";

import { describe, it, expect } from "vitest";
import { createTestIndexer } from "envio";

const START_SLOT = 420_650_000;
const END_SLOT = 420_650_008;

describe("Flow X-Ray indexer (live)", () => {
  it(
    "indexes a multi-protocol CPI window into flat flow rows",
    async () => {
      const indexer = createTestIndexer();
      const result = await indexer.process({ chains: { 0: {} } });

      const nodes: any[] = [];
      const deltas: any[] = [];
      const txs: any[] = [];
      for (const change of result.changes) {
        const n = (change as any).InstructionNode;
        if (n?.sets) nodes.push(...n.sets);
        const d = (change as any).TokenDelta;
        if (d?.sets) deltas.push(...d.sets);
        const t = (change as any).FlowTx;
        if (t?.sets) txs.push(...t.sets);
      }

      const programs = new Set(nodes.map((n) => n.program));
      const summary = {
        startSlot: START_SLOT,
        endSlot: END_SLOT,
        producedNodes: nodes.length > 0,
        producedTokenDeltas: deltas.length > 0,
        producedFlowTxs: txs.length > 0,
        multipleProtocols: programs.size >= 2,
        capturedCpiNesting: nodes.some((n) => n.parentPath != null || n.isInner === true),
        deltasAreSigned: deltas.every((d) => d.delta === d.postAmount - d.preAmount),
      };

      expect(summary).toEqual({
        startSlot: START_SLOT,
        endSlot: END_SLOT,
        producedNodes: true,
        producedTokenDeltas: true,
        producedFlowTxs: true,
        multipleProtocols: true,
        capturedCpiNesting: true,
        deltasAreSigned: true,
      });
    },
    300_000,
  );
});
