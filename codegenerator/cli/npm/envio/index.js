// This file is needed to have control over TS version exports
// Some parts like Sury reexport are impossible to implement
// on the JS side, so we need to do it here

import * as Sury from "rescript-schema";
import { schema as bigintSchema } from "./src/bindings/BigInt.res.mjs";
import { schema as bigDecimalSchema } from "./src/bindings/BigDecimal.res.mjs";

// Re-export everything from envioGen
export * from "./src/Envio.res.mjs";

// Important! Should match the index.d.ts file
export const S = {
  string: Sury.string,
  address: Sury.string,
  jsonString: Sury.jsonString,
  boolean: Sury.boolean,
  int32: Sury.int32,
  number: Sury.number,
  bigint: bigintSchema,
  never: Sury.never,
  union: Sury.union,
  object: Sury.object,
  // Might change in a near future
  // custom: Sury.custom,
  // Don't expose recursive for now, since it's too advanced
  // recursive: Sury.recursive,
  transform: Sury.transform,
  shape: Sury.shape,
  refine: Sury.refine,
  schema: Sury.schema,
  record: Sury.record,
  array: Sury.array,
  tuple: Sury.tuple,
  merge: Sury.merge,
  optional: Sury.optional,
  nullable: Sury.nullable,
  bigDecimal: bigDecimalSchema,
  // Nullish type will change in "sury@10"
  // nullish: Sury.nullish,
  assertOrThrow: Sury.assertOrThrow,
  parseOrThrow: Sury.parseOrThrow,
};
