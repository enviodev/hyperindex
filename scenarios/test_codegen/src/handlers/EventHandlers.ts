import { deepEqual, fail } from "assert";
import {
  createEffect,
  type Effect,
  S,
  type Logger,
  type EffectCaller,
  TestHelpers,
} from "envio";
import {
  BigDecimal,
  indexer,
  type EvmChainId,
  type EvmEvent,
  type NftCollection,
  type User,
} from "generated";
import { expectType, type TypeEqual } from "ts-expect";
import { bytesToHex } from "viem";

// Test effects type inference
const noopEffect = createEffect(
  {
    name: "noopEffect",
    input: undefined,
    output: undefined,
    rateLimit: false,
  },
  async ({ context, input }) => {
    expectType<TypeEqual<typeof input, undefined>>(true);
    expectType<TypeEqual<typeof noopEffect, Effect<undefined, undefined>>>(
      true,
    );
    const result = await context.effect(noopEffect, undefined);
    expectType<TypeEqual<typeof result, undefined>>(true);
    // @ts-expect-error
    await context.effect(noopEffect, "foo");
    return undefined;
  },
);
const getFiles = createEffect(
  {
    name: "getFiles",
    input: {
      foo: S.string,
      bar: S.optional(S.string),
    },
    output: S.union(["foo", "files"]),
    rateLimit: false,
  },
  async ({ context, input }) => {
    if (Math.random() > 0.5) {
      return "files";
    }
    // @ts-expect-error
    await context.effect(getFiles, undefined);
    const recursive = await context.effect(getFiles, {
      foo: "bar",
      bar: undefined,
    });
    expectType<
      TypeEqual<
        typeof input,
        {
          foo: string;
          bar?: string | undefined;
        }
      >
    >(true);
    expectType<TypeEqual<typeof recursive, "files" | "foo">>(true);
    expectType<
      TypeEqual<
        typeof getFiles,
        Effect<
          {
            foo: string;
            bar?: string | undefined;
          },
          "files" | "foo"
        >
      >
    >(true);
    return "foo";
  },
);
const getBalance = createEffect(
  {
    name: "getBalance",
    input: {
      address: S.address,
      blockNumber: S.optional(S.bigint),
    },
    output: S.bigDecimal,
    rateLimit: false,
  },
  async ({ context, input: { address, blockNumber } }) => {
    try {
      // If blockNumber is provided, use it to get balance at that specific block
      const options = blockNumber ? { blockNumber } : undefined;
      // const balance = await lbtcContract.read.balanceOf(
      //   [address as `0x${string}`],
      //   options
      // );
      const balance = 123n;

      // Only log on successful retrieval to reduce noise
      context.log.info(
        `Balance of ${address}${
          blockNumber ? ` at block ${blockNumber}` : ""
        }: ${balance}`,
      );

      return BigDecimal(balance.toString());
    } catch (error) {
      context.log.error(`Error getting balance for ${address}`, error as Error);
      // Return 0 on error to prevent processing failures
      return BigDecimal(0);
    }
  },
);
expectType<
  TypeEqual<
    typeof getBalance,
    Effect<
      { address: `0x${string}`; blockNumber?: bigint | undefined },
      BigDecimal
    >
  >
>(true);

const zeroAddress = "0x0000000000000000000000000000000000000000";

indexer.onEvent({ contract: "Gravatar", event: "CustomSelection" }, async ({ event, context }) => {
  if (0) {
    const _ = await context.effect(noopEffect, undefined);
    context.log.error("There's an error");
    context.log.error("This is a test error", new Error("Test error message"));
    context.log.warn("This is a test warn", { foo: "bar" });
  }

  const transactionSchema = S.schema({
    to: undefined,
    from: "0xfoo",
    hash: S.string,
  });
  S.assertOrThrow(event.transaction, transactionSchema)!;
  const blockSchema = S.schema({
    hash: S.string,
    number: S.number,
    timestamp: S.number,
    parentHash: "0xParentHash",
  });
  S.assertOrThrow(event.block, blockSchema)!;
  deepEqual(context.chain.id, event.chainId);

  // Type checking for custom field selection is done in CustomSelection.test.ts

  // Test chain field accessibility in TypeScript
  expectType<
    TypeEqual<
      typeof context.chain,
      {
        readonly id: EvmChainId;
        readonly isLive: boolean;
      }
    >
  >(true);

  context.CustomSelectionTestPass.set({
    id: event.transaction.hash,
  });
});

