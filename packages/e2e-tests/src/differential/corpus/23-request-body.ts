/**
 * Malformed and edge-shaped POST bodies.
 *
 * These shapes used to be asserted in a Rust unit test against hardcoded
 * expectations (`http.rs::request_body_decoding_errors`). Recording them from
 * Hasura instead makes the oracle real: the unit test claimed a JSON array
 * body was "expected Object, but encountered Array", which is what serve
 * does, but Hasura treats an array as a batch and blames the element
 * (`$[0]`) — a difference the unit test could never surface because it only
 * ever compared serve against itself.
 */

import { defineCases } from "../corpus.js";

/**
 * A JSON syntax error carries aeson's phrasing in Hasura — `Unexpected
 * end-of-input, expecting JSON value`, `Unexpected ",\n}", expecting key
 * literal` — where serve passes serde_json's own message through. What aeson
 * calls "unexpected" is the input from where ITS parser gave up: before a
 * separator it had not consumed, with escapes applied. serde reports a line
 * and a byte column after skipping whitespace, which cannot reconstruct that
 * position — the multi-line cases below are what proved it, after a rule
 * derived from the single-line ones turned out to be coincidence. The code,
 * the path and the status all match; only the human-readable text differs.
 */
const AESON_PHRASING =
  "serve passes serde_json's syntax-error text through; Hasura reports aeson's phrasing, " +
  "which names the input from its own parser position";

const bodies: [string, string][] = [
  // Not a GraphQL request object at all.
  ["body-not-json", `not json`],
  ["body-json-string", `"query"`],
  ["body-json-number", `42`],
  ["body-json-true", `true`],
  ["body-json-null", `null`],
  ["body-json-float", `1.5`],
  // Objects, wrong in some field.
  ["body-empty-object", `{}`],
  ["body-query-number", `{"query": 5}`],
  ["body-query-null", `{"query": null}`],
  ["body-query-object", `{"query": {}}`],
  ["body-query-array", `{"query": ["{ __typename }"]}`],
  ["body-variables-string", `{"query": "{ __typename }", "variables": "v"}`],
  ["body-variables-array", `{"query": "{ __typename }", "variables": [1]}`],
  ["body-variables-number", `{"query": "{ __typename }", "variables": 1}`],
  ["body-variables-null", `{"query": "{ __typename }", "variables": null}`],
  ["body-operation-name-number", `{"query": "{ __typename }", "operationName": 5}`],
  ["body-operation-name-null", `{"query": "{ __typename }", "operationName": null}`],
  ["body-extra-unknown-key", `{"query": "{ __typename }", "nonsense": 1}`],
  // A repeated key: the FIRST occurrence wins, so this answers __typename.
  [
    "body-duplicate-query-key",
    `{"query": "{ __typename }", "query": "{ User { id } }"}`,
  ],
  ["body-trailing-comma", `{"query": "{ __typename }",}`],
  ["body-unterminated-object", `{"query": "{ __typename }"`],
  ["body-empty", ``],
  ["body-whitespace", `   `],
  // Pretty-printed bodies are the common case from a file or a GUI client,
  // and put the syntax error on a line of its own — the offending token has
  // to be found by line and byte column, not by counting from the start.
  ["body-multiline-trailing-comma", `{\n  "query": "{ __typename }",\n}`],
  ["body-multiline-unterminated", `{\n  "query": "{ __typename }"\n`],
  ["body-multiline-bad-value", `{\n  "query": nope\n}`],
  ["body-multiline-second-line-garbage", `{\n  "query": "{ __typename }",\n  oops\n}`],
  // A multibyte character before the error means the byte column and the
  // character index disagree.
  ["body-unicode-before-error", `{"q🚀": "x", "query": }`],
  ["body-unicode-in-query-then-error", `{"query": "{ User(where: {id: {_eq: \"🚀\"}}) { id } }", }`],
];

/** The bodies whose failure is a JSON syntax error rather than a bad field. */
const SYNTAX_ERRORS = new Set([
  "body-not-json",
  "body-empty",
  "body-whitespace",
  "body-trailing-comma",
  "body-unterminated-object",
  "body-multiline-trailing-comma",
  "body-multiline-unterminated",
  "body-multiline-bad-value",
  "body-multiline-second-line-garbage",
  "body-unicode-before-error",
  "body-unicode-in-query-then-error",
]);

export default defineCases(
  bodies.map(([name, rawBody]) => ({
    name,
    transport: { rawBody },
    ...(SYNTAX_ERRORS.has(name) && { knownGap: AESON_PHRASING }),
  }))
);
