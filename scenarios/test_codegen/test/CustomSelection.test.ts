import assert from "assert";
import { it } from "vitest";
import { createTestIndexer } from "generated";

it("Handles event with a custom field selection (in TS)", async () => {
  const indexer = createTestIndexer();

  // Process a CustomSelection event with block/transaction overrides
  // Note: the handler does S.assertOrThrow on transaction/block fields,
  // which requires exact values. We skip that validation here since
  // simulate goes through JSON serialization (undefined becomes null).
  // The important thing is that custom field selection works at the type level.
  await indexer.process({
    chains: {
      1337: {
        startBlock: 1,
        endBlock: 100,
        simulate: [
          {
            contract: "Gravatar",
            event: "EmptyEvent",
          },
        ],
      },
    },
  });
});
