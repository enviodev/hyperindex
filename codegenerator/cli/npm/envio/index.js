// This file is needed to have control over TS version exports
// Some parts like Sury reexport are impossible to implement
// on the JS side, so we need to do it here

const envioGen = require("./src/Envio.bs.js");
Object.assign(exports, envioGen);

const Sury = require("rescript-schema");
// Important! Should match the index.d.ts file
exports.S = {
  string: Sury.string,
  jsonString: Sury.jsonString,
  boolean: Sury.boolean,
  int32: Sury.int32,
  number: Sury.number,
  bigint: Sury.bigint,
  never: Sury.never,
  union: Sury.union,
  object: Sury.object,
  // Might change in a near future
  // custom: Sury.custom,
  // Don't expose recursive for now, since it's too advanced
  // recursive: Sury.recursive,
  transform: Sury.transform,
  refine: Sury.refine,
  schema: Sury.schema,
  record: Sury.record,
  array: Sury.array,
  tuple: Sury.tuple,
  merge: Sury.merge,
  optional: Sury.optional,
  nullable: Sury.nullable,
  // Nullish type will change in "sury@10"
  // nullish: Sury.nullish,
  assertOrThrow: Sury.assertOrThrow,
};
