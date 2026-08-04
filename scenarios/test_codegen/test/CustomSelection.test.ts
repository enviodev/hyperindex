import assert from "assert";
import { it } from "vitest";
import { createTestIndexer } from "envio";

it("Handles event with a custom field selection (in TS)", async () => {
  const indexer = createTestIndexer();

  const result = await indexer.process({
    chains: {
      1337: {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            contract: "Gravatar",
            event: "CustomSelection",
            transaction: {
              from: "0xfoo",
            },
            block: {
              parentHash: "0xParentHash",
            },
          },
        ],
      },
    },
  });

  assert.equal(result.changes.length, 1);
});
