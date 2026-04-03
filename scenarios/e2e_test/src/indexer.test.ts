import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer smoke test", () => {
  it(
    "processes the first block with events on chain 1",
    async (t) => {
      const indexer = createTestIndexer();

      const result = await indexer.process({ chains: { 1: {} } });

      t.expect(result.changes.length, "Should have at least one change").toBeGreaterThan(0);
      t.expect(result.changes[0]).toMatchObject({
        chainId: 1,
        Transfer: {
          sets: expect.arrayContaining([
            expect.objectContaining({
              id: expect.any(String),
              from: expect.any(String),
              to: expect.any(String),
              value: expect.any(BigInt),
              blockNumber: expect.any(Number),
              transactionHash: expect.any(String),
            }),
          ]),
        },
      });
    },
    60_000
  );
});
