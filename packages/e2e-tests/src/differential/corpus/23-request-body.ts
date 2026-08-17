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
 * A JSON syntax error is reported in aeson's phrasing — `Unexpected
 * end-of-input, expecting JSON value`, `Unexpected ",}", expecting key
 * literal` — which serve restates from serde_json's own error. What aeson
 * calls "unexpected" is the rest of the input from the offending token, one
 * byte before the column serde reports; these cases are what pin that.
 */

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
];

export default defineCases(
  bodies.map(([name, rawBody]) => ({ name, transport: { rawBody } }))
);
