export type {
  logger as Logger,
  effect as Effect,
  effectContext as EffectContext,
  effectArgs as EffectArgs,
  effectOptions as EffectOptoins,
} from "./src/Envio.gen.ts";
export type { EffectCaller } from "./src/Types.ts";

import type {
  effect as Effect,
  effectArgs as EffectArgs,
} from "./src/Envio.gen.ts";

import * as Sury from "rescript-schema";

type UnknownToOutput<T> = T extends Sury.Schema<unknown>
  ? Sury.Output<T>
  : T extends {
      [k in keyof T]: unknown;
    }
  ? {
      [k in keyof T]: UnknownToOutput<T[k]>;
    }
  : T;

type UnknownToInput<T> = T extends Sury.Schema<unknown>
  ? Sury.Input<T>
  : T extends {
      [k in keyof T]: unknown;
    }
  ? {
      [k in keyof T]: UnknownToInput<T[k]>;
    }
  : T;

// All the type gymnastics with generics to be able to
// define schema without an additional `S.schema` call in TS:
// createEffect({
//   input: undefined,
// })
// Instead of:
// createEffect({
//   input: S.schema(undefined),
// })
// Or for objects:
// createEffect({
//   input: {
//     foo: S.string,
//   },
// })
// Instead of:
// createEffect({
//   input: S.schema({
//     foo: S.string,
//   }),
// })
// The behaviour is inspired by Sury code:
// https://github.com/DZakh/sury/blob/551f8ee32c1af95320936d00c086e5fb337f59fa/packages/sury/src/S.d.ts#L344C1-L355C50
export function experimental_createEffect<
  IS,
  OS,
  I = UnknownToInput<IS>,
  O = UnknownToOutput<OS>,
  // A hack to enforce that the inferred return type
  // matches the output schema type
  R extends O = O
>(
  options: {
    /** The name of the effect. Used for logging and debugging. */
    readonly name: string;
    /** The input schema of the effect. */
    readonly input: IS;
    /** The output schema of the effect. */
    readonly output: OS;
  },
  handler: (args: EffectArgs<I>) => Promise<R>
): Effect<I, O>;

// Important! Should match the index.js file
export declare namespace S {
  export type Schema<Output, Input = unknown> = Sury.Schema<Output, Input>;
  export const string: typeof Sury.string;
  export const jsonString: typeof Sury.jsonString;
  export const boolean: typeof Sury.boolean;
  export const int32: typeof Sury.int32;
  export const number: typeof Sury.number;
  export const bigint: typeof Sury.bigint;
  export const never: typeof Sury.never;
  export const union: typeof Sury.union;
  export const object: typeof Sury.object;
  // Might change in a near future
  // export const custom: typeof Sury.custom;
  // Don't expose recursive for now, since it's too advanced
  // export const recursive: typeof Sury.recursive;
  export const transform: typeof Sury.transform;
  export const refine: typeof Sury.refine;
  export const schema: typeof Sury.schema;
  export const record: typeof Sury.record;
  export const array: typeof Sury.array;
  export const tuple: typeof Sury.tuple;
  export const merge: typeof Sury.merge;
  export const optional: typeof Sury.optional;
  export const nullable: typeof Sury.nullable;
  // Nullish type will change in "sury@10"
  // export const nullish: typeof Sury.nullish;
  export const assertOrThrow: typeof Sury.assertOrThrow;
}
