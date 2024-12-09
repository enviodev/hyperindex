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
import * as S from "rescript-schema";
import { expectType, TypeEqual } from "ts-expect";

const zeroAddress = "0x0000000000000000000000000000000000000000";

Gravatar.CustomSelection.handler(async ({ event, context }) => {
  const transactionSchema = S.object({
    to: S.undefined,
    from: "0xfoo",
    hash: S.string,
  });
  transactionSchema.assert(event.transaction)!;
  const blockSchema = S.object({
    hash: S.string,
    number: S.number,
    timestamp: S.number,
    parentHash: "0xParentHash",
  });
  blockSchema.assert(event.block)!;

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
