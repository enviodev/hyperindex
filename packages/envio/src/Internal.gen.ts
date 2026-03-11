/* TypeScript file generated from Internal.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {GenericContractRegister as $$genericContractRegister} from './Types.ts';

import type {Invalid as $$noEventFilters} from './Types.ts';

import type {ResponseTypes_accessList as HyperSyncClient_ResponseTypes_accessList} from '../src/sources/HyperSyncClient.gen.js';

import type {ResponseTypes_authorizationList as HyperSyncClient_ResponseTypes_authorizationList} from '../src/sources/HyperSyncClient.gen.js';

import type {t as Address_t} from './Address.gen.js';

export type evmTransactionFields = {
  readonly transactionIndex?: number; 
  readonly hash?: string; 
  readonly from?: (undefined | Address_t); 
  readonly to?: (undefined | Address_t); 
  readonly gas?: bigint; 
  readonly gasPrice?: (undefined | bigint); 
  readonly input?: string; 
  readonly nonce?: bigint; 
  readonly value?: bigint; 
  readonly v?: (undefined | string); 
  readonly r?: (undefined | string); 
  readonly s?: (undefined | string); 
  readonly yParity?: (undefined | string); 
  readonly maxPriorityFeePerGas?: (undefined | bigint); 
  readonly maxFeePerGas?: (undefined | bigint); 
  readonly maxFeePerBlobGas?: (undefined | bigint); 
  readonly blobVersionedHashes?: (undefined | string[]); 
  readonly cumulativeGasUsed?: bigint; 
  readonly effectiveGasPrice?: bigint; 
  readonly gasUsed?: bigint; 
  readonly contractAddress?: (undefined | Address_t); 
  readonly logsBloom?: string; 
  readonly type: (undefined | (undefined | number)); 
  readonly root?: (undefined | string); 
  readonly status?: (undefined | number); 
  readonly l1Fee?: (undefined | bigint); 
  readonly l1GasPrice?: (undefined | bigint); 
  readonly l1GasUsed?: (undefined | bigint); 
  readonly l1FeeScalar?: (undefined | number); 
  readonly gasUsedForL1?: (undefined | bigint); 
  readonly accessList?: (undefined | HyperSyncClient_ResponseTypes_accessList[]); 
  readonly authorizationList?: (undefined | HyperSyncClient_ResponseTypes_authorizationList[])
};

export type genericEvent<params,block,transaction> = {
  readonly params: params; 
  readonly chainId: number; 
  readonly srcAddress: Address_t; 
  readonly logIndex: number; 
  readonly transaction: transaction; 
  readonly block: block
};

export type genericLoaderArgs<event,context> = { readonly event: event; readonly context: context };

export type genericLoader<args,loaderReturn> = (_1:args) => Promise<loaderReturn>;

export type genericContractRegisterArgs<event,context> = { readonly event: event; readonly context: context };

export type genericContractRegister<args> = $$genericContractRegister<args>;

export type genericHandlerArgs<event,context> = { readonly event: event; readonly context: context };

export type genericHandler<args> = (_1:args) => Promise<void>;

export type entityHandlerContext<entity> = {
  readonly get: (_1:string) => Promise<(undefined | entity)>; 
  readonly getOrThrow: (_1:string, message:(undefined | string)) => Promise<entity>; 
  readonly getOrCreate: (_1:entity) => Promise<entity>; 
  readonly set: (_1:entity) => void; 
  readonly deleteUnsafe: (_1:string) => void
};

export type genericHandlerWithLoader<loader,handler,eventFilters> = {
  readonly loader: loader; 
  readonly handler: handler; 
  readonly wildcard?: boolean; 
  readonly eventFilters?: eventFilters
};

export abstract class fuelEventConfig { protected opaque!: any }; /* simulate opaque types */

export abstract class evmEventConfig { protected opaque!: any }; /* simulate opaque types */

export type eventOptions<eventFilters> = { readonly wildcard?: boolean; readonly eventFilters?: eventFilters };

export type fuelSupplyParams = { readonly subId: string; readonly amount: bigint };

export type fuelTransferParams = {
  readonly to: Address_t; 
  readonly assetId: string; 
  readonly amount: bigint
};

export type noEventFilters = $$noEventFilters;
