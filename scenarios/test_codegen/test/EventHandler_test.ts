import assert from "assert";
import { it } from "mocha";
import { TestHelpers } from "generated";
import { BigDecimal } from "generated";
const { MockDb, Gravatar } = TestHelpers;

describe("Use Envio test framework to test event handlers", () => {
  it("Runs contract register handler", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "syncRegistration",
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

  it("Runs contract register with async handler", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "asyncRegistration",
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

  it("Throws when contract registered in an unawaited macrotask", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "throwOnHangingRegistration",
    });

    const updatedMockDb = await Gravatar.FactoryEvent.processEvent({
      event: event,
      mockDb: mockDbInitial,
    });
    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(
      registeredDcs,
      [],
      `Since the error thrown in the separate macrotask,
      can't really break the flow here.
      So the contract register should finish successfully.`
    );

    // Currently no good way to test this:
    // But you should be able to see it the logs when running the test
    // assert.equal(
    //   log.message,
    //   "The context.addSimpleNft was called after the contract register resolved. Use await or return a promise from the contract register handler to avoid this error."
    // );
  });

  it("Runs handler for entity with all types set", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "entityWithAllTypesSet",
    });

    const updatedMockDb = await Gravatar.FactoryEvent.processEvent({
      event: event,
      mockDb: mockDbInitial,
    });

    const entities = updatedMockDb.entities.EntityWithAllTypes.getAll();
    const expectedEntity1 = {
      id: "1",
      string: "string",
      optString: "optString",
      arrayOfStrings: ["arrayOfStrings1", "arrayOfStrings2"],
      int_: 1,
      optInt: 2,
      arrayOfInts: [3, 4],
      float_: 1.1,
      optFloat: 2.2,
      arrayOfFloats: [3.3, 4.4],
      bool: true,
      optBool: false,
      bigInt: 1n,
      optBigInt: 2n,
      arrayOfBigInts: [3n, 4n],
      bigDecimal: new BigDecimal("1.1"),
      optBigDecimal: new BigDecimal("2.2"),
      arrayOfBigDecimals: [new BigDecimal("3.3"), new BigDecimal("4.4")],
      json: { foo: ["bar"] },
    };
    assert.deepEqual(entities, [
      expectedEntity1,
      {
        ...expectedEntity1,
        id: "2",
      },
    ] satisfies typeof entities);
  });
});
