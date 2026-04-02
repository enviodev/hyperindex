import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// Block range near the config start_block — ERC20 mints and burns occur on every block
const START_BLOCK = 22000000;
const END_BLOCK = 22000100;

describe("Topic Filter Indexer", () => {
  it("indexes mint events (Transfer from zero address)", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: { startBlock: START_BLOCK, endBlock: END_BLOCK },
      },
    });

    const allTransfers = result.changes.flatMap((c) => c.Transfer?.sets ?? []);
    const mints = allTransfers.filter((t) => t.from === ZERO_ADDRESS);

    expect(mints.length, "Should have indexed at least one mint event").toBeGreaterThan(0);
    expect(mints[0]).toMatchObject({ from: ZERO_ADDRESS, chainId: 1 });
  });

  it("indexes burn events (Transfer to zero address)", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: { startBlock: START_BLOCK, endBlock: END_BLOCK },
      },
    });

    const allTransfers = result.changes.flatMap((c) => c.Transfer?.sets ?? []);
    const burns = allTransfers.filter((t) => t.to === ZERO_ADDRESS);

    expect(burns.length, "Should have indexed at least one burn event").toBeGreaterThan(0);
    expect(burns[0]).toMatchObject({ to: ZERO_ADDRESS, chainId: 1 });
  });

  it("does not index regular transfers (neither mint nor burn)", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: { startBlock: START_BLOCK, endBlock: END_BLOCK },
      },
    });

    const allTransfers = result.changes.flatMap((c) => c.Transfer?.sets ?? []);
    const regularTransfers = allTransfers.filter(
      (t) => t.from !== ZERO_ADDRESS && t.to !== ZERO_ADDRESS
    );

    expect(regularTransfers.length, "Regular transfers should not be indexed").toBe(0);
  });
});
