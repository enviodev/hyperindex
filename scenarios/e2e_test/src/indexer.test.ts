// The handler asserts indexer.chains[1].endBlock matches this env var.
// In the smoke test no DB state is loaded, so the config endBlock applies.
process.env.E2E_EXPECTED_END_BLOCK = "10861774";

import { describe, it } from "vitest";
import { createTestIndexer } from "generated";

describe("Indexer smoke test", () => {
  it(
    "processes the first block with events on chain 1",
    async (t) => {
      const indexer = createTestIndexer();

      const result = await indexer.process({ chains: { 1: {} } });

      t.expect(result).toMatchInlineSnapshot(`
        {
          "changes": [
            {
              "Transfer": {
                "sets": [
                  {
                    "blockNumber": 10861674,
                    "from": "0x0000000000000000000000000000000000000000",
                    "id": "1-10861674-23",
                    "to": "0x41653c7d61609D856f29355E404F310Ec4142Cfb",
                    "transactionHash": "0x4b37d2f343608457ca3322accdab2811c707acf3eb07a40dd8d9567093ea5b82",
                    "value": 1000000000000000000000000000n,
                  },
                ],
              },
              "block": 10861674,
              "chainId": 1,
              "eventsProcessed": 1,
            },
          ],
        }
      `);
    },
    60_000
  );
});
