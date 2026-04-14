import { describe, it, expect } from "vitest";
import { createTestIndexer, indexer } from "generated";

// Minimum coverage for the SVM `indexer.onSlot` API. We rely on the typed
// `indexer` shape from `generated` to assert:
//   1. `indexer.onSlot` is the registered method on SVM (the access itself
//      type-checks; calling out the runtime function shape catches a wiring
//      regression in `Main.res`).
//   2. `createTestIndexer()` reflects the SVM chain configured in
//      `config.yaml`.
// `indexer.onBlock` would be a TypeScript compile error on SVM and is
// therefore not asserted at runtime — the type system covers it.
describe("indexer.onSlot (SVM)", () => {
  it("exposes onSlot on the indexer", () => {
    expect(typeof indexer.onSlot).toBe("function");
  });

  it("creates a test indexer with the SVM chain configured", () => {
    const testIndexer = createTestIndexer();
    expect(testIndexer.chainIds).toEqual([0]);
    expect(testIndexer.chains[0].id).toBe(0);
  });
});
