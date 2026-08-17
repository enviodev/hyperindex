/**
 * Comparison operands against array-typed columns, and the parse/validation
 * errors they produce. Found by `fuzz.ts` — the hand-written where-matrix
 * crosses operators with scalar columns, and never crossed them with the
 * array columns, where the operand rules are completely different.
 *
 * Hasura parses an array operand with aeson, which demands a real array. The
 * rules that fall out, each pinned below:
 *
 *   [a, b]   coerce elementwise; a null element is legal and becomes NULL
 *            inside the array literal. An element that fails to parse is
 *            reported at the operand's own path, NOT at an element index.
 *   "text"   strings and enum literals pass through opaquely as the array
 *            literal, so a bad one fails in Postgres as data-exception,
 *            not at validation.
 *   null     "unexpected null value for type '<element>'" — the element
 *            type's name, not the list's.
 *   1/true/{} "parsing [] failed, expected Array, but encountered <Kind>".
 *
 * `_in`/`_nin` take a list OF array operands, so their element index does
 * appear in the path (`._in[0]`) — the one place indexing is correct.
 */

import { defineCases } from "../corpus.js";

/** Deterministic row order for the cases that actually return data. */
const SEL = `id`;

export default defineCases([
  // --- operand is not an array -------------------------------------------
  {
    name: "arrop-int-array-eq-number",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: 1}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-eq-boolean",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: true}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-eq-object",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: {}}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-lt-negative-number",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_lt: -1}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-float-array-gt-number",
    query: `{ EntityWithAllTypes(where: {arrayOfFloats: {_gt: -1}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-bigint-array-lt-number",
    query: `{ PostgresNumericPrecisionEntityTester(where: {exampleBigIntArrayRequired: {_lt: -1}}, order_by: {id: asc}) { ${SEL} } }`,
  },

  // --- operand is null ----------------------------------------------------
  {
    name: "arrop-int-array-eq-null",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: null}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-string-array-eq-null",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_eq: null}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-numeric-array-eq-null",
    query: `{ PostgresNumericPrecisionEntityTester(where: {exampleBigIntArray: {_eq: null}}, order_by: {id: asc}) { ${SEL} } }`,
  },

  // --- string passthrough, failing in Postgres ---------------------------
  {
    name: "arrop-string-array-eq-string",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_eq: "a"}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-numeric-array-eq-string",
    query: `{ EntityWithAllTypes(where: {arrayOfBigDecimals: {_eq: "abc"}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  // A string that IS a well-formed array literal reaches Postgres and works.
  {
    name: "arrop-string-array-eq-literal-text",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_eq: "{a,b}"}}, order_by: {id: asc}) { ${SEL} } }`,
  },

  // --- well-formed array operands ----------------------------------------
  {
    name: "arrop-int-array-eq-list",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: [1]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-eq-list-with-null-element",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: [null]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-eq-list-null-and-value",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: [1, null]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-gt-list",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_gt: [1]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-string-array-eq-list",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_eq: ["a"]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-is-null",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_is_null: true}}, order_by: {id: asc}) { ${SEL} } }`,
  },

  // --- element-level parse failures are reported unindexed ---------------
  {
    name: "arrop-bigint-array-eq-list-with-nested-array",
    query: `{ PostgresNumericPrecisionEntityTester(where: {exampleBigIntArray: {_eq: [["a"], 1]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-bigint-array-neq-list-null-then-boolean",
    query: `{ EntityWithAllTypes(where: {arrayOfBigInts: {_neq: [null, true]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-eq-list-with-string-element",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_eq: [1, "x"]}}, order_by: {id: asc}) { ${SEL} } }`,
  },

  // --- _in / _nin take a list of array operands, so indexes DO appear ----
  {
    name: "arrop-int-array-in-list-of-numbers",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_in: [1]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-bigint-array-nin-list-of-numbers",
    query: `{ PostgresNumericPrecisionEntityTester(where: {exampleBigIntArrayRequired: {_nin: [1e3]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-in-list-of-arrays",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_in: [[1], [2]]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-string-array-in-list-of-arrays",
    query: `{ EntityWithAllTypes(where: {arrayOfStrings: {_in: [["a"]]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-nin-list-of-arrays",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_nin: [[1]]}}, order_by: {id: asc}) { ${SEL} } }`,
  },
  {
    name: "arrop-int-array-in-empty-list",
    query: `{ EntityWithAllTypes(where: {arrayOfInts: {_in: []}}, order_by: {id: asc}) { ${SEL} } }`,
  },

  // --- array operands via variables take the same path -------------------
  {
    name: "arrop-int-array-eq-variable-scalar",
    query: `query ($v: [Int!]) { EntityWithAllTypes(where: {arrayOfInts: {_eq: $v}}, order_by: {id: asc}) { ${SEL} } }`,
    rawVariables: `{"v": 1}`,
  },
  {
    name: "arrop-int-array-eq-variable-list",
    query: `query ($v: [Int!]) { EntityWithAllTypes(where: {arrayOfInts: {_eq: $v}}, order_by: {id: asc}) { ${SEL} } }`,
    variables: { v: [1] },
  },
  {
    name: "arrop-int-array-eq-variable-null",
    query: `query ($v: [Int!]) { EntityWithAllTypes(where: {arrayOfInts: {_eq: $v}}, order_by: {id: asc}) { ${SEL} } }`,
    variables: { v: null },
  },

  // --- Postgres error-class mapping --------------------------------------
  // A LIKE pattern ending in the escape character is SQLSTATE 22025, which
  // Hasura reports as bad-request rather than data-exception.
  {
    name: "arrop-like-trailing-escape",
    query: `{ D(where: {c: {_nlike: "\\\\"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "arrop-like-trailing-escape-positive",
    query: `{ D(where: {c: {_like: "\\\\"}}, order_by: {id: asc}) { id } }`,
  },

  // --- required fields are checked before provided ones are descended into
  {
    name: "arrop-aggregate-count-missing-predicate",
    query: `{ B_aggregate(where: {a_aggregate: {count: {filter: {optionalStringToTestLinkedEntities: {_eq: "x"}}}}}) { aggregate { count } } }`,
    role: "admin",
  },
]);
