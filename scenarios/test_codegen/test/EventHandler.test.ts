import assert from "assert";
import { it, describe } from "vitest";
import {
  indexer,
  type User,
  type Indexer,
  type EvmChainId,
  type EvmChainName,
  type FuelChainId,
  type SvmChainId,
  type TestIndexer,
} from "generated";
import { type Address } from "envio";
import { expectType, type TypeEqual } from "ts-expect";
import { createTestIndexer } from "generated";

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
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    // FactoryEvent with syncRegistration testCase triggers context.addSimpleNft
    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "syncRegistration" },
              block: { number: 2 },
            },
          ],
        },
      },
    });

    // Verify dynamic contract was registered
    assert.deepEqual(result.changes[0]?.addresses, {
      sets: [{ address: dcAddress, contract: "SimpleNft" }],
    });
  });

  it("Runs contract register with async handler", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "asyncRegistration" },
            },
          ],
        },
      },
    });

    // Verify dynamic contract was registered
    assert.deepEqual(result.changes[0]?.addresses, {
      sets: [{ address: dcAddress, contract: "SimpleNft" }],
    });
  });

  it("Throws when contract registered in an unawaited macrotask", async (t) => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "throwOnHangingRegistration" },
            },
          ],
        },
      },
    });

    // Since the error is thrown in a separate macrotask, the contract register
    // should finish but the registration shouldn't succeed
    t.expect(result.changes[0]?.addresses).toBeUndefined();
    // Currently no good way to test this:
    // But you should be able to see it in the logs when running the test
    // t.expect(log.message).toEqual(
    //   "Impossible to access context.addSimpleNft after the contract register is resolved. Make sure you didn't miss an await in the handler.",
    // );
  });

  it("entity.getOrCreate should create the entity if it doesn't exist", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "getOrCreate - creates" },
            },
          ],
        },
      },
    });

    const users = await indexer.User.getAll();
    assert.deepEqual(users, [
      {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      },
    ]);
  });

  it("entity.getOrCreate should load the entity if it exists", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    const existingUser: User = {
      id: "0",
      address: "existing",
      updatesCountOnUserForTesting: 0,
      gravatar_id: undefined,
      accountType: "USER",
    };
    indexer.User.set(existingUser);

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "getOrCreate - loads" },
            },
          ],
        },
      },
    });

    const users = await indexer.User.getAll();
    assert.deepEqual(users, [existingUser]);
  });

  it("entity.getOrThrow should return existing entity", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    const existingUser: User = {
      id: "0",
      address: "existing",
      updatesCountOnUserForTesting: 0,
      gravatar_id: undefined,
      accountType: "USER",
    };
    indexer.User.set(existingUser);

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "getOrThrow" },
            },
          ],
        },
      },
    });

    const users = await indexer.User.getAll();
    assert.deepEqual(users, [existingUser]);
  });

  it("entity.getOrThrow throws if entity doesn't exist", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dcAddress, testCase: "getOrThrow" },
              },
            ],
          },
        },
      }),
    );
  });

  it("entity.getOrThrow throws if entity doesn't exist with custom message", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dcAddress, testCase: "getOrThrow - custom message" },
              },
            ],
          },
        },
      }),
    );
  });

  it("entity.getOrThrow - ignores the first fail in loader", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dcAddress, testCase: "getOrThrow - ignores the first fail in loader" },
              },
            ],
          },
        },
      }),
    );
  });

  it("entity.set should be ignored in unordered loader run", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "loaderSetCount" },
            },
          ],
        },
      },
    });

    const users = await indexer.User.getAll();
    assert.deepEqual(users, [
      {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      },
    ]);
  });

  it("Process multiple events in batch", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "processMultipleEvents - 1" },
            },
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "processMultipleEvents - 2" },
            },
          ],
        },
      },
    });

    const allD = await indexer.D.getAll();
    assert.deepEqual(allD, [
      { id: "1", c: "1" },
      { id: "2", c: "2" },
    ]);
  });

  it("Throws when contract registered with invalid address", async () => {
    const indexer = createTestIndexer();

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: "0x0000000000000000000000000000000000000000", testCase: "validatesAddress" },
              },
            ],
          },
        },
      }),
      {
        message:
          'Address "invalid-address" is invalid. Expected a 20-byte hex string starting with 0x.',
      }
    );
  });

  it("Checksums address when contract registered with valid address", async () => {
    const indexer = createTestIndexer();
    // Use a lowercase address that will be checksummed to proper format
    const inputAddress = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266";
    const expectedChecksummedAddress =
      "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: inputAddress, testCase: "checksumsAddress" },
            },
          ],
        },
      },
    });

    assert.deepEqual(result.changes[0]?.addresses, {
      sets: [{ address: expectedChecksummedAddress, contract: "SimpleNft" }],
    });
  });

  it("composes duplicate handlers with same options", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    // Process CustomSelection — original handler + composed handler should both run
    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "CustomSelection",
              transaction: { from: "0xfoo" },
              block: { parentHash: "0xParentHash" },
            },
          ],
        },
      },
    });

    // Original handler sets entity with id = event.transaction.hash
    // Composed handler sets entity with id = "composed-" + event.transaction.hash
    const change = result.changes[0]?.CustomSelectionTestPass;
    assert.equal(change?.sets?.length, 2, "Both original and composed handler should set entities");
    assert.ok(
      change?.sets?.some((e: { id: string }) => e.id.startsWith("composed-")),
      "Composed handler should have set an entity with 'composed-' prefix"
    );
  });

  it("composes duplicate contractRegister with same options", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    // Process FactoryEvent with composeContractRegister testCase —
    // original contractRegister adds SimpleNft (via syncRegistration path),
    // composed contractRegister adds NftFactory
    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "composeContractRegister" },
            },
          ],
        },
      },
    });

    // The composed contractRegister should have registered NftFactory
    const addresses = result.changes[0]?.addresses?.sets;
    assert.ok(
      addresses?.some((a: { contract: string }) => a.contract === "NftFactory"),
      "Composed contractRegister should register NftFactory"
    );
  });

  it("Should be able to run effect with cache", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "testEffectWithCache" },
            },
            {
              contract: "Gravatar",
              event: "FactoryEvent",
              params: { contract: dcAddress, testCase: "testEffectWithCache2" },
            },
          ],
        },
      },
    });
  });

  it("Should throw when effect throws", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dcAddress, testCase: "throwingEffect" },
              },
            ],
          },
        },
      }),
    );
  });

  it("Should throw when registering a handler after the indexer has finished initializing", async () => {
    const indexer = createTestIndexer();
    const dcAddress = "0x1234567890123456789012345678901234567890";

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "Gravatar",
                event: "FactoryEvent",
                params: { contract: dcAddress, testCase: "handlerInHandler" },
              },
            ],
          },
        },
      }),
    );
  });



  it("Currently filters are ignored by the test framework", async () => {
    const indexer = createTestIndexer();

    await assert.rejects(
      indexer.process({
        chains: {
          1337: {
            startBlock: 1,
            endBlock: 100,
            simulate: [
              {
                contract: "EventFiltersTest",
                event: "FilterTestEvent",
                params: { addr: "0x000" },
              },
            ],
          },
        },
      }),
    );
  });

  it("createTestIndexer has chain info", () => {
    const testIndexer = createTestIndexer();

    // TestIndexer should expose chainIds and chains like the Indexer
    assert.deepEqual(testIndexer.chainIds, [1, 100, 137, 1337]);
    assert.deepEqual(Object.keys(testIndexer.chains), ["1", "100", "137", "1337"]);

    // Chain by ID
    const chain = testIndexer.chains[1];
    assert.deepEqual(chain.id, 1);
    assert.deepEqual(chain.name, "ethereumMainnet");
    assert.deepEqual(chain.startBlock, 1);
    assert.deepEqual(chain.endBlock, undefined);
    assert.deepEqual(chain.isLive, false);

    // Chain by name (non-enumerable alias)
    assert.deepEqual(testIndexer.chains[1], testIndexer.chains.ethereumMainnet);

    // Contract info on chain
    assert.deepEqual(chain.Noop.name, "Noop");
    assert.ok(Array.isArray(chain.Noop.abi));
    assert.deepEqual(chain.Noop.addresses, [
      "0x0b2F78c5Bf6d9c12EE1225d5f374Aa91204580C3",
    ]);
  });

  it("TestIndexer contract addresses throws during processing", () => {
    const testIndexer = createTestIndexer();

    // Start processing (don't await)
    testIndexer.process({
      chains: {
        1: { startBlock: 1, endBlock: 100 },
      },
    });

    assert.throws(() => testIndexer.chains[1].Noop.addresses, {
      message:
        "Cannot access Noop.addresses while indexer.process() is running. Wait for process() to complete before reading contract addresses.",
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
      changes: [],
    });
  });

  it("createTestIndexer throws when no chain is defined", () => {
    const indexer = createTestIndexer();

    assert.throws(
      () =>
        indexer.process({
          chains: {},
        }),
      {
        message: "createTestIndexer requires at least one chain to be defined",
      }
    );
  });

  it("createTestIndexer processes multiple chains without simulate", async () => {
    const indexer = createTestIndexer();

    // Chain 1 uses HyperSync, no events in range → empty changes
    // Chains are sorted by chain ID
    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [],
        },
        1: {
          startBlock: 1,
          endBlock: 100,
        },
      },
    });

    assert.deepEqual(result, { changes: [] });
  });

  it("createTestIndexer processes multiple chains with simulate", async () => {
    const indexer = createTestIndexer();

    // Chain 1337 is listed first but has higher ID - should be processed second
    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: {
                id: 1n,
                owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                displayName: "Chain 1337",
                imageUrl: "https://example.com/1337.png",
              },
            },
          ],
        },
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            { contract: "Noop", event: "EmptyEvent" },
          ],
        },
      },
    });

    // Chains are sorted by chain ID: chain 1 first, then chain 1337
    assert.deepEqual(result, {
      changes: [
        {
          block: 1,
          chainId: 1,
          eventsProcessed: 1,
        },
        {
          block: 1,
          chainId: 1337,
          eventsProcessed: 1,
          Gravatar: {
            sets: [
              {
                id: "1",
                owner_id: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                displayName: "Chain 1337",
                imageUrl: "https://example.com/1337.png",
                updatesCount: 1n,
                size: "SMALL",
              },
            ],
          },
        },
      ],
    });
  });

  it("createTestIndexer throws when process is called while already running", async () => {
    const indexer = createTestIndexer();

    // Start first process (don't await)
    const firstProcess = indexer.process({
      chains: {
        1: { startBlock: 1, endBlock: 100 },
      },
    });

    // Try to start second process immediately - throws synchronously
    assert.throws(
      () =>
        indexer.process({
          chains: {
            1: { startBlock: 1, endBlock: 100 },
          },
        }),
      {
        message:
          "createTestIndexer process is already running. Only one process call is allowed at a time",
      }
    );

    // Clean up first process
    await firstProcess;
  });

  it("createTestIndexer throws when startBlock is less than config.startBlock", () => {
    const indexer = createTestIndexer();

    // Chain 1 has start_block: 1 in config.yaml
    assert.throws(
      () =>
        indexer.process({
          chains: {
            1: { startBlock: 0, endBlock: 100 },
          },
        }),
      {
        message:
          "Invalid block range for chain 1: startBlock (0) is less than config.startBlock (1). Either use startBlock >= 1 or create a new test indexer with createTestIndexer().",
      }
    );
  });

  it("createTestIndexer throws when startBlock overlaps with previously processed blocks", async () => {
    const indexer = createTestIndexer();

    // First process: block 1 with simulate event (WriteBatch sets progress to block 1)
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            { contract: "Gravatar", event: "EmptyEvent", block: { number: 100 } },
          ],
        },
      },
    });

    // Second process with startBlock <= 100 should throw (progress block is 100 from WriteBatch)
    assert.throws(
      () =>
        indexer.process({
          chains: {
            1: { startBlock: 50, endBlock: 150 },
          },
        }),
      {
        message:
          "Invalid block range for chain 1: startBlock (50) must be greater than previously processed endBlock (100). Either use startBlock > 100 or create a new test indexer with createTestIndexer().",
      }
    );
  });

  it("TestIndexer result type is properly typed", async () => {
    const testIndexer = createTestIndexer();

    // Verify TestIndexer type matches createTestIndexer return type
    expectType<TypeEqual<typeof testIndexer, TestIndexer>>(true);

    // Verify chain info types
    expectType<TypeEqual<typeof testIndexer.chainIds, readonly (1 | 100 | 137 | 1337)[]>>(true);
    expectType<TypeEqual<typeof testIndexer.chains[1]["isLive"], boolean>>(true);
    expectType<TypeEqual<typeof testIndexer.chains[1]["id"], 1>>(true);

    const result = await testIndexer.process({
      chains: {
        1: { startBlock: 1, endBlock: 100 },
      },
    });

    const change = result.changes[0];
    if (change) {
      // Verify change has expected metadata fields
      expectType<TypeEqual<typeof change.block, number>>(true);
      expectType<TypeEqual<typeof change.chainId, number>>(true);
      expectType<TypeEqual<typeof change.eventsProcessed, number>>(true);
      expectType<TypeEqual<typeof change.blockHash, string | undefined>>(true);

      // Verify entity changes have expected structure
      const userChange = change.User;
      if (userChange) {
        expectType<
          TypeEqual<typeof userChange.sets, readonly User[] | undefined>
        >(true);
        expectType<
          TypeEqual<typeof userChange.deleted, readonly string[] | undefined>
        >(true);
      }
    }
  });

  it("TestIndexer.Entity.set stores entity and .get retrieves it", async () => {
    const indexer = createTestIndexer();

    const user: User = {
      id: "test-user-1",
      address: "0x1234",
      updatesCountOnUserForTesting: 5,
      gravatar_id: undefined,
      accountType: "USER",
    };

    // Set entity
    indexer.User.set(user);

    // Get entity
    const retrieved = await indexer.User.get("test-user-1");
    assert.deepEqual(retrieved, user);
  });

  it("TestIndexer.Entity.get returns undefined for non-existent entity", async () => {
    const indexer = createTestIndexer();

    const retrieved = await indexer.User.get("non-existent");
    assert.strictEqual(retrieved, undefined);
  });

  it("TestIndexer.Entity.set overwrites existing entity", async () => {
    const indexer = createTestIndexer();

    const user1: User = {
      id: "test-user-1",
      address: "0x1234",
      updatesCountOnUserForTesting: 5,
      gravatar_id: undefined,
      accountType: "USER",
    };

    const user2: User = {
      id: "test-user-1",
      address: "0x5678",
      updatesCountOnUserForTesting: 10,
      gravatar_id: "gravatar-1",
      accountType: "ADMIN",
    };

    indexer.User.set(user1);
    indexer.User.set(user2);

    const retrieved = await indexer.User.get("test-user-1");
    assert.deepEqual(retrieved, user2);
  });

  it("TestIndexer.Entity.get throws when called during processing", () => {
    const indexer = createTestIndexer();

    // Start processing (don't await - we're testing the error during processing)
    indexer.process({
      chains: {
        1: { startBlock: 1, endBlock: 100 },
      },
    });

    // The error is thrown synchronously when calling get during processing
    assert.throws(() => indexer.User.get("test-user-1"), {
      message:
        "Cannot call User.get() while indexer.process() is running. Wait for process() to complete before accessing entities directly.",
    });
  });

  it("TestIndexer.Entity.set throws when called during processing", () => {
    const indexer = createTestIndexer();

    const user: User = {
      id: "test-user-1",
      address: "0x1234",
      updatesCountOnUserForTesting: 5,
      gravatar_id: undefined,
      accountType: "USER",
    };

    // Start processing (don't await - we're testing the error during processing)
    indexer.process({
      chains: {
        1: { startBlock: 1, endBlock: 100 },
      },
    });

    // Try to call set during processing
    assert.throws(() => indexer.User.set(user), {
      message:
        "Cannot call User.set() while indexer.process() is running. Wait for process() to complete before modifying entities directly.",
    });
  });

  it("simulate block numbers and log indexes are managed correctly", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            // Item 1: no explicit block → uses startBlock (1), logIndex 0
            { contract: "Gravatar", event: "EmptyEvent" },
            // Item 2: no explicit block → same block (1), logIndex 1
            { contract: "Gravatar", event: "EmptyEvent" },
            // Item 3: explicit block number 50
            { contract: "Gravatar", event: "EmptyEvent", block: { number: 50 } },
            // Item 4: no explicit block → continues from last explicit (50)
            { contract: "Gravatar", event: "EmptyEvent" },
          ],
        },
      },
    });

    const entities = await indexer.SimulateTestEvent.getAll();
    // Sort by id for stable ordering
    entities.sort((a, b) => a.id.localeCompare(b.id));

    assert.deepEqual(entities, [
      { id: "1_0", blockNumber: 1, logIndex: 0, timestamp: 0 },
      { id: "1_1", blockNumber: 1, logIndex: 1, timestamp: 0 },
      { id: "50_2", blockNumber: 50, logIndex: 2, timestamp: 0 },
      { id: "50_3", blockNumber: 50, logIndex: 3, timestamp: 0 },
    ]);
  });

  it("simulate passes block timestamp to event", async () => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "EmptyEvent",
              block: { number: 5, timestamp: 1234567890 },
            },
          ],
        },
      },
    });

    const entity = await indexer.SimulateTestEvent.get("5_0");
    assert.deepEqual(entity, {
      id: "5_0",
      blockNumber: 5,
      logIndex: 0,
      timestamp: 1234567890,
    });
  });

  it("createTestIndexer with simulate processes events without fetching", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: {
                id: 1n,
                owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                displayName: "Test Gravatar",
                imageUrl: "https://example.com/image.png",
              },
            },
          ],
        },
      },
    });

    assert.deepEqual(result, {
      changes: [
        {
          block: 1,
          chainId: 1337,
          eventsProcessed: 1,
          Gravatar: {
            sets: [
              {
                id: "1",
                owner_id: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                displayName: "Test Gravatar",
                imageUrl: "https://example.com/image.png",
                updatesCount: 1n,
                size: "SMALL",
              },
            ],
          },
        },
      ],
    });

    // Entity should be accessible after processing
    const gravatar = await indexer.Gravatar.get("1");
    assert.deepEqual(gravatar, {
      id: "1",
      owner_id: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      displayName: "Test Gravatar",
      imageUrl: "https://example.com/image.png",
      updatesCount: 1n,
      size: "SMALL",
    });
  });

  it("createTestIndexer with simulate processes multiple events", async () => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1337: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: {
                id: 1n,
                owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                displayName: "First",
                imageUrl: "https://example.com/1.png",
              },
            },
            {
              contract: "Gravatar",
              event: "NewGravatar",
              params: {
                id: 2n,
                owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
                displayName: "Second",
                imageUrl: "https://example.com/2.png",
              },
            },
          ],
        },
      },
    });

    // Should have processed both events
    assert.strictEqual(result.changes.length, 1);
    assert.strictEqual(result.changes[0]!.eventsProcessed, 2);
    assert.strictEqual(result.changes[0]!.Gravatar?.sets?.length, 2);
  });
});
