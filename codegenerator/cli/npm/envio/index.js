// This file is needed to have control over TS version exports
// Some parts like rescript-schema reexport are impossible to implement
// on the JS side, so we need to do it here

import * as RescriptSchema from "rescript-schema";
import { $$BigInt } from "./src/Utils.res.mjs";
import { schema as bigDecimalSchema } from "./src/bindings/BigDecimal.res.mjs";

// Re-export everything from envioGen
export * from "./src/Envio.res.mjs";

// Important! Should match the index.d.ts file
export const S = {
  string: RescriptSchema.string,
  address: RescriptSchema.string,
  evmChainId: RescriptSchema.number,
  fuelChainId: RescriptSchema.number,
  svmChainId: RescriptSchema.number,
  jsonString: RescriptSchema.jsonString,
  boolean: RescriptSchema.boolean,
  int32: RescriptSchema.int32,
  number: RescriptSchema.number,
  bigint: $$BigInt.schema,
  never: RescriptSchema.never,
  union: RescriptSchema.union,
  object: RescriptSchema.object,
  // Might change in a near future
  // custom: RescriptSchema.custom,
  // Don't expose recursive for now, since it's too advanced
  // recursive: RescriptSchema.recursive,
  transform: RescriptSchema.transform,
  shape: RescriptSchema.shape,
  refine: RescriptSchema.refine,
  schema: RescriptSchema.schema,
  record: RescriptSchema.record,
  array: RescriptSchema.array,
  tuple: RescriptSchema.tuple,
  merge: RescriptSchema.merge,
  optional: RescriptSchema.optional,
  nullable: RescriptSchema.nullable,
  bigDecimal: bigDecimalSchema,
  assertOrThrow: RescriptSchema.assertOrThrow,
  parseOrThrow: RescriptSchema.parseOrThrow,
};