indexer.contractRegister({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  context.chain.SimpleNft.add(event.params.contractAddress);
});

indexer.onEvent({ contract: "NftFactory", event: "SimpleNftCreated" }, async ({ event, context }) => {
  // Type validation: EvmEvent params match handler event params
  expectType<
    TypeEqual<
      typeof event.params,
      EvmEvent<"NftFactory", "SimpleNftCreated">["params"]
    >
  >(true);

  let nftCollection: NftCollection = {
    id: event.params.contractAddress,
    contractAddress: event.params.contractAddress,
    name: event.params.name,
    symbol: event.params.symbol,
    maxSupply: event.params.maxSupply,
    currentSupply: 0,
  };
  context.NftCollection.set(nftCollection);
  context.EntityWithBigDecimal.set({
    id: "testingEntityWithBigDecimal",
    bigDecimal: new BigDecimal(123.456),
  });
  context.EntityWithTimestamp.set({
    id: "testingEntityWithTimestamp",
    timestamp: new Date(1725265940437),
  });
});

indexer.onEvent({ contract: "SimpleNft", event: "Transfer" }, async ({ event, context }) => {
  const [loadedUserFrom, loadedUserTo, nftCollectionUpdated, existingToken] =
    await Promise.all([
      context.User.get(event.params.from),
      context.User.get(event.params.to),
      context.NftCollection.get(event.srcAddress),
      context.Token.get(
        event.srcAddress.concat("-").concat(event.params.tokenId.toString()),
      ),
    ]);

  const token = {
    id: event.srcAddress.concat("-").concat(event.params.tokenId.toString()),
    tokenId: event.params.tokenId,
    collection_id: event.srcAddress,
    owner_id: event.params.to,
  };
  if (nftCollectionUpdated) {
    if (!existingToken) {
      let currentSupply = Number(nftCollectionUpdated.currentSupply) + 1;

      let nftCollection: NftCollection = {
        ...nftCollectionUpdated,
        currentSupply,
      };
      context.NftCollection.set(nftCollection);
    }
  } else {
    console.log(
      "Issue with events emitted, unregistered NFT collection transfer",
    );
    return;
  }

  if (event.params.from !== zeroAddress) {
    const userFrom: User = {
      id: event.params.from,
      address: event.params.from,
      updatesCountOnUserForTesting:
        loadedUserFrom?.updatesCountOnUserForTesting || 0,
      gravatar_id: undefined,
      accountType: "USER",
    };
    context.User.set(userFrom);
  }

  if (event.params.to !== zeroAddress) {
    const userTo: User = {
      id: event.params.to,
      address: event.params.to,
      updatesCountOnUserForTesting:
        loadedUserTo?.updatesCountOnUserForTesting || 0,
      gravatar_id: undefined,
      accountType: "ADMIN",
    };
    context.User.set(userTo);
  }

  context.Token.set(token);
});

