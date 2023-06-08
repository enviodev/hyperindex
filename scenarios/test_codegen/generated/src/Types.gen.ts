/* TypeScript file generated from Types.res by genType. */
/* eslint-disable import/first */


import type {BigInt_t as Ethers_BigInt_t} from '../src/bindings/Ethers.gen';

import type {ethAddress as Ethers_ethAddress} from '../src/bindings/Ethers.gen';

// tslint:disable-next-line:interface-over-type-literal
export type id = string;
export type Id = id;

// tslint:disable-next-line:interface-over-type-literal
export type userLoaderConfig = { readonly loadGravatar?: gravatarLoaderConfig; readonly loadTokens?: tokenLoaderConfig };

// tslint:disable-next-line:interface-over-type-literal
export type gravatarLoaderConfig = { readonly loadOwner?: userLoaderConfig };

// tslint:disable-next-line:interface-over-type-literal
export type nftcollectionLoaderConfig = boolean;

// tslint:disable-next-line:interface-over-type-literal
export type tokenLoaderConfig = { readonly loadCollection?: nftcollectionLoaderConfig; readonly loadOwner?: userLoaderConfig };

// tslint:disable-next-line:interface-over-type-literal
export type aLoaderConfig = { readonly loadB?: bLoaderConfig };

// tslint:disable-next-line:interface-over-type-literal
export type bLoaderConfig = { readonly loadA?: aLoaderConfig; readonly loadC?: cLoaderConfig };

// tslint:disable-next-line:interface-over-type-literal
export type cLoaderConfig = { readonly loadA?: aLoaderConfig };

// tslint:disable-next-line:interface-over-type-literal
export type userEntity = {
  readonly id: string; 
  readonly address: string; 
  readonly gravatar?: id; 
  readonly updatesCountOnUserForTesting: number; 
  readonly tokens: id[]
};

// tslint:disable-next-line:interface-over-type-literal
export type gravatarEntity = {
  readonly id: string; 
  readonly owner: id; 
  readonly displayName: string; 
  readonly imageUrl: string; 
  readonly updatesCount: Ethers_BigInt_t
};

// tslint:disable-next-line:interface-over-type-literal
export type nftcollectionEntity = {
  readonly id: string; 
  readonly contractAddress: string; 
  readonly name: string; 
  readonly symbol: string; 
  readonly maxSupply: Ethers_BigInt_t; 
  readonly currentSupply: number
};

// tslint:disable-next-line:interface-over-type-literal
export type tokenEntity = {
  readonly id: string; 
  readonly tokenId: Ethers_BigInt_t; 
  readonly collection: id; 
  readonly owner: id
};

// tslint:disable-next-line:interface-over-type-literal
export type aEntity = { readonly id: string; readonly b: id };

// tslint:disable-next-line:interface-over-type-literal
export type bEntity = {
  readonly id: string; 
  readonly a: id[]; 
  readonly c: id
};

// tslint:disable-next-line:interface-over-type-literal
export type cEntity = { readonly id: string; readonly a: id };

