/* TypeScript file generated from Envio.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {EffectContext as $$effectContext} from './Types.ts';

import type {Effect as $$effect} from './Types.ts';

import type {Logger as $$logger} from './Types.ts';

import type {S_t as RescriptSchema_S_t} from 'rescript-schema/RescriptSchema.gen';

export type logger = $$logger;

export type effect<input,output> = $$effect<input,output>;

export type effectOptions<input,output> = {
  /** The name of the effect. Used for logging and debugging. */
  readonly name: string; 
  /** The input schema of the effect. */
  readonly input: RescriptSchema_S_t<input>; 
  /** The output schema of the effect. */
  readonly output: RescriptSchema_S_t<output>; 
  /** Whether the effect should be cached. */
  readonly cache?: boolean
};

export type effectContext = $$effectContext;

export type effectArgs<input> = { readonly input: input; readonly context: effectContext };
