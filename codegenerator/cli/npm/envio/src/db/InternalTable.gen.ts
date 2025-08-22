/* TypeScript file generated from InternalTable.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {Json_t as Js_Json_t} from './Js.gen';

import type {t as Address_t} from '../../src/Address.gen';

export type EventSyncState_t = {
  readonly chain_id: number; 
  readonly block_number: number; 
  readonly log_index: number; 
  readonly block_timestamp: number
};

export type ChainMetadata_t = {
  readonly chain_id: number; 
  readonly start_block: number; 
  readonly end_block: (undefined | number); 
  readonly block_height: number; 
  readonly first_event_block_number: (undefined | number); 
  readonly latest_processed_block: (undefined | number); 
  readonly num_events_processed: (undefined | number); 
  readonly is_hyper_sync: boolean; 
  readonly num_batches_fetched: number; 
  readonly latest_fetched_block_number: number; 
  readonly timestamp_caught_up_to_head_or_endblock: Date
};

export type PersistedState_t = {
  readonly id: number; 
  readonly envio_version: string; 
  readonly config_hash: string; 
  readonly schema_hash: string; 
  readonly handler_files_hash: string; 
  readonly abi_files_hash: string
};

export type EndOfBlockRangeScannedData_t = {
  readonly chain_id: number; 
  readonly block_number: number; 
  readonly block_hash: string
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
  readonly block_fields: Js_Json_t; 
  readonly transaction_fields: Js_Json_t; 
  readonly params: Js_Json_t
};

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
