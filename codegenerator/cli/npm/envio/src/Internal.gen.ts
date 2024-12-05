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
