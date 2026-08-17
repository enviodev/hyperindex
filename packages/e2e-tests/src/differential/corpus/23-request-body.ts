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
 * Hasura reports a JSON syntax error in aeson's phrasing —
 * `Unexpected end-of-input, expecting JSON value`, `Unexpected ",}",
 * expecting key literal` — while serve passes serde_json's own message
 * through. Closing that means mapping serde_json's syntax errors onto
 * aeson's vocabulary; the shapes below are what such a mapping has to
 * produce. The code (`invalid-json`), the path and the status already match,
 * so only the human-readable text differs.
 */
const JSON_SYNTAX_TEXT =
  "serve passes serde_json's syntax-error text through; Hasura reports aeson's phrasing";

/** Body shapes that are not a GraphQL request object at all. */
const notAnObject = [
  ["body-not-json", `not json`, JSON_SYNTAX_TEXT],
  ["body-json-string", `"query"`, undefined],
  ["body-json-number", `42`, undefined],
  ["body-json-true", `true`, undefined],
  ["body-json-null", `null`, undefined],
  ["body-json-float", `1.5`, undefined],
] as const;

/** Bodies that are objects, but wrong in some field. */
const wrongFields = [
  ["body-empty-object", `{}`, undefined],
  ["body-query-number", `{"query": 5}`, undefined],
  ["body-query-null", `{"query": null}`, undefined],
  ["body-query-object", `{"query": {}}`, undefined],
  ["body-query-array", `{"query": ["{ __typename }"]}`, undefined],
  ["body-variables-string", `{"query": "{ __typename }", "variables": "v"}`, undefined],
  ["body-variables-array", `{"query": "{ __typename }", "variables": [1]}`, undefined],
  ["body-variables-number", `{"query": "{ __typename }", "variables": 1}`, undefined],
  ["body-variables-null", `{"query": "{ __typename }", "variables": null}`, undefined],
  ["body-operation-name-number", `{"query": "{ __typename }", "operationName": 5}`, undefined],
  ["body-operation-name-null", `{"query": "{ __typename }", "operationName": null}`, undefined],
  ["body-extra-unknown-key", `{"query": "{ __typename }", "nonsense": 1}`, undefined],
  // Hasura keeps the FIRST occurrence of a repeated key and answers the
  // __typename query; serde_json keeps the last, so serve answers the User
  // one. Closing it needs a decoder that folds duplicates first-wins.
  [
    "body-duplicate-query-key",
    `{"query": "{ __typename }", "query": "{ User { id } }"}`,
    "serve keeps the last occurrence of a duplicated JSON key, Hasura keeps the first",
  ],
  ["body-trailing-comma", `{"query": "{ __typename }",}`, JSON_SYNTAX_TEXT],
  ["body-unterminated-object", `{"query": "{ __typename }"`, JSON_SYNTAX_TEXT],
] as const;

export default defineCases([
  ...[...notAnObject, ...wrongFields].map(([name, rawBody, knownGap]) => ({
    name,
    transport: { rawBody },
    ...(knownGap !== undefined && { knownGap }),
  })),
  // An empty body, and a body that is only whitespace.
  { name: "body-empty", transport: { rawBody: `` }, knownGap: JSON_SYNTAX_TEXT },
  { name: "body-whitespace", transport: { rawBody: `   ` }, knownGap: JSON_SYNTAX_TEXT },
]);
