/**
 * Aggregate roots whose selection carries no actual aggregate function, so
 * Hasura's SQL degenerates. Found by `fuzz.ts` once it started emitting
 * @skip / @include.
 *
 * `aggregate { __typename }` asks for nothing that needs aggregating, and a
 * selection emptied by a directive asks for nothing at all. Hasura still
 * emits a statement built around the row set — one row per matching row
 * rather than a single aggregate row — and then asserts it got exactly one,
 * so the query succeeds only when exactly one row happens to match and is an
 * internal "database query error" for zero rows and for many. serve compiles
 * the same selection to a statement that answers it, and so returns the
 * data GraphQL asks for.
 *
 * These are therefore recorded as gaps we do not plan to close: matching
 * would mean emitting a statement that cannot answer the query. The cases
 * where Hasura's assertion happens to hold (exactly one row) must keep
 * matching, and do.
 *
 * Runs in the limited phase, where the public role may aggregate `User`:
 * as admin, Hasura adds `extensions.internal` to every internal error (the
 * failing SQL and its parameters), which serve deliberately never returns.
 */

import { defineCases } from "../corpus.js";

const DEGENERATE =
  "Hasura's degenerate aggregate statement returns one row per matching row and " +
  "fails its exactly-one-row assertion; serve compiles a statement that answers the query";

export default defineCases([
  // --- no aggregate function in the selection ----------------------------
  {
    name: "degagg-typename-only-many-rows",
    query: `{ User_aggregate { aggregate { __typename } } }`,
    phases: ["limited"],
    knownGap: DEGENERATE,
  },
  {
    name: "degagg-typename-only-two-rows-by-limit",
    query: `{ User_aggregate(limit: 2) { aggregate { __typename } } }`,
    phases: ["limited"],
    knownGap: DEGENERATE,
  },
  // Zero rows: Hasura's assertion fails, and serve reaches the same internal
  // error from its own statement, so this one does match.
  {
    name: "degagg-typename-only-zero-rows",
    query: `{ User_aggregate(where: {id: {_eq: "nope"}}) { aggregate { __typename } } }`,
    phases: ["limited"],
  },
  // Exactly one row matches, so Hasura's assertion holds and both engines
  // must answer identically.
  {
    name: "degagg-typename-only-one-row-by-where",
    query: `{ User_aggregate(where: {id: {_eq: "user-1"}}) { aggregate { __typename } } }`,
    phases: ["limited"],
  },
  {
    name: "degagg-typename-only-one-row-by-limit",
    query: `{ User_aggregate(limit: 1) { aggregate { __typename } } }`,
    phases: ["limited"],
  },

  // --- selections emptied by a directive ---------------------------------
  {
    name: "degagg-nodes-skipped",
    query: `{ User_aggregate { nodes @skip(if: true) { id } } }`,
    phases: ["limited"],
    knownGap: DEGENERATE,
  },
  {
    name: "degagg-nodes-excluded",
    query: `{ User_aggregate { nodes @include(if: false) { id } } }`,
    phases: ["limited"],
    knownGap: DEGENERATE,
  },
  {
    name: "degagg-aggregate-skipped",
    query: `{ User_aggregate { aggregate @skip(if: true) { count } } }`,
    phases: ["limited"],
    knownGap: DEGENERATE,
  },

  // --- a surviving aggregate function keeps the statement well-formed ----
  {
    name: "degagg-count-plus-skipped-nodes",
    query: `{ User_aggregate { aggregate { count } nodes @skip(if: true) { id } } }`,
    phases: ["limited"],
  },
  {
    name: "degagg-root-typename-only",
    query: `{ User_aggregate { __typename } }`,
    phases: ["limited"],
  },
  {
    name: "degagg-nodes-only",
    query: `{ User_aggregate { nodes { id } } }`,
    phases: ["limited"],
    compare: "rootSet",
  },
  {
    name: "degagg-count-and-nodes",
    query: `{ User_aggregate { aggregate { count } nodes { id } } }`,
    phases: ["limited"],
    compare: "rootSet",
  },

  // --- the same shapes on non-aggregate roots stay fine ------------------
  {
    name: "degagg-table-root-all-skipped",
    query: `{ User(order_by: {id: asc}, limit: 1) { id @skip(if: true) } }`,
  },
  {
    name: "degagg-by-pk-all-skipped",
    query: `{ User_by_pk(id: "user-1") { id @skip(if: true) } }`,
  },
  {
    name: "degagg-nested-relationship-all-skipped",
    query: `{ User(order_by: {id: asc}, limit: 1) { id tokens(order_by: {id: asc}) { id @skip(if: true) } } }`,
  },
  {
    name: "degagg-table-root-include-true",
    query: `{ User(order_by: {id: asc}, limit: 1) { id @include(if: true) address @skip(if: false) } }`,
  },

  // --- the same degeneration nested under a table root -------------------
  // A nested aggregate whose selection is emptied does not fail an
  // assertion: it returns one row per related row, so the PARENT rows are
  // duplicated. coll-1 has 4 tokens and appears 4 times, turning 3
  // collections into 10 rows. serve returns the 3 rows GraphQL asks for.
  {
    name: "degagg-nested-aggregate-nodes-excluded",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate { nodes @include(if: false) { __typename } } } }`,
    role: "admin",
    knownGap: DEGENERATE,
  },
  {
    name: "degagg-nested-aggregate-typename-only",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate { aggregate { __typename } } } }`,
    role: "admin",
    knownGap: DEGENERATE,
  },
  // A real aggregate function nested the same way is well-formed on both.
  {
    name: "degagg-nested-aggregate-count",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate { aggregate { count } } } }`,
    role: "admin",
  },
  {
    name: "degagg-nested-aggregate-count-plus-skipped-nodes",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate { aggregate { count } nodes @skip(if: true) { id } } } }`,
    role: "admin",
  },

  // --- admin-only internal error detail ----------------------------------
  // Hasura returns the failing statement, its parameters and the raw
  // Postgres error under extensions.internal for the admin role. serve never
  // does, so a leaked admin secret cannot be used to read the generated SQL
  // back out of the API.
  {
    name: "degagg-admin-internal-error-detail",
    query: `{ User_aggregate(where: {id: {_eq: "nope"}}) { aggregate { __typename } } }`,
    role: "admin",
    phases: ["limited"],
    knownGap:
      "Hasura returns the failing SQL and its parameters in extensions.internal for the admin role; serve deliberately omits it",
  },
]);
