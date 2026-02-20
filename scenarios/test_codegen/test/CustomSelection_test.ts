import { expectType, type TypeEqual } from "ts-expect";
import assert from "assert";
import { it } from "mocha";
import { TestHelpers } from "generated";
const { MockDb, Gravatar } = TestHelpers;

// The same as for ReScript but in TS
it("Handles event with a custom field selection (in TS)", async () => {
  // Initializing the mock database
  const mockDbInitial = MockDb.createMockDb();

  let hash = "0xabc123def456789012345678901234567890abcd";

  const event = Gravatar.CustomSelection.createMockEvent({
    mockEventData: {
      transaction: {
        // Can pass transactionIndex event though it's not selected for the event
        transactionIndex: 12,
        hash: hash,
        to: undefined,
        from: "0xfoo",
      },
      block: {
        parentHash: "0xParentHash",
      },
    },
  });

  expectType<
    TypeEqual<
      typeof event.transaction,
      {
        readonly to: `0x${string}` | undefined;
        readonly from: `0x${string}` | undefined;
        readonly hash: string;
      }
    >
  >(true);
  expectType<
    TypeEqual<
      typeof event.block,
      {
        readonly number: number;
        readonly timestamp: number;
        readonly hash: string;
        readonly parentHash: string;
      }
    >
  >(true);

  // The event not used for the test, but we want to make sure
  // that events without custom field selection use the global one
  const anotherEvent = Gravatar.EmptyEvent.createMockEvent({});
  expectType<
    TypeEqual<
      typeof anotherEvent.transaction,
      { readonly transactionIndex: number; readonly hash: string }
    >
  >(true);
  expectType<
    TypeEqual<
      typeof anotherEvent.block,
      {
        readonly number: number;
        readonly timestamp: number;
        readonly hash: string;
      }
    >
  >(true);

  const updatedMockDb = await Gravatar.CustomSelection.processEvent({
    event: event,
    mockDb: mockDbInitial,
  });

  assert.notEqual(
    updatedMockDb.entities.CustomSelectionTestPass.get(hash),
    undefined
  );
});
