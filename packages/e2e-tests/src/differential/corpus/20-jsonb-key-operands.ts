/**
 * Operands of the jsonb key operators (`_has_key`, `_has_keys_all`,
 * `_has_keys_any`). Found by `fuzz.ts`.
 *
 * These take Text rather than the column's own type, and Hasura parses them
 * with aeson like any other operand — so a non-string is a `parse-failed`
 * ("parsing Text failed, expected String, but encountered <Kind>"), not the
 * GraphQL-native "expected a string for type 'String'" that serve produced.
 * The null cases differ by position: a null operand is passed through to SQL
 * (matching no rows), while a null *element* of the keys list is rejected,
 * because the list's element type is non-null.
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
]);
