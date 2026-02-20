/* TypeScript file generated from Config.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {t as Address_t} from './Address.gen.js';

export type DynamicContractRegistry_t = {
  readonly id: string; 
  readonly chain_id: number; 
  readonly registering_event_block_number: number; 
  readonly registering_event_log_index: number; 
  readonly registering_event_block_timestamp: number; 
  readonly registering_event_contract_name: string; 
  readonly registering_event_name: string; 
  readonly registering_event_src_address: Address_t; 
  readonly contract_address: Address_t; 
  readonly contract_name: string
};
