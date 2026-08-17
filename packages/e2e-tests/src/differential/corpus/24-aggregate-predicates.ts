/**
 * Aggregate predicates in a bool_exp (`<rel>_aggregate: { ... }`), and
 * whether an aggregate root touches the database at all. Found by `fuzz.ts`.
 *
 * An aggregate bool_exp must hold exactly one predicate: Hasura rejects an
 * empty one with "exactly one predicate should be specified", where serve
 * used to accept it and return every row.
 *
 * The `__typename`-only cases are a divergence rather than a bug: serve
 * answers a selection that needs no data without running a statement, so a
 * `where` clause that would fail inside Postgres never gets the chance.
 * Hasura runs the statement regardless and surfaces the failure. Skipping
 * the round trip is worth more than reproducing an error nobody asked for.
 */

import { defineCases } from "../corpus.js";

const NO_ROUND_TRIP =
  "serve answers a selection needing no data without running a statement, so a " +
  "predicate that would fail inside Postgres never runs; Hasura executes regardless";

export default defineCases([
  // --- an aggregate predicate must hold exactly one entry ----------------
  {
    name: "aggpred-empty-object",
    query: `{ NftCollection(where: {tokens_aggregate: {}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "aggpred-empty-object-nested-in-and",
    query: `{ NftCollection(where: {_and: [{tokens_aggregate: {}}]}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "aggpred-empty-object-under-not",
    query: `{ NftCollection(where: {_not: {tokens_aggregate: {}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "aggpred-count-predicate",
    query: `{ NftCollection(where: {tokens_aggregate: {count: {predicate: {_gt: 0}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "aggpred-count-predicate-zero",
    query: `{ NftCollection(where: {tokens_aggregate: {count: {predicate: {_eq: 0}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "aggpred-unknown-field",
    query: `{ NftCollection(where: {tokens_aggregate: {nonsense: {}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "aggpred-null-object",
    query: `{ NftCollection(where: {tokens_aggregate: null}, order_by: {id: asc}) { id } }`,
  },

  // --- a selection that needs no data ------------------------------------
  {
    name: "aggpred-typename-only-with-failing-predicate",
    query: `{ SimpleEntity_aggregate(where: {value: {_nilike: "\\\\"}}) { __typename } }`,
    phases: ["limited"],
    knownGap: NO_ROUND_TRIP,
  },
  {
    name: "aggpred-typename-only-with-valid-predicate",
    query: `{ SimpleEntity_aggregate(where: {value: {_eq: "nope"}}) { __typename } }`,
    phases: ["limited"],
  },
  {
    name: "aggpred-count-with-failing-predicate",
    query: `{ SimpleEntity_aggregate(where: {value: {_nilike: "\\\\"}}) { aggregate { count } } }`,
    phases: ["limited"],
  },
]);
