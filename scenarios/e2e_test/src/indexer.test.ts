import { describe, it, expect } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer smoke test", () => {
  it(
    "processes the first block with events on chain 1",
    async (t) => {
      const indexer = createTestIndexer();

      const result = await indexer.process({ chains: { 1: {} } });

      console.log(result);
      t.expect(result).toMatchInlineSnapshot();
    },
    60_000
  );
});
