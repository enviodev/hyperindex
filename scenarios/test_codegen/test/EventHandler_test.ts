import assert from "assert";
import { it } from "mocha";
import { TestHelpers } from "generated";
const { MockDb, Gravatar } = TestHelpers;

describe("Use Envio test framework to test event handlers", () => {
  it("Runs contract register handler", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
    });

    const updatedMockDb = await Gravatar.FactoryEvent.processEvent({
      event: event,
      mockDb: mockDbInitial,
    });

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1-${dcAddress}`,
        contract_type: "SimpleNft",
        contract_address: dcAddress,
        chain_id: 1,
        registering_event_block_number: 0,
        registering_event_log_index: 0,
        registering_event_name: "FactoryEvent",
        registering_event_src_address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`,
        registering_event_block_timestamp: 0,
        registering_event_contract_name: "Gravatar",
      },
    ] satisfies typeof registeredDcs);
  });
});
