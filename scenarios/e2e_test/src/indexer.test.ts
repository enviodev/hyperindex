import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer smoke test", () => {
  it(
    "processes the first block with events on chain 1",
    async (t) => {
      const indexer = createTestIndexer();

      const result = await indexer.process({ chains: { 1: {} } });

      t.expect(result.changes.length).toBeGreaterThan(0);

      const change = result.changes[0];
      t.expect(change).toEqual({
        block: expect.any(Number),
        blockHash: expect.any(String),
        chainId: 1,
        eventsProcessed: expect.any(Number),
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
