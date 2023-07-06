import {
  NftFactoryContract_SimpleNftCreated_loader,
  NftFactoryContract_SimpleNftCreated_handler,
  SimpleNftContract_Transfer_loader,
  SimpleNftContract_Transfer_handler
} from "../generated/src/Handlers.gen";

import {
  nftcollectionEntity,
  tokenEntity,
  userEntity,
} from "../generated/src/Types.gen";

const zeroAddress = "0x0000000000000000000000000000000000000000";

NftFactoryContract_SimpleNftCreated_loader(
  ({ event, context }) => {
    context.contractRegistration.addSimpleNft(event.params.contractAddress)
  }
);

NftFactoryContract_SimpleNftCreated_handler(({ event, context }) => {
  let nftCollection: nftcollectionEntity = {
    id: event.params.contractAddress,
    contractAddress: event.params.contractAddress,
    name: event.params.name,
    symbol: event.params.symbol,
    maxSupply: event.params.maxSupply,
    currentSupply: 0,
  };
  context.nftcollection.set(nftCollection);
});

SimpleNftContract_Transfer_loader(({ event, context }) => {
  context.user.userFromLoad(event.params.from, {});
  context.user.userToLoad(event.params.to, {});
  context.nftcollection.nftCollectionUpdatedLoad(event.srcAddress);
  context.token.existingTransferredTokenLoad(
    event.srcAddress.concat("-").concat(event.params.tokenId.toString())
    , {}
  );
});

SimpleNftContract_Transfer_handler(({ event, context }) => {
  let nftCollectionUpdated = context.nftcollection.nftCollectionUpdated();
  let token = {
    id: event.srcAddress.concat("-").concat(event.params.tokenId.toString()),
    tokenId: event.params.tokenId,
    collection: event.srcAddress,
    owner: event.params.to,
  };
  if (nftCollectionUpdated) {
    let existingToken = context.token.existingTransferredToken();
    if (!existingToken) {
      let currentSupply = Number(nftCollectionUpdated.currentSupply) + 1;

      let nftCollection: nftcollectionEntity = {
        ...nftCollectionUpdated,
        currentSupply,
      };
      context.nftcollection.set(nftCollection);
    }
  } else {
    console.log(
      "Issue with events emitted, unregistered NFT collection transfer"
    );
    return;
  }

  if (event.params.from !== zeroAddress) {
    let loadedUserFrom = context.user.userFrom();
    let userFromTokensOpt: Array<string> = loadedUserFrom?.tokens ?? [];
    let userFromTokens: Array<string> = [];
    if (typeof userFromTokensOpt !== "string") {
      userFromTokens.concat(userFromTokensOpt);
    }
    let index = userFromTokens.indexOf(token.id, 0);
    if (index > -1) {
      userFromTokens.splice(index, 1);
    }

    let userFrom = {
      id: event.params.from,
      address: event.params.from,
      tokens: userFromTokens,
      updatesCountOnUserForTesting: loadedUserFrom?.updatesCountOnUserForTesting || 0
    };
    context.user.set(userFrom);
  }

  if (event.params.to !== zeroAddress) {
    let loadedUserTo = context.user.userTo();

    let userToTokensOpt: Array<string> = loadedUserTo?.tokens ?? [];
    let userToTokens: Array<string> = [token.id];

    if (typeof userToTokensOpt !== "string") {
      userToTokens.concat(userToTokensOpt);
    }

    let userTo: userEntity = {
      id: event.params.to,
      address: event.params.to,
      tokens: userToTokens,
      updatesCountOnUserForTesting: loadedUserTo?.updatesCountOnUserForTesting || 0
    };
    context.user.set(userTo);
  }

  context.token.set(token);
});
