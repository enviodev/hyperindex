import { expectType, type TypeEqual } from "ts-expect";
import assert from "assert";
import { it } from "vitest";
import { createTestIndexer } from "generated";
import type {
  Gravatar_CustomSelection_transaction,
  Gravatar_CustomSelection_block,
  Gravatar_EmptyEvent_transaction,
  Gravatar_EmptyEvent_block,
} from "generated/src/Indexer.gen";

// Compile-time type assertions for custom field selection
expectType<
  TypeEqual<
    Gravatar_CustomSelection_transaction,
    {
      readonly to: `0x${string}` | undefined;
      readonly from: `0x${string}` | undefined;
      readonly hash: string;
    }
  >
>(true);
expectType<
  TypeEqual<
    Gravatar_CustomSelection_block,
    {
      readonly number: number;
      readonly timestamp: number;
      readonly hash: string;
      readonly parentHash: string;
    }
  >
>(true);

// Events without custom field selection should use the global one
expectType<
  TypeEqual<
    Gravatar_EmptyEvent_transaction,
    { readonly transactionIndex: number; readonly hash: string }
  >
>(true);
expectType<
  TypeEqual<
    Gravatar_EmptyEvent_block,
    {
      readonly number: number;
      readonly timestamp: number;
      readonly hash: string;
    }
  >
>(true);

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
