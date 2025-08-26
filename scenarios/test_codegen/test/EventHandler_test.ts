import assert from "assert";
import { it } from "mocha";
import { TestHelpers, User } from "generated";
const { MockDb, Gravatar, EventFiltersTest } = TestHelpers;

describe("Use Envio test framework to test event handlers", () => {
  it("Runs contract register handler", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "syncRegistration",
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1-${dcAddress}`,
        contract_name: "SimpleNft",
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

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1-${dcAddress}`,
        contract_name: "SimpleNft",
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

    const updatedMockDb = await mockDbInitial.processEvents([event]);
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

  it("entity.getOrCreate should create the entity if it doesn't exist", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrCreate - creates",
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const users = updatedMockDb.entities.User.getAll();
    assert.deepEqual(users, [
      {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      },
    ] satisfies typeof users);
  });

  it("entity.getOrCreate should load the entity if it exists", async () => {
    let mockDb = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrCreate - loads",
    });

    const existingUser: User = {
      id: "0",
      address: "existing",
      updatesCountOnUserForTesting: 0,
      gravatar_id: undefined,
      accountType: "USER",
    };
    mockDb = mockDb.entities.User.set(existingUser);

    mockDb = await mockDb.processEvents([event]);

    const users = mockDb.entities.User.getAll();
    assert.deepEqual(users, [existingUser] satisfies typeof users);
  });

  it("entity.getOrThrow should return existing entity", async () => {
    let mockDb = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrThrow",
    });

    const existingUser: User = {
      id: "0",
      address: "existing",
      updatesCountOnUserForTesting: 0,
      gravatar_id: undefined,
      accountType: "USER",
    };
    mockDb = mockDb.entities.User.set(existingUser);

    mockDb = await mockDb.processEvents([event]);

    const users = mockDb.entities.User.getAll();
    assert.deepEqual(users, [existingUser] satisfies typeof users);
  });

  it("entity.getOrThrow throws if entity doesn't exist", async () => {
    let mockDb = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrThrow",
    });

    await assert.rejects(
      mockDb.processEvents([event]),
      // It also logs to the console.
      {
        message: `Entity 'User' with ID '0' is expected to exist.`,
      }
    );
  });

  it("entity.getOrThrow throws if entity doesn't exist with custom message", async () => {
    let mockDb = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrThrow - custom message",
    });

    await assert.rejects(
      mockDb.processEvents([event]),
      // It also logs to the console.
      {
        message: `User should always exist`,
      }
    );
  });

  it("entity.getOrThrow - ignores the first fail in loader", async () => {
    let mockDb = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrThrow - ignores the first fail in loader",
    });

    await assert.rejects(
      mockDb.processEvents([event]),
      // It also logs to the console.
      {
        message: `Second loader failure should abort processing`,
      }
    );
  });

  it("entity.set should be ignored in unordered loader run", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "loaderSetCount",
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const users = updatedMockDb.entities.User.getAll();
    assert.deepEqual(users, [
      {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      },
    ] satisfies typeof users);
  });

  it("Process multiple events in batch", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event1 = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "processMultipleEvents - 1",
    });
    const event2 = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "processMultipleEvents - 2",
    });

    const updatedMockDb = await mockDbInitial.processEvents([event1, event2]);

    const d = updatedMockDb.entities.D.getAll();
    assert.deepEqual(d, [
      {
        id: "1",
        c: "1",
      },
      {
        id: "2",
        c: "2",
      },
    ] satisfies typeof d);
  });

  it("Throws when contract registered with invalid address", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const event = Gravatar.FactoryEvent.createMockEvent({
      testCase: "validatesAddress",
    });

    await assert.rejects(mockDbInitial.processEvents([event]), {
      message:
        'Address "invalid-address" is invalid. Expected a 20-byte hex string starting with 0x.',
    });
  });

  it("Checksums address when contract registered with valid address", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const eventAddress = "0x134";
    // Use a lowercase address that will be checksummed to proper format
    const inputAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
    const expectedChecksummedAddress =
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: inputAddress,
      testCase: "checksumsAddress",
      mockEventData: {
        srcAddress: eventAddress,
      },
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1-${expectedChecksummedAddress}`,
        contract_name: "SimpleNft",
        contract_address: expectedChecksummedAddress,
        chain_id: 1,
        registering_event_block_number: 0,
        registering_event_log_index: 0,
        registering_event_name: "FactoryEvent",
        registering_event_src_address: eventAddress,
        registering_event_block_timestamp: 0,
        registering_event_contract_name: "Gravatar",
      },
    ] satisfies typeof registeredDcs);
  });

  it("Should be able to run effect with cache", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const event = Gravatar.FactoryEvent.createMockEvent({
      testCase: "testEffectWithCache",
    });
    const event2 = Gravatar.FactoryEvent.createMockEvent({
      testCase: "testEffectWithCache2",
    });

    const _updatedMockDb = await mockDbInitial.processEvents([event, event2]);
  });

  it("Should throw when effect throws", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const event = Gravatar.FactoryEvent.createMockEvent({
      testCase: "throwingEffect",
    });

    await assert.rejects(mockDbInitial.processEvents([event]), {
      message: "Error from effect",
    });
  });

  it("Currently filters are ignored by the test framework", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const event = EventFiltersTest.FilterTestEvent.createMockEvent({
      addr: "0x000",
    });

    await assert.rejects(mockDbInitial.processEvents([event]), {
      message: "This should not be called",
    });
  });

  it("Can initialize the handlerWithLoader using wildcard", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const event = EventFiltersTest.WildcardHandlerWithLoader.createMockEvent(
      {}
    );

    const _updatedMockDb = await mockDbInitial.processEvents([event]);

    // Nothing to check here. There was a regression caused by Caml_option.some
    // So we just want to make sure that the handler is initialized correctly.
  });
});
