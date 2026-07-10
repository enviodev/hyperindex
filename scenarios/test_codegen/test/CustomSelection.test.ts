import { expectType, type TypeEqual } from "ts-expect";
import assert from "assert";
import { it } from "vitest";
import { createTestIndexer, type EvmEvent } from "envio";

type CustomSelectionEvent = EvmEvent<"Gravatar", "CustomSelection">;
type EmptyEventEvent = EvmEvent<"Gravatar", "EmptyEvent">;

// Unselected fields are typed as the branded `FieldNotSelected<...>` (not `never`)
// so reading them is a type error instead of silently passing as `never`.
type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

// Compile-time type assertions for custom field selection
// CustomSelection event has custom block_fields: [parentHash]
// Default fields (number, timestamp, hash) are always included
expectType<TypeEqual<CustomSelectionEvent["block"]["number"], number>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["timestamp"], number>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["hash"], string>>(true);
expectType<TypeEqual<CustomSelectionEvent["block"]["parentHash"], string>>(true);
// Unselected block fields are not selected
expectType<IsNotSelected<CustomSelectionEvent["block"]["nonce"]>>(true);
expectType<IsNotSelected<CustomSelectionEvent["block"]["gasUsed"]>>(true);

// CustomSelection event has custom transaction_fields: [to, from, hash]
expectType<TypeEqual<CustomSelectionEvent["transaction"]["to"], `0x${string}` | undefined>>(true);
expectType<TypeEqual<CustomSelectionEvent["transaction"]["from"], `0x${string}` | undefined>>(true);
expectType<TypeEqual<CustomSelectionEvent["transaction"]["hash"], string>>(true);
// Unselected transaction fields are not selected
expectType<IsNotSelected<CustomSelectionEvent["transaction"]["transactionIndex"]>>(true);
expectType<IsNotSelected<CustomSelectionEvent["transaction"]["gas"]>>(true);

// Events without custom field selection should use the global one
// Global has transactionIndex + hash
expectType<TypeEqual<EmptyEventEvent["transaction"]["transactionIndex"], number>>(true);
expectType<TypeEqual<EmptyEventEvent["transaction"]["hash"], string>>(true);
// Fields not in global selection are not selected
expectType<IsNotSelected<EmptyEventEvent["transaction"]["from"]>>(true);
expectType<IsNotSelected<EmptyEventEvent["transaction"]["to"]>>(true);

// Global block has defaults only (number, timestamp, hash)
expectType<TypeEqual<EmptyEventEvent["block"]["number"], number>>(true);
expectType<TypeEqual<EmptyEventEvent["block"]["timestamp"], number>>(true);
expectType<TypeEqual<EmptyEventEvent["block"]["hash"], string>>(true);
// parentHash not in global selection — not selected
expectType<IsNotSelected<EmptyEventEvent["block"]["parentHash"]>>(true);

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
