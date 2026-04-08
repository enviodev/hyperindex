/* TypeScript file generated from Envio.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {EffectContext as $$effectContext} from './Types.ts';

import type {Effect as $$effect} from './Types.ts';

import type {Logger as $$logger} from './Types.ts';

import type {S_t as RescriptSchema_S_t} from 'rescript-schema/RescriptSchema.gen.js';

export type blockEvent = { readonly number: number };

export type fuelBlockEvent = { readonly height: number };

export type svmOnBlockArgs<context> = { readonly slot: number; readonly context: context };

export type onBlockArgs<block,context> = { readonly block: block; readonly context: context };

export type onBlockNumberFilter = {
  readonly _gte?: number; 
  readonly _lte?: number; 
  /** Match every Nth block relative to _gte (or chain startBlock). */
  readonly _every?: number
};

export type onBlockBlockFilter = { readonly number?: onBlockNumberFilter };

export type onBlockFilter = { readonly block?: onBlockBlockFilter };

export type onBlockWhereResult = boolean | onBlockFilter;

export type onBlockWhereArgs<chain> = { readonly chain: chain };

export type onBlockOptions<chain> = { readonly name: string; readonly where?: (_1:onBlockWhereArgs<chain>) => onBlockWhereResult };

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
