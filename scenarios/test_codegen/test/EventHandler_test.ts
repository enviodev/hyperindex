import assert from "assert";
import { it } from "mocha";
import { TestHelpers, User } from "generated";
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

  it("entity.getOrCreate should create the entity if it doesn't exist", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "getOrCreate - creates",
    });

    const updatedMockDb = await Gravatar.FactoryEvent.processEvent({
      event: event,
      mockDb: mockDbInitial,
    });

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

    mockDb = await Gravatar.FactoryEvent.processEvent({
      event: event,
      mockDb: mockDb,
    });

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

    mockDb = await Gravatar.FactoryEvent.processEvent({
      event: event,
      mockDb: mockDb,
    });

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
      Gravatar.FactoryEvent.processEvent({
        event: event,
        mockDb: mockDb,
      }),
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
      Gravatar.FactoryEvent.processEvent({
        event: event,
        mockDb: mockDb,
      }),
      // It also logs to the console.
      {
        message: `User should always exist`,
      }
    );
  });
});
