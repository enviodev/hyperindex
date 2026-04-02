import { describe, it } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer smoke test", () => {
  it(
    "processes the first block with events on chain 1",
    async (t) => {
      const indexer = createTestIndexer();

      t.expect(
        await indexer.process({ chains: { 1: {} } }),
        "Should find the first block with an event on chain 1 and process it."
      ).toMatchInlineSnapshot(``);
    },
    30_000
  );
});
