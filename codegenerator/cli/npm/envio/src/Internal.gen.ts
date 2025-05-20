/* TypeScript file generated from Internal.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {GenericContractRegister as $$genericContractRegister} from './Types.ts';

import type {Invalid as $$noEventFilters} from './Types.ts';

import type {t as Address_t} from './Address.gen';

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

export type genericHandlerArgs<event,context,loaderReturn> = {
  readonly event: event; 
  readonly context: context; 
  readonly loaderReturn: loaderReturn
};

export type genericHandler<args> = (_1:args) => Promise<void>;

export type genericHandlerWithLoader<loader,handler,eventFilters> = {
  readonly loader: loader; 
  readonly handler: handler; 
  readonly wildcard?: boolean; 
  readonly eventFilters?: eventFilters; 
  /** @deprecated The option is removed starting from v2.19 since we made the default mode even faster than pre-registration. */
  readonly preRegisterDynamicContracts?: boolean
};

export type fuelSupplyParams = { readonly subId: string; readonly amount: bigint };

export type fuelTransferParams = {
  readonly to: Address_t; 
  readonly assetId: string; 
  readonly amount: bigint
};

export type noEventFilters = $$noEventFilters;
