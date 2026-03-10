import assert from "assert";
import { it } from "vitest";
import { TestHelpers } from "generated";
const { MockDb, Gravatar } = TestHelpers;

// With the new static types, all events use the same EvmBlock and EvmTransaction types.
// Runtime proxies validate field access based on field_selection in config.yaml.
it("Handles event with a custom field selection (in TS)", async () => {
  // Initializing the mock database
  const mockDbInitial = MockDb.createMockDb();

  // Every time use different hash to make sure the test data isn't stale
  let hash = "0x" + Math.random() * 10 ** 18;

  const event = Gravatar.CustomSelection.createMockEvent({
    mockEventData: {
      transaction: {
        // Can pass transactionIndex event though it's not selected for the event
        transactionIndex: 12,
        hash: hash,
        from: "0xfoo",
      },
      block: {
        parentHash: "0xParentHash",
      },
    },
  });

  const updatedMockDb = await Gravatar.CustomSelection.processEvent({
    event: event,
    mockDb: mockDbInitial,
  });

  assert.notEqual(
    updatedMockDb.entities.CustomSelectionTestPass.get(hash),
    undefined
  );
});
