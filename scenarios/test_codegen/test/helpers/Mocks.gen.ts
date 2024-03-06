/* TypeScript file generated from Mocks.res by genType. */

/* eslint-disable */
/* tslint:disable */

const MocksJS = require('./Mocks.bs.js');

export const eventNames: { readonly NftFactory_SimpleNftCreated: string } = MocksJS.eventNames as any;

export const mockRawEventRow: {
  readonly block_hash: string; 
  readonly block_number: number; 
  readonly block_timestamp: number; 
  readonly chain_id: number; 
  readonly event_id: number; 
  readonly event_type: string; 
  readonly log_index: number; 
  readonly params: {
    readonly baz: number; 
    readonly foo: string
  }; 
  readonly src_address: string; 
  readonly transaction_hash: string; 
  readonly transaction_index: number
} = MocksJS.mockRawEventRow as any;
