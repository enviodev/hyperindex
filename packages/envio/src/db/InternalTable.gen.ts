/* TypeScript file generated from InternalTable.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {t as Address_t} from '../../src/Address.gen.js';

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

export type RawEvents_t = {
  readonly chain_id: number; 
  readonly event_id: bigint; 
  readonly event_name: string; 
  readonly contract_name: string; 
  readonly block_number: number; 
  readonly log_index: number; 
  readonly src_address: Address_t; 
  readonly block_hash: string; 
  readonly block_timestamp: number; 
  readonly block_fields: unknown; 
  readonly transaction_fields: unknown; 
  readonly params: unknown
};
