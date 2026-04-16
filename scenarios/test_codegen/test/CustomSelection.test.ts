import { expectType, type TypeEqual } from "ts-expect";
import assert from "assert";
import { it } from "vitest";
import { createTestIndexer, type EvmEvent } from "generated";

type CustomSelectionEvent = EvmEvent<"Gravatar", "CustomSelection">;
type EmptyEventEvent = EvmEvent<"Gravatar", "EmptyEvent">;

// Compile-time type assertions for custom field selection
// CustomSelection event has custom block_fields: [parentHash]
// Default fields (number, timestamp, hash) are always included
expectType<TypeEqual<CustomSelectionEvent["block"]["number"], number>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["timestamp"], number>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["hash"], string>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["parentHash"], string>>(true);
// Unselected block fields are never
expectType<TypeEqual<CustomSelectionEvent["block"]["nonce"], never>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["gasUsed"], never>>(true);

// CustomSelection event has custom transaction_fields: [to, from, hash]
expectType<TypeEqual<CustomSelectionEvent["transaction"]["to"], `0x${string}` | undefined>>(true);
expectType<TypeEqual<CustomSelectionEvent["transaction"]["from"], `0x${string}` | undefined>>(true);
expectType<TypeEqual<CustomSelectionEvent["transaction"]["hash"], string>>(true);
// Unselected transaction fields are never
expectType<TypeEqual<CustomSelectionEvent["transaction"]["transactionIndex"], never>>(true);
expectType<TypeEqual<CustomSelectionEvent["transaction"]["gas"], never>>(true);

// Events without custom field selection should use the global one
// Global has transactionIndex + hash
expectType<TypeEqual<EmptyEventEvent["transaction"]["transactionIndex"], number>>(true);
expectType<TypeEqual<EmptyEventEvent["transaction"]["hash"], string>>(true);
// Fields not in global selection are never
expectType<TypeEqual<EmptyEventEvent["transaction"]["from"], never>>(true);
expectType<TypeEqual<EmptyEventEvent["transaction"]["to"], never>>(true);

// Global block has defaults only (number, timestamp, hash)
expectType<TypeEqual<EmptyEventEvent["block"]["number"], number>>(true);
expectType<TypeEqual<EmptyEventEvent["block"]["timestamp"], number>>(true);
expectType<TypeEqual<EmptyEventEvent["block"]["hash"], string>>(true);
// parentHash not in global selection — never
expectType<TypeEqual<EmptyEventEvent["block"]["parentHash"], never>>(true);

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
