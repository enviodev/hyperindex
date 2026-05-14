import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const simulatePayload = (n: number) => ({
  chains: {
    1337: {
      startBlock: 1,
      endBlock: 100,
      simulate: [
        {
          contract: "Gravatar" as const,
          event: "FactoryEvent" as const,
          params: {
            contract: "0x1234567890123456789012345678901234567890" as const,
            testCase: `testEffectWithCache${n === 0 ? "" : "2"}` as const,
          },
        },
      ],
    },
  },
});

describe("profile createTestIndexer simulate", () => {
  it("times createTestIndexer + process across fresh indexers", async () => {
    // Pre-import is paid before t0
    const N = 4;
    for (let i = 0; i < N; i++) {
      const t0 = performance.now();
      const indexer = createTestIndexer();
      const t1 = performance.now();
      await indexer.process(simulatePayload(i % 2));
      const t2 = performance.now();
      console.log(
        `PROFILE iter ${i}: createTestIndexer=${(t1 - t0).toFixed(1)}ms ` +
          `process=${(t2 - t1).toFixed(1)}ms total=${(t2 - t0).toFixed(1)}ms`,
      );
    }
  }, 60_000);
});
