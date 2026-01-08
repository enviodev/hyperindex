import assert from "assert";
import { it } from "mocha";
import {
  TestHelpers,
  indexer,
  type User,
  type Indexer,
  type EvmChainId,
  type EvmChainName,
  type FuelChainId,
  type SvmChainId,
} from "generated";
import { type Address } from "envio";
import { expectType, type TypeEqual } from "ts-expect";
import { createTestIndexer } from "generated";

const { MockDb, Gravatar, EventFiltersTest } = TestHelpers;

describe("Use Envio test framework to test event handlers", () => {
  it("Indexer types and value", () => {
    // Address type test
    expectType<TypeEqual<Address, `0x${string}`>>(true);

    // Indexer type tests
    expectType<TypeEqual<typeof indexer, Indexer>>(true);

    type ExpectedEvmContracts = {
      readonly NftFactory: {
        readonly name: "NftFactory";
        readonly abi: readonly unknown[];
        readonly addresses: readonly Address[];
      };
      readonly EventFiltersTest: {
        readonly name: "EventFiltersTest";
        readonly abi: readonly unknown[];
        readonly addresses: readonly Address[];
      };
      readonly SimpleNft: {
        readonly name: "SimpleNft";
        readonly abi: readonly unknown[];
        readonly addresses: readonly Address[];
      };
      readonly TestEvents: {
        readonly name: "TestEvents";
        readonly abi: readonly unknown[];
        readonly addresses: readonly Address[];
      };
      readonly Gravatar: {
        readonly name: "Gravatar";
        readonly abi: readonly unknown[];
        readonly addresses: readonly Address[];
      };
      readonly Noop: {
        readonly name: "Noop";
        readonly abi: readonly unknown[];
        readonly addresses: readonly Address[];
      };
    };

    // Chain types are internal, so we check through the indexer type
    expectType<
      TypeEqual<
        typeof indexer.chains,
        {
          readonly ethereumMainnet: {
            readonly id: 1;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
          readonly gnosis: {
            readonly id: 100;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
          readonly polygon: {
            readonly id: 137;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
          readonly "1337": {
            readonly id: 1337;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
        } & {
          readonly 1: {
            readonly id: 1;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
          readonly 100: {
            readonly id: 100;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
          readonly 137: {
            readonly id: 137;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
          readonly 1337: {
            readonly id: 1337;
            readonly startBlock: number;
            readonly endBlock: number | undefined;
            readonly name: string;
            readonly isLive: boolean;
          } & ExpectedEvmContracts;
        }
      >
    >(true);
    // Check that chain has the expected structure with name and isLive
    expectType<
      TypeEqual<
        typeof indexer.chains.ethereumMainnet,
        {
          readonly id: 1;
          readonly startBlock: number;
          readonly endBlock: number | undefined;
          readonly name: string;
          readonly isLive: boolean;
        } & ExpectedEvmContracts
      >
    >(true);

    const _chainId: EvmChainId = 1;

    // EvmChainId should be the union of configured chain IDs
    expectType<TypeEqual<EvmChainId, 1 | 1337 | 100 | 137>>(true);
    expectType<
      TypeEqual<EvmChainName, "ethereumMainnet" | "gnosis" | "polygon" | "1337">
    >(true);

    // Non-configured ecosystem types should return error strings
    expectType<
      TypeEqual<
        FuelChainId,
        "FuelChainId is not available. Configure Fuel chains in config.yaml and run 'pnpm envio codegen'"
      >
    >(true);
    expectType<
      TypeEqual<
        SvmChainId,
        "SvmChainId is not available. Configure SVM chains in config.yaml and run 'pnpm envio codegen'"
      >
    >(true);

    // Indexer value assertion
    assert.deepEqual(indexer.name, "test_codegen");
    assert.deepEqual(indexer.description, "Gravatar for Ethereum");
    assert.deepEqual(indexer.chainIds, [1, 100, 137, 1337]);
    assert.deepEqual(Object.keys(indexer.chains), [1, 100, 137, 1337]);
    assert.deepEqual(
      indexer.chains[1],
      indexer.chains.ethereumMainnet,
      "Chains by name are not enumerable, but should be accessible by name"
    );
    assert.deepEqual(indexer.chains[1].id, 1);
    assert.deepEqual(indexer.chains[1].startBlock, 1);
    assert.deepEqual(indexer.chains[1].endBlock, undefined);
    assert.deepEqual(indexer.chains[1].name, "ethereumMainnet");
    assert.deepEqual(indexer.chains[1].isLive, false);
    assert.deepEqual(indexer.chains[1].Noop.addresses, [
      "0x0b2F78c5Bf6d9c12EE1225d5f374Aa91204580C3",
    ]);
    assert.deepEqual(indexer.chains[1].Noop.name, "Noop");
    assert.deepEqual(Object.keys(indexer.chains[1]), [
      "id",
      "startBlock",
      "endBlock",
      "name",
      "isLive",
      "EventFiltersTest",
      "Gravatar",
      "NftFactory",
      "Noop",
      "SimpleNft",
      "TestEvents",
    ]);
  });

  it("Indexer chains should have contracts with name and abi", () => {
    // Type check: contracts should be present on chain objects
    expectType<
      TypeEqual<
        typeof indexer.chains.ethereumMainnet.Noop,
        {
          readonly name: "Noop";
          readonly abi: readonly unknown[];
          readonly addresses: readonly Address[];
        }
      >
    >(true);

    expectType<
      TypeEqual<
        (typeof indexer.chains)[1337]["Gravatar"],
        {
          readonly name: "Gravatar";
          readonly abi: readonly unknown[];
          readonly addresses: readonly Address[];
        }
      >
    >(true);

    // Value checks: contracts should have name and abi properties
    const { Gravatar, NftFactory } = indexer.chains[1337];
    assert.strictEqual(Gravatar.name, "Gravatar");
    assert.ok(Array.isArray(Gravatar.abi) && Gravatar.abi.length > 0);

    assert.strictEqual(NftFactory.name, "NftFactory");
    assert.ok(Array.isArray(NftFactory.abi));

    // Check contracts exist on other chains
    assert.strictEqual(indexer.chains[1].Noop.name, "Noop");
    assert.strictEqual(
      indexer.chains[100].EventFiltersTest.name,
      "EventFiltersTest"
    );
    assert.strictEqual(indexer.chains[137].Noop.name, "Noop");
  });

  it("Contract ABIs should be the same across chains for same contract", () => {
    // Same contract (Noop) on different chains should have the same ABI
    const chain1 = indexer.chains[1];
    const chain137 = indexer.chains[137];

    assert.deepStrictEqual(
      chain1.Noop.abi,
      chain137.Noop.abi,
      "Same contract on different chains should have identical ABIs"
    );

    // Same contract (EventFiltersTest) on different chains should have the same ABI
    const chain100 = indexer.chains[100];
    assert.deepStrictEqual(
      chain100.EventFiltersTest.abi,
      chain137.EventFiltersTest.abi,
      "EventFiltersTest should have identical ABIs across chains"
    );
  });

  it("Runs contract register handler", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    const dcAddress = "0x1234567890123456789012345678901234567890";

    const event = Gravatar.FactoryEvent.createMockEvent({
      contract: dcAddress,
      testCase: "syncRegistration",
      mockEventData: {
        chainId: 1337,
        block: {
          number: 2,
        },
      },
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1337-${dcAddress}`,
        contract_name: "SimpleNft",
        contract_address: dcAddress,
        chain_id: 1337,
        registering_event_block_number: 2,
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
      mockEventData: {
        chainId: 1337,
      },
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1337-${dcAddress}`,
        contract_name: "SimpleNft",
        contract_address: dcAddress,
        chain_id: 1337,
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
        chainId: 1337,
      },
    });

    const updatedMockDb = await mockDbInitial.processEvents([event]);

    const registeredDcs = updatedMockDb.dynamicContractRegistry.getAll();
    assert.deepEqual(registeredDcs, [
      {
        id: `1337-${expectedChecksummedAddress}`,
        contract_name: "SimpleNft",
        contract_address: expectedChecksummedAddress,
        chain_id: 1337,
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

  it("Should throw when registering a handler after the indexer has finished initializing", async () => {
    const mockDbInitial = MockDb.createMockDb();

    const event = Gravatar.FactoryEvent.createMockEvent({
      testCase: "handlerInHandler",
    });

    await assert.rejects(mockDbInitial.processEvents([event]), {
      message:
        "The indexer finished initializing, so no more handlers can be registered. Make sure the handlers are registered on the top level of the file.",
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

  it("createTestIndexer works", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
        },
      },
    });

    assert.deepEqual(result, {
      checkpoints: [],
      changes: {},
    });
  });
});
