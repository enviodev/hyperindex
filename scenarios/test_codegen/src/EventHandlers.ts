import {
  AccountType,
  BigDecimal,
  NftCollectionEntity,
  NftFactoryContract,
  SimpleNftContract,
  UserEntity,
  BigDecimal,
} from "generated";

const zeroAddress = "0x0000000000000000000000000000000000000000";

NftFactoryContract.SimpleNftCreated.register({
  contractRegister: ({ event, context }) => {
    context.addSimpleNft(event.params.contractAddress);
  },
  preLoader: async (_) => undefined,
  handler: async ({ event, context }) => {
    let nftCollection: NftCollectionEntity = {
      id: event.params.contractAddress,
      contractAddress: event.params.contractAddress,
      name: event.params.name,
      symbol: event.params.symbol,
      maxSupply: event.params.maxSupply,
      currentSupply: 0,
    };
    context.NftCollection.set(nftCollection);
    context.EntityWithFields.set({
      id: "testingBigDecimalWorks",
      bigDecimal: new BigDecimal(123.456),
    });
  },
});

SimpleNftContract.Transfer.register({
  preLoader: async ({ event, context }) => {
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
  handler: async ({ event, context, preLoaderReturn }) => {
    const {
      loadedUserFrom,
      loadedUserTo,
      nftCollectionUpdated,
      existingToken,
    } = preLoaderReturn;
    const token = {
      id: event.srcAddress.concat("-").concat(event.params.tokenId.toString()),
      tokenId: event.params.tokenId,
      collection_id: event.srcAddress,
      owner_id: event.params.to,
    };
    if (nftCollectionUpdated) {
      if (!existingToken) {
        let currentSupply = Number(nftCollectionUpdated.currentSupply) + 1;

        let nftCollection: NftCollectionEntity = {
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
      const userFrom: UserEntity = {
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
      const userTo: UserEntity = {
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
