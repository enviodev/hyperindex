import {
  NftFactoryContract,
  SimpleNftContract,
  NftCollectionEntity,
  UserEntity,
  BigDecimal,
  AccountType
} from "generated";

const zeroAddress = "0x0000000000000000000000000000000000000000";

NftFactoryContract.SimpleNftCreated.loader(({ event, context }) => {
  context.contractRegistration.addSimpleNft(event.params.contractAddress);
});

NftFactoryContract.SimpleNftCreated.handler(({ event, context }) => {
  let nftCollection: NftCollectionEntity = {
    id: event.params.contractAddress,
    contractAddress: event.params.contractAddress,
    name: event.params.name,
    symbol: event.params.symbol,
    maxSupply: event.params.maxSupply,
    currentSupply: 0,
  };
  context.NftCollection.set(nftCollection);

  // context.EntityWithFields.set({ id: "testingBigDecimalWorks", bigDecimal: BigDecimal.fromFloat(123.456) })
});

SimpleNftContract.Transfer.loader(({ event, context }) => {
  context.User.load(event.params.from, {});
  context.User.load(event.params.to, {});
  context.NftCollection.load(event.srcAddress);
  context.Token.load(
    event.srcAddress.concat("-").concat(event.params.tokenId.toString()),
    {}
  );
});

SimpleNftContract.Transfer.handler(({ event, context }) => {
  let nftCollectionUpdated = context.NftCollection.get(event.srcAddress);
  let token = {
    id: event.srcAddress.concat("-").concat(event.params.tokenId.toString()),
    tokenId: event.params.tokenId,
    collection_id: event.srcAddress,
    owner_id: event.params.to,
  };
  if (nftCollectionUpdated) {
    let existingToken = context.Token.get(
      event.srcAddress.concat("-").concat(event.params.tokenId.toString())
    );
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
    let loadedUserFrom = context.User.get(event.params.from);
    let accountType: AccountType = "USER";
    let userFrom = {
      id: event.params.from,
      address: event.params.from,
      updatesCountOnUserForTesting:
        loadedUserFrom?.updatesCountOnUserForTesting || 0,
      gravatar_id: undefined,
      accountType
    };
    context.User.set(userFrom);
  }

  if (event.params.to !== zeroAddress) {
    let loadedUserTo = context.User.get(event.params.to);

    let userTo: UserEntity = {
      id: event.params.to,
      address: event.params.to,
      updatesCountOnUserForTesting:
        loadedUserTo?.updatesCountOnUserForTesting || 0,
      gravatar_id: undefined,
      accountType: "ADMIN"
    };
    context.User.set(userTo);
  }

  context.Token.set(token);
});
