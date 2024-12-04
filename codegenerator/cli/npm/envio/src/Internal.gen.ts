/* TypeScript file generated from Internal.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {t as Address_t} from './Address.gen';

export type genericEvent<params,transaction,block> = {
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

export type genericContractRegister<args> = (_1:args) => void;

export type genericHandlerArgs<event,context,loaderReturn> = {
  readonly event: event; 
  readonly context: context; 
  readonly loaderReturn: loaderReturn
};

export type genericHandler<args> = (_1:args) => Promise<void>;
