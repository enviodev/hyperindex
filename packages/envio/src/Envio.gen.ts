/* TypeScript file generated from Envio.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {EffectContext as $$effectContext} from './Types.ts';

import type {Effect as $$effect} from './Types.ts';

import type {Logger as $$logger} from './Types.ts';

import type {S_t as RescriptSchema_S_t} from 'rescript-schema/RescriptSchema.gen.js';

import type {evmTransactionFields as Internal_evmTransactionFields} from './Internal.gen.js';

import type {t as Address_t} from './Address.gen.js';

export type blockEvent = { readonly number: number };

export type fuelBlockEvent = { readonly height: number };

/** EVM block data. `number`, `timestamp`, and `hash` are always available.
    Other fields require `field_selection` configuration in config.yaml. */
export type evmBlock = {
  /** The block number (height) in the chain. Always available. */
  readonly number: number; 
  /** The unix timestamp of when the block was mined. Always available. */
  readonly timestamp: number; 
  /** The hash of the block. Always available. */
  readonly hash: string; 
  /** The hash of the parent block. */
  readonly parentHash: string; 
  /** The nonce of the block, used in proof-of-work. None for proof-of-stake blocks. */
  readonly nonce: (undefined | bigint); 
  /** The SHA3 hash of the uncles data in the block. */
  readonly sha3Uncles: string; 
  /** The bloom filter for the logs of the block. */
  readonly logsBloom: string; 
  /** The root of the transaction trie of the block. */
  readonly transactionsRoot: string; 
  /** The root of the state trie of the block. */
  readonly stateRoot: string; 
  /** The root of the receipts trie of the block. */
  readonly receiptsRoot: string; 
  /** The address of the miner/validator who mined this block. */
  readonly miner: Address_t; 
  /** The difficulty for this block. None for proof-of-stake blocks. */
  readonly difficulty: (undefined | bigint); 
  /** The total difficulty of the chain until this block. None for proof-of-stake blocks. */
  readonly totalDifficulty: (undefined | bigint); 
  /** The extra data included in the block by the miner. */
  readonly extraData: string; 
  /** The size of this block in bytes. */
  readonly size: bigint; 
  /** The maximum gas allowed in this block. */
  readonly gasLimit: bigint; 
  /** The total gas used by all transactions in this block. */
  readonly gasUsed: bigint; 
  /** The list of uncle block hashes. */
  readonly uncles: (undefined | string[]); 
  /** The base fee per gas in this block (EIP-1559). None for pre-London blocks. */
  readonly baseFeePerGas: (undefined | bigint); 
  /** The total amount of blob gas consumed by transactions in this block (EIP-4844). */
  readonly blobGasUsed: (undefined | bigint); 
  /** The running total of blob gas consumed in excess of the target (EIP-4844). */
  readonly excessBlobGas: (undefined | bigint); 
  /** The root hash of the parent beacon block (EIP-4788). */
  readonly parentBeaconBlockRoot: (undefined | string); 
  /** The root hash of the withdrawals trie (EIP-4895). */
  readonly withdrawalsRoot: (undefined | string); 
  /** The L1 block number associated with this L2 block (L2 chains only). */
  readonly l1BlockNumber: (undefined | number); 
  /** The number of messages sent in this block (Arbitrum). */
  readonly sendCount: (undefined | string); 
  /** The Merkle root of the outbox messages (Arbitrum). */
  readonly sendRoot: (undefined | string); 
  /** The mix hash used in proof-of-work. */
  readonly mixHash: (undefined | string)
};

/** EVM transaction data. All fields require `field_selection` configuration. */
export type evmTransaction = Internal_evmTransactionFields;

/** Fuel block data. */
export type fuelBlock = {
  /** The unique identifier of the block. */
  readonly id: string; 
  /** The block height (number). */
  readonly height: number; 
  /** The unix timestamp of the block. */
  readonly time: number
};

/** Fuel transaction data. */
export type fuelTransaction = { 
/** The unique identifier of the transaction. */
readonly id: string };

export type svmOnBlockArgs<context> = { readonly slot: number; readonly context: context };

export type onBlockArgs<block,context> = { readonly block: block; readonly context: context };

export type onBlockOptions<chain> = {
  readonly name: string; 
  readonly chain: chain; 
  readonly interval?: number; 
  readonly startBlock?: number; 
  readonly endBlock?: number
};

export type logger = $$logger;

export type effect<input,output> = $$effect<input,output>;

export type rateLimitDuration = "second" | "minute" | number;

export type rateLimit = 
    false
  | { readonly calls: number; readonly per: rateLimitDuration };

export type effectOptions<input,output> = {
  /** The name of the effect. Used for logging and debugging. */
  readonly name: string; 
  /** The input schema of the effect. */
  readonly input: RescriptSchema_S_t<input>; 
  /** The output schema of the effect. */
  readonly output: RescriptSchema_S_t<output>; 
  /** Rate limit for the effect. Set to false to disable or provide {calls: number, per: "second" | "minute"} to enable. */
  readonly rateLimit: rateLimit; 
  /** Whether the effect should be cached. */
  readonly cache?: boolean
};

export type effectContext = $$effectContext;

export type effectArgs<input> = { readonly input: input; readonly context: effectContext };
