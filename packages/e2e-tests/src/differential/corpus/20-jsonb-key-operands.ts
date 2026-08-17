/**
 * Operands of the jsonb operators. Found by `fuzz.ts`.
 *
 * The key operators (`_has_key`, `_has_keys_all`, `_has_keys_any`):
 *
 * These take Text rather than the column's own type, and Hasura parses them
 * with aeson like any other operand — so a non-string is a `parse-failed`
 * ("parsing Text failed, expected String, but encountered <Kind>"), not the
 * GraphQL-native "expected a string for type 'String'" that serve produced.
 * The null cases differ by position: a null operand is passed through to SQL
 * (matching no rows), while a null *element* of the keys list is rejected,
 * because the list's element type is non-null.
 *
 * `_in`/`_nin` on a jsonb column are a different story: they are broken in
 * Hasura v2.43 and serve deliberately does not reproduce the breakage. Hasura
 * builds the `= ANY(...)` array literal with `buildArrayLiteral`, which
 * encodes a non-string jsonb element through `PE.jsonb_ast` — the BINARY
 * encoder. Every such element therefore carries jsonb's 0x01 version byte
 * into a text array literal and Postgres rejects the lot with "invalid input
 * syntax for type json". The only operand that survives is a JSON string
 * whose contents do not themselves parse as JSON, which takes a different
 * branch. serve implements the operator as intended, so these cases are
 * marked as gaps we do not plan to close: if a Hasura upgrade fixes the
 * encoder, re-recording makes them match and the harness will say so.
 */

import { defineCases } from "../corpus.js";

const ROOT = `raw_events(order_by: {serial: asc})`;

export default defineCases([
  // --- _has_key ----------------------------------------------------------
  {
    name: "jsonbkey-has-key-string",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: "number"}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-key-missing-string",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: "nope"}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-key-null",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: null}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-key-boolean",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: true}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-key-object",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: {}}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-key-number",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: 1}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-key-list",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_key: ["number"]}})`)} { serial } }`,
  },

  // --- _has_keys_all / _has_keys_any -------------------------------------
  {
    name: "jsonbkey-has-keys-all-strings",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: ["number", "timestamp"]}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-any-strings",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_any: ["number", "nope"]}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-all-empty",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: []}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-any-empty",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_any: []}})`)} { serial } }`,
  },
  // A bare string coerces to a one-element list: this IS a GraphQL list
  // input position, unlike an array column's operand.
  {
    name: "jsonbkey-has-keys-all-bare-string",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: "number"}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-all-null-operand",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: null}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-all-null-element",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: [null]}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-any-number-element",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_any: [1]}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-all-object-element",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: [{}]}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-all-nested-list-element",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: [["a"]]}})`)} { serial } }`,
  },
  {
    name: "jsonbkey-has-keys-all-string-then-null",
    query: `{ ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: ["number", null]}})`)} { serial } }`,
  },

  // --- via variables -----------------------------------------------------
  {
    name: "jsonbkey-has-key-variable-number",
    query: `query ($k: String) { ${ROOT.replace(")", `, where: {block_fields: {_has_key: $k}})`)} { serial } }`,
    rawVariables: `{"k": 1}`,
  },
  {
    name: "jsonbkey-has-keys-all-variable-null-element",
    query: `query ($k: [String!]) { ${ROOT.replace(")", `, where: {block_fields: {_has_keys_all: $k}})`)} { serial } }`,
    rawVariables: `{"k": [null]}`,
  },

  // --- _in / _nin on a jsonb column: Hasura's binary-encoder bug ---------
  // Works on both: a string that is not itself valid JSON.
  {
    name: "jsonbin-in-string-not-json",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: ["str"]}})`)} { serial } }`,
  },
  {
    name: "jsonbin-in-empty-list",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: []}})`)} { serial } }`,
  },
  // _eq takes a different translation path and is correct on both engines.
  {
    name: "jsonbin-eq-number",
    query: `{ ${ROOT.replace(")", `, where: {params: {_eq: 1}})`)} { serial } }`,
  },
  {
    name: "jsonbin-eq-object",
    query: `{ ${ROOT.replace(")", `, where: {params: {_eq: {}}})`)} { serial } }`,
  },
  {
    name: "jsonbin-in-number",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: [1]}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
  {
    name: "jsonbin-in-boolean",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: [true]}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
  {
    name: "jsonbin-in-object",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: [{}]}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
  {
    name: "jsonbin-in-nested-list",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: [[1]]}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
  // A string that DOES parse as JSON takes the same buggy branch.
  {
    name: "jsonbin-in-string-that-is-json",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: ["1"]}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
  {
    name: "jsonbin-nin-number",
    query: `{ ${ROOT.replace(")", `, where: {params: {_nin: [1]}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
  {
    name: "jsonbin-in-number-bare",
    query: `{ ${ROOT.replace(")", `, where: {params: {_in: 1}})`)} { serial } }`,
    knownGap: "Hasura binary-encodes non-string jsonb _in elements and errors; serve executes the operator correctly",
  },
]);
