/* TypeScript file generated from HyperSyncClient.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {t as Address_t} from '../../src/Address.gen';

export type ResponseTypes_accessList = { readonly address?: Address_t; readonly storageKeys?: string[] };

export type ResponseTypes_authorizationList = {
  readonly chainId: bigint; 
  readonly address: Address_t; 
  readonly nonce: number; 
  readonly yParity: 
    1
  | 0; 
  readonly r: string; 
  readonly s: string
};
