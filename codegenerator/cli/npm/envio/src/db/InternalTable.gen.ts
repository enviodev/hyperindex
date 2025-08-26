/* TypeScript file generated from InternalTable.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {Json_t as Js_Json_t} from './Js.gen';

import type {t as Address_t} from '../../src/Address.gen';

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
  readonly block_fields: Js_Json_t; 
  readonly transaction_fields: Js_Json_t; 
  readonly params: Js_Json_t
};
