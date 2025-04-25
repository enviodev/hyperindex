/* TypeScript file generated from Envio.res by genType. */

/* eslint-disable */
/* tslint:disable */

import type {EffectContext as $$effectContext} from './Types.ts';

import type {Effect as $$effect} from './Types.ts';

import type {Logger as $$logger} from './Types.ts';

export type logger = $$logger;

export type effect<input,output> = $$effect<input,output>;

export type effectOptions<input,output> = { 
/** The name of the effect. Used for logging and debugging. */
readonly name: string; 
/** The handler function that will be called when the effect is executed. */
readonly handler: (_1:effectArgs<input>) => Promise<output> };

export type effectContext = $$effectContext;

export type effectArgs<input> = { readonly input: input; readonly context: effectContext };
