import { experimental_createEffect, Effect, S } from "envio";
import { TestEvents } from "generated";
import { TestHelpers } from "generated";
import { EventFiltersTest } from "generated";
import {
  Gravatar,
  BigDecimal,
  NftFactory,
  SimpleNft,
  NftCollection,
  User,
  eventLog,
  NftFactory_SimpleNftCreated_eventArgs,
  NftFactory_SimpleNftCreated_event,
} from "generated";
import { expectType, TypeEqual } from "ts-expect";
import { bytesToHex } from "viem";

// Test effects type inference
const noopEffect = experimental_createEffect(
  {
    name: "noopEffect",
    input: undefined,
    output: undefined,
  },
  async ({ context, input }) => {
    expectType<TypeEqual<typeof input, undefined>>(true);
    expectType<TypeEqual<typeof noopEffect, Effect<undefined, undefined>>>(
      true
    );
    const result = await context.effect(noopEffect, undefined);
    expectType<TypeEqual<typeof result, undefined>>(true);
    // @ts-expect-error
    await context.effect(noopEffect, "foo");
    return undefined;
  }
);
const getFiles = experimental_createEffect(
  {
    name: "getFiles",
    input: {
      foo: S.string,
      bar: S.optional(S.string),
    },
    output: S.union(["foo", "files"]),
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
          bar: string | undefined;
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
            bar: string | undefined;
          },
          "files" | "foo"
        >
      >
    >(true);
    return "foo";
  }
);
const getBalance = experimental_createEffect(
  {
    name: "getBalance",
    input: {
      address: S.string,
      blockNumber: S.optional(S.bigint),
    },
    output: S.bigDecimal,
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
        }: ${balance}`
      );

      return BigDecimal(balance.toString());
    } catch (error) {
      context.log.error(`Error getting balance for ${address}`, error as Error);
      // Return 0 on error to prevent processing failures
      return BigDecimal(0);
    }
  }
);
expectType<
  TypeEqual<
    typeof getBalance,
    Effect<{ address: string; blockNumber: bigint | undefined }, BigDecimal>
  >
>(true);

const zeroAddress = "0x0000000000000000000000000000000000000000";

Gravatar.CustomSelection.handler(async ({ event, context }) => {
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

  // We already do type checking in the tests,
  // but double-check that we receive correct types
  // in the handler args as well
  expectType<
    TypeEqual<
      typeof event.transaction,
      {
        readonly to: string | undefined;
        readonly from: string | undefined;
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

  context.CustomSelectionTestPass.set({
    id: event.transaction.hash,
  });
});

NftFactory.SimpleNftCreated.contractRegister(({ event, context }) => {
  context.addSimpleNft(event.params.contractAddress);
});

NftFactory.SimpleNftCreated.handlerWithLoader({
  loader: async (_) => undefined,
  handler: async ({ event, context }) => {
    const testType: NftFactory_SimpleNftCreated_event =
      event satisfies eventLog<NftFactory_SimpleNftCreated_eventArgs>;

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
  },
});

SimpleNft.Transfer.handlerWithLoader({
  loader: async ({ event, context }) => {
    const [loadedUserFrom, loadedUserTo, nftCollectionUpdated, existingToken] =
      await Promise.all([
        context.User.get(event.params.from),
        context.User.get(event.params.to),
        context.NftCollection.get(event.srcAddress),
        context.Token.get(
          event.srcAddress.concat("-").concat(event.params.tokenId.toString())
        ),
      ]);

    return {
      loadedUserFrom,
      loadedUserTo,
      nftCollectionUpdated,
      existingToken,
    };
  },
  handler: async ({ event, context, loaderReturn }) => {
    const {
      loadedUserFrom,
      loadedUserTo,
      nftCollectionUpdated,
      existingToken,
    } = loaderReturn;
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
        "Issue with events emitted, unregistered NFT collection transfer"
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
  },
});

// Test event filtering hashing
export const hashingTestParams = {
  id: 50n,
  addr: TestHelpers.Addresses.mockAddresses[0],
  str: "test",
  isTrue: true,
  dynBytes: new Uint8Array([1, 2, 3, 4, 5, 6, 7, 9]),
  fixedBytes32: new Uint8Array(32).fill(0x12),
  struct: [50n, "test"] satisfies [bigint, string],
};
TestEvents.IndexedUint.handler(async (_) => {}, {
  eventFilters: {
    num: [hashingTestParams.id],
  },
});
TestEvents.IndexedInt.handler(async (_) => {}, {
  eventFilters: {
    num: [-hashingTestParams.id],
  },
});
TestEvents.IndexedBool.handler(async (_) => {}, {
  eventFilters: {
    isTrue: [hashingTestParams.isTrue],
  },
});
TestEvents.IndexedAddress.handler(async (_) => {}, {
  eventFilters: {
    addr: [hashingTestParams.addr],
  },
});
TestEvents.IndexedBytes.handler(async (_) => {}, {
  eventFilters: {
    dynBytes: [bytesToHex(hashingTestParams.dynBytes)],
  },
});
TestEvents.IndexedFixedBytes.handler(async (_) => {}, {
  eventFilters: {
    fixedBytes: [bytesToHex(hashingTestParams.fixedBytes32)],
  },
});
TestEvents.IndexedString.handler(async (_) => {}, {
  eventFilters: {
    str: [hashingTestParams.str],
  },
});
TestEvents.IndexedStruct.handler(async (_) => {}, {
  eventFilters: {
    testStruct: hashingTestParams.struct,
  },
});
TestEvents.IndexedArray.handler(async (_) => {}, {
  eventFilters: {
    array: [[hashingTestParams.id, hashingTestParams.id + 1n]],
  },
});
TestEvents.IndexedFixedArray.handler(async (_) => {}, {
  eventFilters: {
    array: [[hashingTestParams.id, hashingTestParams.id + 1n]],
  },
});
TestEvents.IndexedNestedArray.handler(async (_) => {}, {
  eventFilters: {
    array: [
      [
        [hashingTestParams.id, hashingTestParams.id],
        [hashingTestParams.id, hashingTestParams.id],
      ],
    ],
  },
});
TestEvents.IndexedStructArray.handler(async (_) => {}, {
  eventFilters: {
    array: [[hashingTestParams.struct, hashingTestParams.struct]],
  },
});
TestEvents.IndexedNestedStruct.handler(async (_) => {}, {
  eventFilters: {
    nestedStruct: [[hashingTestParams.id, hashingTestParams.struct]],
  },
});
TestEvents.IndexedStructWithArray.handler(async (_) => {}, {
  eventFilters: {
    structWithArray: [
      [hashingTestParams.id, hashingTestParams.id + 1n],
      [hashingTestParams.str, hashingTestParams.str],
    ],
  },
});

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const WHITELISTED_ADDRESSES = {
  137: [
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  ],
  100: ["0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"],
};
EventFiltersTest.Transfer.handler(async (_) => {}, {
  wildcard: true,
  eventFilters: ({ chainId }) => {
    return [
      { from: ZERO_ADDRESS, to: WHITELISTED_ADDRESSES[chainId] },
      { from: WHITELISTED_ADDRESSES[chainId], to: ZERO_ADDRESS },
    ];
  },
});
EventFiltersTest.EmptyFiltersArray.handler(async (_) => {}, {
  wildcard: true,
  eventFilters: [],
});
EventFiltersTest.WildcardWithAddress.handler(async (_) => {}, {
  wildcard: true,
  eventFilters: ({ addresses }) => {
    return [
      { from: ZERO_ADDRESS, to: addresses },
      { from: addresses, to: ZERO_ADDRESS },
    ];
  },
});
EventFiltersTest.WithExcessField.handler(async (_) => {}, {
  wildcard: true,
  eventFilters: (_) => {
    return { from: ZERO_ADDRESS, to: ZERO_ADDRESS };
  },
});