// tslint:disable-next-line:interface-over-type-literal
export type eventLog<a> = {
  readonly params: a; 
  readonly blockNumber: number; 
  readonly blockTimestamp: number; 
  readonly blockHash: string; 
  readonly srcAddress: Ethers_ethAddress; 
  readonly transactionHash: string; 
  readonly transactionIndex: number; 
  readonly logIndex: number
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_eventArgs = {
  readonly id: Ethers_BigInt_t; 
  readonly user: Ethers_ethAddress; 
  readonly contactDetails: [string, string]
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_userEntityHandlerContext = {
  readonly getGravatar: (_1:userEntity) => (null | undefined | gravatarEntity); 
  readonly getTokens: (_1:userEntity) => tokenEntity[]; 
  readonly insert: (_1:userEntity) => void; 
  readonly update: (_1:userEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_gravatarEntityHandlerContext = {
  readonly getOwner: (_1:gravatarEntity) => userEntity; 
  readonly insert: (_1:gravatarEntity) => void; 
  readonly update: (_1:gravatarEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_nftcollectionEntityHandlerContext = {
  readonly insert: (_1:nftcollectionEntity) => void; 
  readonly update: (_1:nftcollectionEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_tokenEntityHandlerContext = {
  readonly getCollection: (_1:tokenEntity) => nftcollectionEntity; 
  readonly getOwner: (_1:tokenEntity) => userEntity; 
  readonly insert: (_1:tokenEntity) => void; 
  readonly update: (_1:tokenEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_aEntityHandlerContext = {
  readonly testingA: () => (null | undefined | aEntity); 
  readonly getB: (_1:aEntity) => bEntity; 
  readonly insert: (_1:aEntity) => void; 
  readonly update: (_1:aEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_bEntityHandlerContext = {
  readonly getA: (_1:bEntity) => aEntity[]; 
  readonly getC: (_1:bEntity) => cEntity; 
  readonly insert: (_1:bEntity) => void; 
  readonly update: (_1:bEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_cEntityHandlerContext = {
  readonly getA: (_1:cEntity) => aEntity; 
  readonly insert: (_1:cEntity) => void; 
  readonly update: (_1:cEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_context = {
  readonly user: GravatarContract_TestEventEvent_userEntityHandlerContext; 
  readonly gravatar: GravatarContract_TestEventEvent_gravatarEntityHandlerContext; 
  readonly nftcollection: GravatarContract_TestEventEvent_nftcollectionEntityHandlerContext; 
  readonly token: GravatarContract_TestEventEvent_tokenEntityHandlerContext; 
  readonly a: GravatarContract_TestEventEvent_aEntityHandlerContext; 
  readonly b: GravatarContract_TestEventEvent_bEntityHandlerContext; 
  readonly c: GravatarContract_TestEventEvent_cEntityHandlerContext
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_aEntityLoaderContext = { readonly testingALoad: (_1:id, _2:{ readonly loaders?: aLoaderConfig }) => void };

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_contractRegistrations = {
  readonly addGravatar: (_1:Ethers_ethAddress) => void; 
  readonly addNftFactory: (_1:Ethers_ethAddress) => void; 
  readonly addSimpleNft: (_1:Ethers_ethAddress) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_TestEventEvent_loaderContext = { readonly contractRegistration: GravatarContract_TestEventEvent_contractRegistrations; readonly a: GravatarContract_TestEventEvent_aEntityLoaderContext };

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_eventArgs = {
  readonly id: Ethers_BigInt_t; 
  readonly owner: Ethers_ethAddress; 
  readonly displayName: string; 
  readonly imageUrl: string
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_userEntityHandlerContext = {
  readonly getGravatar: (_1:userEntity) => (null | undefined | gravatarEntity); 
  readonly getTokens: (_1:userEntity) => tokenEntity[]; 
  readonly insert: (_1:userEntity) => void; 
  readonly update: (_1:userEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_gravatarEntityHandlerContext = {
  readonly getOwner: (_1:gravatarEntity) => userEntity; 
  readonly insert: (_1:gravatarEntity) => void; 
  readonly update: (_1:gravatarEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_nftcollectionEntityHandlerContext = {
  readonly insert: (_1:nftcollectionEntity) => void; 
  readonly update: (_1:nftcollectionEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_tokenEntityHandlerContext = {
  readonly getCollection: (_1:tokenEntity) => nftcollectionEntity; 
  readonly getOwner: (_1:tokenEntity) => userEntity; 
  readonly insert: (_1:tokenEntity) => void; 
  readonly update: (_1:tokenEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_aEntityHandlerContext = {
  readonly getB: (_1:aEntity) => bEntity; 
  readonly insert: (_1:aEntity) => void; 
  readonly update: (_1:aEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_bEntityHandlerContext = {
  readonly getA: (_1:bEntity) => aEntity[]; 
  readonly getC: (_1:bEntity) => cEntity; 
  readonly insert: (_1:bEntity) => void; 
  readonly update: (_1:bEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_cEntityHandlerContext = {
  readonly getA: (_1:cEntity) => aEntity; 
  readonly insert: (_1:cEntity) => void; 
  readonly update: (_1:cEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_context = {
  readonly user: GravatarContract_NewGravatarEvent_userEntityHandlerContext; 
  readonly gravatar: GravatarContract_NewGravatarEvent_gravatarEntityHandlerContext; 
  readonly nftcollection: GravatarContract_NewGravatarEvent_nftcollectionEntityHandlerContext; 
  readonly token: GravatarContract_NewGravatarEvent_tokenEntityHandlerContext; 
  readonly a: GravatarContract_NewGravatarEvent_aEntityHandlerContext; 
  readonly b: GravatarContract_NewGravatarEvent_bEntityHandlerContext; 
  readonly c: GravatarContract_NewGravatarEvent_cEntityHandlerContext
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_contractRegistrations = {
  readonly addGravatar: (_1:Ethers_ethAddress) => void; 
  readonly addNftFactory: (_1:Ethers_ethAddress) => void; 
  readonly addSimpleNft: (_1:Ethers_ethAddress) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_NewGravatarEvent_loaderContext = { readonly contractRegistration: GravatarContract_NewGravatarEvent_contractRegistrations };

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_eventArgs = {
  readonly id: Ethers_BigInt_t; 
  readonly owner: Ethers_ethAddress; 
  readonly displayName: string; 
  readonly imageUrl: string
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_userEntityHandlerContext = {
  readonly getGravatar: (_1:userEntity) => (null | undefined | gravatarEntity); 
  readonly getTokens: (_1:userEntity) => tokenEntity[]; 
  readonly insert: (_1:userEntity) => void; 
  readonly update: (_1:userEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_gravatarEntityHandlerContext = {
  readonly gravatarWithChanges: () => (null | undefined | gravatarEntity); 
  readonly getOwner: (_1:gravatarEntity) => userEntity; 
  readonly insert: (_1:gravatarEntity) => void; 
  readonly update: (_1:gravatarEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_nftcollectionEntityHandlerContext = {
  readonly insert: (_1:nftcollectionEntity) => void; 
  readonly update: (_1:nftcollectionEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_tokenEntityHandlerContext = {
  readonly getCollection: (_1:tokenEntity) => nftcollectionEntity; 
  readonly getOwner: (_1:tokenEntity) => userEntity; 
  readonly insert: (_1:tokenEntity) => void; 
  readonly update: (_1:tokenEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_aEntityHandlerContext = {
  readonly getB: (_1:aEntity) => bEntity; 
  readonly insert: (_1:aEntity) => void; 
  readonly update: (_1:aEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_bEntityHandlerContext = {
  readonly getA: (_1:bEntity) => aEntity[]; 
  readonly getC: (_1:bEntity) => cEntity; 
  readonly insert: (_1:bEntity) => void; 
  readonly update: (_1:bEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_cEntityHandlerContext = {
  readonly getA: (_1:cEntity) => aEntity; 
  readonly insert: (_1:cEntity) => void; 
  readonly update: (_1:cEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_context = {
  readonly user: GravatarContract_UpdatedGravatarEvent_userEntityHandlerContext; 
  readonly gravatar: GravatarContract_UpdatedGravatarEvent_gravatarEntityHandlerContext; 
  readonly nftcollection: GravatarContract_UpdatedGravatarEvent_nftcollectionEntityHandlerContext; 
  readonly token: GravatarContract_UpdatedGravatarEvent_tokenEntityHandlerContext; 
  readonly a: GravatarContract_UpdatedGravatarEvent_aEntityHandlerContext; 
  readonly b: GravatarContract_UpdatedGravatarEvent_bEntityHandlerContext; 
  readonly c: GravatarContract_UpdatedGravatarEvent_cEntityHandlerContext
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_gravatarEntityLoaderContext = { readonly gravatarWithChangesLoad: (_1:id, _2:{ readonly loaders?: gravatarLoaderConfig }) => void };

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_contractRegistrations = {
  readonly addGravatar: (_1:Ethers_ethAddress) => void; 
  readonly addNftFactory: (_1:Ethers_ethAddress) => void; 
  readonly addSimpleNft: (_1:Ethers_ethAddress) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type GravatarContract_UpdatedGravatarEvent_loaderContext = { readonly contractRegistration: GravatarContract_UpdatedGravatarEvent_contractRegistrations; readonly gravatar: GravatarContract_UpdatedGravatarEvent_gravatarEntityLoaderContext };

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_eventArgs = {
  readonly name: string; 
  readonly symbol: string; 
  readonly maxSupply: Ethers_BigInt_t; 
  readonly contractAddress: Ethers_ethAddress
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_userEntityHandlerContext = {
  readonly getGravatar: (_1:userEntity) => (null | undefined | gravatarEntity); 
  readonly getTokens: (_1:userEntity) => tokenEntity[]; 
  readonly insert: (_1:userEntity) => void; 
  readonly update: (_1:userEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_gravatarEntityHandlerContext = {
  readonly getOwner: (_1:gravatarEntity) => userEntity; 
  readonly insert: (_1:gravatarEntity) => void; 
  readonly update: (_1:gravatarEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_nftcollectionEntityHandlerContext = {
  readonly insert: (_1:nftcollectionEntity) => void; 
  readonly update: (_1:nftcollectionEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_tokenEntityHandlerContext = {
  readonly getCollection: (_1:tokenEntity) => nftcollectionEntity; 
  readonly getOwner: (_1:tokenEntity) => userEntity; 
  readonly insert: (_1:tokenEntity) => void; 
  readonly update: (_1:tokenEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_aEntityHandlerContext = {
  readonly getB: (_1:aEntity) => bEntity; 
  readonly insert: (_1:aEntity) => void; 
  readonly update: (_1:aEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_bEntityHandlerContext = {
  readonly getA: (_1:bEntity) => aEntity[]; 
  readonly getC: (_1:bEntity) => cEntity; 
  readonly insert: (_1:bEntity) => void; 
  readonly update: (_1:bEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_cEntityHandlerContext = {
  readonly getA: (_1:cEntity) => aEntity; 
  readonly insert: (_1:cEntity) => void; 
  readonly update: (_1:cEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_context = {
  readonly user: NftFactoryContract_SimpleNftCreatedEvent_userEntityHandlerContext; 
  readonly gravatar: NftFactoryContract_SimpleNftCreatedEvent_gravatarEntityHandlerContext; 
  readonly nftcollection: NftFactoryContract_SimpleNftCreatedEvent_nftcollectionEntityHandlerContext; 
  readonly token: NftFactoryContract_SimpleNftCreatedEvent_tokenEntityHandlerContext; 
  readonly a: NftFactoryContract_SimpleNftCreatedEvent_aEntityHandlerContext; 
  readonly b: NftFactoryContract_SimpleNftCreatedEvent_bEntityHandlerContext; 
  readonly c: NftFactoryContract_SimpleNftCreatedEvent_cEntityHandlerContext
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_contractRegistrations = {
  readonly addGravatar: (_1:Ethers_ethAddress) => void; 
  readonly addNftFactory: (_1:Ethers_ethAddress) => void; 
  readonly addSimpleNft: (_1:Ethers_ethAddress) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type NftFactoryContract_SimpleNftCreatedEvent_loaderContext = { readonly contractRegistration: NftFactoryContract_SimpleNftCreatedEvent_contractRegistrations };

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_eventArgs = {
  readonly from: Ethers_ethAddress; 
  readonly to: Ethers_ethAddress; 
  readonly tokenId: Ethers_BigInt_t
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_userEntityHandlerContext = {
  readonly userFrom: () => (null | undefined | userEntity); 
  readonly userTo: () => (null | undefined | userEntity); 
  readonly getGravatar: (_1:userEntity) => (null | undefined | gravatarEntity); 
  readonly getTokens: (_1:userEntity) => tokenEntity[]; 
  readonly insert: (_1:userEntity) => void; 
  readonly update: (_1:userEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_gravatarEntityHandlerContext = {
  readonly getOwner: (_1:gravatarEntity) => userEntity; 
  readonly insert: (_1:gravatarEntity) => void; 
  readonly update: (_1:gravatarEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_nftcollectionEntityHandlerContext = {
  readonly nftCollectionUpdated: () => (null | undefined | nftcollectionEntity); 
  readonly insert: (_1:nftcollectionEntity) => void; 
  readonly update: (_1:nftcollectionEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_tokenEntityHandlerContext = {
  readonly existingTransferredToken: () => (null | undefined | tokenEntity); 
  readonly getCollection: (_1:tokenEntity) => nftcollectionEntity; 
  readonly getOwner: (_1:tokenEntity) => userEntity; 
  readonly insert: (_1:tokenEntity) => void; 
  readonly update: (_1:tokenEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_aEntityHandlerContext = {
  readonly getB: (_1:aEntity) => bEntity; 
  readonly insert: (_1:aEntity) => void; 
  readonly update: (_1:aEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_bEntityHandlerContext = {
  readonly getA: (_1:bEntity) => aEntity[]; 
  readonly getC: (_1:bEntity) => cEntity; 
  readonly insert: (_1:bEntity) => void; 
  readonly update: (_1:bEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_cEntityHandlerContext = {
  readonly getA: (_1:cEntity) => aEntity; 
  readonly insert: (_1:cEntity) => void; 
  readonly update: (_1:cEntity) => void; 
  readonly delete: (_1:id) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_context = {
  readonly user: SimpleNftContract_TransferEvent_userEntityHandlerContext; 
  readonly gravatar: SimpleNftContract_TransferEvent_gravatarEntityHandlerContext; 
  readonly nftcollection: SimpleNftContract_TransferEvent_nftcollectionEntityHandlerContext; 
  readonly token: SimpleNftContract_TransferEvent_tokenEntityHandlerContext; 
  readonly a: SimpleNftContract_TransferEvent_aEntityHandlerContext; 
  readonly b: SimpleNftContract_TransferEvent_bEntityHandlerContext; 
  readonly c: SimpleNftContract_TransferEvent_cEntityHandlerContext
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_userEntityLoaderContext = { readonly userFromLoad: (_1:id, _2:{ readonly loaders?: userLoaderConfig }) => void; readonly userToLoad: (_1:id, _2:{ readonly loaders?: userLoaderConfig }) => void };

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_nftcollectionEntityLoaderContext = { readonly nftCollectionUpdatedLoad: (_1:id) => void };

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_tokenEntityLoaderContext = { readonly existingTransferredTokenLoad: (_1:id, _2:{ readonly loaders?: tokenLoaderConfig }) => void };

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_contractRegistrations = {
  readonly addGravatar: (_1:Ethers_ethAddress) => void; 
  readonly addNftFactory: (_1:Ethers_ethAddress) => void; 
  readonly addSimpleNft: (_1:Ethers_ethAddress) => void
};

// tslint:disable-next-line:interface-over-type-literal
export type SimpleNftContract_TransferEvent_loaderContext = {
  readonly contractRegistration: SimpleNftContract_TransferEvent_contractRegistrations; 
  readonly user: SimpleNftContract_TransferEvent_userEntityLoaderContext; 
  readonly nftcollection: SimpleNftContract_TransferEvent_nftcollectionEntityLoaderContext; 
  readonly token: SimpleNftContract_TransferEvent_tokenEntityLoaderContext
};
