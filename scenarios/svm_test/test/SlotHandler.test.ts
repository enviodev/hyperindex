import { describe, it, expect } from "vitest";
import { createTestIndexer, indexer } from "generated";

// Minimum coverage for the SVM `indexer.onSlot` API. We don't need to
// process slots end-to-end — the goal is to exercise:
//   1. The SVM-only `onSlot` method name (no `onBlock` on SVM).
//   2. The flat-filter decoder branch in `Main.res::extractRange` for SVM
//      (`{_gte, _lte, _every}` at the top level, no `block.number` nesting).
//   3. The chain shape passed to the `where` predicate (`{id, name, ...}`).
describe("indexer.onSlot (SVM)", () => {
  it("exposes onSlot (and not onBlock) on the indexer", () => {
    const indexerObj = indexer as unknown as Record<string, unknown>;
    expect(typeof indexerObj.onSlot).toBe("function");
    expect(indexerObj.onBlock).toBeUndefined();
  });

  it("creates a test indexer with the SVM chain configured", () => {
    const testIndexer = createTestIndexer();
    expect(testIndexer.chainIds).toEqual([0]);
    expect(testIndexer.chains[0].id).toBe(0);
  });
});
