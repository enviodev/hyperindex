import { describe, it } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer smoke test", () => {
  it(
    "processes the first block with events on chain 1",
    async (t) => {
      const indexer = createTestIndexer();

      const result = await indexer.process({ chains: { 1: {} } });

      console.log(JSON.stringify(result, (_, v) => (typeof v === "bigint" ? `${v}n` : v), 2));
      t.expect(result).toMatchInlineSnapshot();
    },
    60_000
  );
});
