/* 
Reexport the types to keep backward compatibility
*/

/* eslint-disable */
/* tslint:disable */

import type { t as Address_t } from "envio/src/Address.gen";
export type {
  Addresses_mockAddresses,
  Addresses_defaultAddress,
  Addresses,
} from "envio/src/bindings/Ethers.gen";

export type ethAddress = Address_t;
