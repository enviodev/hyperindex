/* TypeScript file generated from Envio.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {EffectContext as $$effectContext} from './Types.ts';

import type {Effect as $$effect} from './Types.ts';

import type {Logger as $$logger} from './Types.ts';

import type {S_t as RescriptSchema_S_t} from 'rescript-schema/RescriptSchema.gen';

import type {blockEvent as Internal_blockEvent} from './Internal.gen';

export type blockEvent = Internal_blockEvent;

export type onBlockArgs<context> = { readonly block: blockEvent; readonly context: context };

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