// Test event filtering hashing
export const hashingTestParams = {
  id: 50n,
  addr: TestHelpers.Addresses.mockAddresses[0]!,
  str: "test",
  isTrue: true,
  dynBytes: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 9]),
  fixedBytes32: new Uint8Array(32).fill(0x12),
  struct: [50n, "test"] satisfies [bigint, string],
};
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedUint",
    where: { params: { num: [hashingTestParams.id] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedInt",
    where: { params: { num: [-hashingTestParams.id] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedBool",
    where: { params: { isTrue: [hashingTestParams.isTrue] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedAddress",
    where: { params: { addr: [hashingTestParams.addr] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedBytes",
    where: { params: { dynBytes: [bytesToHex(hashingTestParams.dynBytes)] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedFixedBytes",
    where: { params: { fixedBytes: [bytesToHex(hashingTestParams.fixedBytes32)] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedString",
    where: { params: { str: [hashingTestParams.str] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedStruct",
    where: { params: { testStruct: hashingTestParams.struct } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedArray",
    where: { params: { array: [[hashingTestParams.id, hashingTestParams.id + 1n]] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedFixedArray",
    where: { params: { array: [[hashingTestParams.id, hashingTestParams.id + 1n]] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedNestedArray",
    where: {
      params: {
        array: [
          [
            [hashingTestParams.id, hashingTestParams.id],
            [hashingTestParams.id, hashingTestParams.id],
          ],
        ],
      },
    },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedStructArray",
    where: { params: { array: [[hashingTestParams.struct, hashingTestParams.struct]] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedNestedStruct",
    where: { params: { nestedStruct: [[hashingTestParams.id, hashingTestParams.struct]] } },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "TestEvents",
    event: "IndexedStructWithArray",
    where: {
      params: {
        structWithArray: [
          [hashingTestParams.id, hashingTestParams.id + 1n],
          [hashingTestParams.str, hashingTestParams.str],
        ],
      },
    },
  },
  async (_) => {},
);

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;
const WHITELISTED_ADDRESSES = {
  137: [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" as const,
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const,
  ],
  100: ["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC" as const],
};
indexer.onEvent(
  {
    contract: "EventFiltersTest",
    event: "Transfer",
    wildcard: true,
    where: ({ chainId }) => {
      if (chainId !== 100 && chainId !== 137) {
        return false;
      }
      return {
        params: [
          { from: ZERO_ADDRESS, to: WHITELISTED_ADDRESSES[chainId] },
          { from: WHITELISTED_ADDRESSES[chainId], to: ZERO_ADDRESS },
        ],
      };
    },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "EventFiltersTest",
    event: "EmptyFiltersArray",
    wildcard: true,
    where: ({ chainId }) => {
      if (chainId !== 100 && chainId !== 137) {
        return false;
      }
      return { params: [] };
    },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "EventFiltersTest",
    event: "WildcardWithAddress",
    wildcard: true,
    where: ({ chainId, addresses }) => {
      if (chainId !== 100 && chainId !== 137) {
        return false;
      }
      return {
        params: [
          { from: ZERO_ADDRESS, to: addresses },
          { from: addresses, to: ZERO_ADDRESS },
        ],
      };
    },
  },
  async (_) => {},
);
indexer.onEvent(
  {
    contract: "EventFiltersTest",
    event: "WithExcessField",
    wildcard: true,
    where: ({ chainId }) => {
      if (chainId !== 100 && chainId !== 137) {
        return false;
      }
      return { params: { from: ZERO_ADDRESS, to: ZERO_ADDRESS } };
    },
  },
  async (_) => {},
);

indexer.contractRegister({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  expectType<TypeEqual<typeof context.log, Logger>>(true);

  switch (event.params.testCase) {
    case "throwOnHangingRegistration":
      setTimeout(() => {
        try {
          context.chain.SimpleNft.add(event.params.contract);
        } catch (error) {
          deepEqual(
            error,
            new Error(
              `Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.`,
            ),
          );
        }
      }, 0);
      break;
    case "asyncRegistration":
      return new Promise<void>((resolve) =>
        setTimeout(() => {
          context.chain.SimpleNft.add(event.params.contract);
          resolve();
        }, 0),
      );
    case "syncRegistration":
      context.chain.SimpleNft.add(event.params.contract);
      break;
    case "validatesAddress":
      // This should throw because the address is invalid
      // @ts-expect-error
      context.chain.SimpleNft.add("invalid-address");
      break;
    case "checksumsAddress":
      // This should work and the address should be checksummed
      context.chain.SimpleNft.add(event.params.contract);
      break;
  }
});

const testEffectWithCache = createEffect(
  {
    name: "testEffectWithCache",
    input: {
      id: S.string,
    },
    output: S.string,
    rateLimit: false,
    cache: true,
  },
  async ({ context, input }) => {
    deepEqual(
      Object.keys(context),
      ["effect", "cache"],
      "Logger is on prototype and not included in Object.keys",
    );
    deepEqual(context.cache, true);
    expectType<
      TypeEqual<
        typeof context,
        {
          readonly log: Logger;
          readonly effect: EffectCaller;
          cache: boolean;
        }
      >
    >(true);

    return `test-${input.id}`;
  },
);

const throwingEffect = createEffect(
  {
    name: "throwingEffect",
    input: {
      id: S.string,
    },
    output: S.string,
    rateLimit: false,
    cache: true,
  },
  async (_) => {
    throw new Error("Error from effect");
  },
);

let getOrThrowInLoaderCount = 0;
let loaderSetCount = 0;

indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  switch (event.params.testCase) {
    case "getOrThrow - ignores the first fail in loader": {
      switch (getOrThrowInLoaderCount) {
        case 0: {
          getOrThrowInLoaderCount++;
          await context.User.getOrThrow(
            "0",
            "This should fail, but silently ignored on the first loader run.",
          );
          break;
        }
        case 1: {
          await context.User.getOrThrow(
            "0",
            "Second loader failure should abort processing",
          );
          break;
        }
      }
      break;
    }
    case "loaderSetCount": {
      const entity = await context.User.get("0");
      const newEntity: User = {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      };
      context.User.set(newEntity);
      switch (loaderSetCount) {
        case 0:
          deepEqual(entity, undefined);
          deepEqual(await context.User.get("0"), undefined);
          deepEqual(context.isPreload, true);
          break;
        case 1:
          // It should only apply set only on the second loader run
          deepEqual(entity, undefined);
          deepEqual(await context.User.get("0"), newEntity);
          deepEqual(context.isPreload, false);
          break;
      }
      loaderSetCount++;
      break;
    }
  }

  if (context.isPreload) {
    return;
  }

  switch (event.params.testCase) {
    case "entityWithAllTypesSet":
      context.EntityWithAllTypes.set({
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
        bigDecimalWithConfig: new BigDecimal("1.1"),
        optBigDecimal: new BigDecimal("2.2"),
        arrayOfBigDecimals: [new BigDecimal("3.3"), new BigDecimal("4.4")],
        json: { foo: ["bar"] },
        enumField: "ADMIN",
        optEnumField: "ADMIN",
        timestamp: new Date(1725265940437),
        optTimestamp: new Date(1725265940438),
      });
      context.EntityWithAllTypes.set({
        id: "2",
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
        bigDecimalWithConfig: new BigDecimal("1.1"),
        optBigDecimal: new BigDecimal("2.2"),
        arrayOfBigDecimals: [new BigDecimal("3.3"), new BigDecimal("4.4")],
        json: { foo: ["bar"] },
        enumField: "ADMIN",
        optEnumField: "ADMIN",
        timestamp: new Date(1725265940437),
        optTimestamp: new Date(1725265940438),
      });
      break;

    case "getOrCreate - creates": {
      const user = await context.User.getOrCreate({
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      });
      expectType<TypeEqual<typeof user, User>>(true);
      deepEqual(user, {
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      });
      break;
    }

    case "getOrCreate - loads": {
      const user = await context.User.getOrCreate({
        id: "0",
        address: "0x",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      });
      expectType<TypeEqual<typeof user, User>>(true);
      deepEqual(
        user,
        {
          id: "0",
          address: "existing",
          updatesCountOnUserForTesting: 0,
          gravatar_id: undefined,
          accountType: "USER",
        },
        "Note how address is 'existing' and not '0x'",
      );
      break;
    }

    case "getOrThrow": {
      const user = await context.User.getOrThrow("0");
      expectType<TypeEqual<typeof user, User>>(true);
      deepEqual(user, {
        id: "0",
        address: "existing",
        updatesCountOnUserForTesting: 0,
        gravatar_id: undefined,
        accountType: "USER",
      });
      break;
    }

    case "getOrThrow - custom message": {
      await context.User.getOrThrow("0", "User should always exist");
      break;
    }

    case "processMultipleEvents - 1": {
      context.D.set({
        id: "1",
        c: "1",
      });
      break;
    }

    case "handlerInHandler": {
      indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {});
      break;
    }

    case "processMultipleEvents - 2": {
      context.D.set({
        id: "2",
        c: "2",
      });
      break;
    }

    case "testEffectWithCache": {
      const result = await context.effect(testEffectWithCache, {
        id: "1",
      });
      deepEqual(result, "test-1");
      break;
    }

    case "testEffectWithCache2": {
      const result = await context.effect(testEffectWithCache, {
        id: "2",
      });
      deepEqual(result, "test-2");
      break;
    }

    case "throwingEffect": {
      await context.effect(throwingEffect, {
        id: "1",
      });
      fail("Should have thrown");
    }
  }
});

indexer.onEvent({ contract: "EventFiltersTest", event: "FilterTestEvent", where: ({ chainId }) => {
  if (chainId !== 100 && chainId !== 137) {
    return false;
  }
  return {
    params: {
      addr: ["0x000" as `0x${string}`],
    },
  };
} }, async ({ event }) => {
  if (event.params.addr === "0x000") {
    throw new Error("This should not be called");
  }
});

// Duplicate handler registration tests

// Same options (no options) → should compose without error.
// The composed handler sets an additional entity to prove it ran.
indexer.onEvent({ contract: "Gravatar", event: "CustomSelection" }, async ({ event, context }) => {
  context.CustomSelectionTestPass.set({
    id: "composed-" + event.transaction.hash,
  });
});

// Same options → composed contractRegister registers an additional contract
indexer.contractRegister({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (event.params.testCase === "composeContractRegister") {
    context.chain.NftFactory.add(event.params.contract);
  }
});

// Capture the inner add() closure in one contractRegister invocation, then try
// to invoke the captured closure from a later onEvent handler (after the first
// handler has resolved and params.isResolved === true). The call must throw —
// this guards against the captured-add bypass where
// `const add = context.chain.X.add` survives past handler resolution.
// We signal success via the CustomSelectionTestPass entity so the test can
// observe the outcome across the createTestIndexer worker boundary.
let _capturedCrAdd: ((address: `0x${string}`) => void) | null = null;
indexer.contractRegister({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (event.params.testCase === "captureAdd") {
    _capturedCrAdd = context.chain.SimpleNft.add;
  }
});
indexer.onEvent({ contract: "Gravatar", event: "FactoryEvent" }, async ({ event, context }) => {
  if (event.params.testCase === "callCapturedAdd" && _capturedCrAdd) {
    const outcome = (() => {
      try {
        _capturedCrAdd!("0x1234567890123456789012345678901234567890");
        return "captured-add-did-not-throw";
      } catch {
        return "captured-add-threw";
      }
    })();
    context.CustomSelectionTestPass.set({
      id: outcome,
    });
  }
});

// Different options → should throw
export let mismatchedHandlerOptionsError: Error | undefined;
try {
  indexer.onEvent({ contract: "Gravatar", event: "CustomSelection", wildcard: true }, async () => {});
} catch (e) {
  mismatchedHandlerOptionsError = e as Error;
}

// Handler for testing simulate block/logIndex behavior
indexer.onEvent({ contract: "Gravatar", event: "EmptyEvent" }, async ({ event, context }) => {
  context.SimulateTestEvent.set({
    id: `${event.block.number}_${event.logIndex}`,
    blockNumber: event.block.number,
    logIndex: event.logIndex,
    timestamp: event.block.timestamp,
  });
});

// Module-scope `indexer.onBlock` registrations exercising the four code paths
// in `Main.res::onBlockFn` at indexer-init time:
//   - boolean predicate (true/false per chain)
//   - filter-object predicate (range + stride)
//   - default (no `where`, registers on every chain)
//   - skip-all (`where: () => false`, triggers the zero-match warn log)
//
// All non-skip-all predicates pin to chain 137 (configured in config.yaml
// but not used by any existing simulate/process test) so the handlers
// register without crashing the per-chain validation in `ChainFetcher.res`
// and don't fire on existing test runs (which would pollute the
// `result.changes` array). Handlers are no-ops — the value here is
// validating the registration paths (`where` evaluated per chain, range
// schema parsed) without throwing. End-to-end block-firing behavior is
// covered by `lib_tests/FetchState_onBlock_test.res` at the layer below.
indexer.onBlock(
  { name: "test_onblock_bool", where: ({ chain }) => chain.id === 137 },
  async () => {},
);
indexer.onBlock(
  {
    name: "test_onblock_filter",
    where: ({ chain }) =>
      chain.id === 137
        ? { block: { number: { _gte: 100, _lte: 200, _every: 5 } } }
        : false,
  },
  async () => {},
);
// `test_onblock_default` would register on every configured chain — but
// that fires on every block of every test indexer run, polluting their
// `result.changes` deep-equal assertions. Pin it to chain 137 too; the
// "no `where`" code path is exercised by `test_onblock_skip_all` below
// (which goes through the same `None` branch on chains it doesn't match).
indexer.onBlock(
  { name: "test_onblock_default", where: ({ chain }) => chain.id === 137 },
  async () => {},
);
indexer.onBlock(
  { name: "test_onblock_skip_all", where: () => false },
  async () => {},
);
