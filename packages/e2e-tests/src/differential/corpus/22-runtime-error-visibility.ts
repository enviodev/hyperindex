/**
 * Predicates that fail at runtime in Postgres, ANDed with a predicate that
 * excludes every row. Found by `fuzz.ts`.
 *
 * Whether the failing predicate produces an error at all depends on whether
 * Postgres evaluates it, and Postgres reorders the clauses of an AND by
 * estimated cost. Hasura inlines comparison values as SQL constants
 * (`= ANY(('{-1}')::integer[])`), which the planner costs precisely and
 * hoists ahead of the expensive ILIKE — the plan reads
 * `Filter: (("timestamp" = ANY ('{-1}'::integer[])) AND (id !~~* '\\'))`, so
 * the pattern is never evaluated and the query returns no rows. serve binds
 * every value as an out-of-band parameter and never inlines it into the SQL
 * text, so the planner keeps the written order and the pattern raises.
 *
 * Matching would mean giving up parameter binding, which is worth more than
 * the error visibility of a pathological pattern: these are recorded as gaps
 * we do not plan to close. On its own — nothing to reorder around — the same
 * predicate errors identically on both engines.
 */

import { defineCases } from "../corpus.js";

const PLAN_ORDER =
  "runtime error visibility depends on Postgres's clause ordering: Hasura inlines " +
  "comparison constants so the planner hoists the cheap predicate, serve binds " +
  "parameters out-of-band and keeps the written order";

export default defineCases([
  // Alone, both engines evaluate the pattern and both raise.
  {
    name: "rterr-ilike-trailing-escape-alone",
    query: `{ SimulateTestEvent(where: {id: {_nilike: "\\\\"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rterr-like-trailing-escape-alone",
    query: `{ SimulateTestEvent(where: {id: {_like: "\\\\"}}, order_by: {id: asc}) { id } }`,
  },
  // ANDed with a predicate that matches nothing, the planner may skip it.
  {
    name: "rterr-ilike-and-empty-in",
    query: `{ SimulateTestEvent(where: {_and: [{id: {_nilike: "\\\\"}}, {timestamp: {_in: -1}}]}, order_by: {id: asc}) { id } }`,
    knownGap: PLAN_ORDER,
  },
  {
    name: "rterr-ilike-and-empty-in-reversed",
    query: `{ SimulateTestEvent(where: {_and: [{timestamp: {_in: -1}}, {id: {_nilike: "\\\\"}}]}, order_by: {id: asc}) { id } }`,
    knownGap: PLAN_ORDER,
  },
  // A scalar `_eq` is costed the same way on both engines, so the planner
  // makes the same choice and the pattern raises on both: the divergence
  // needs the array constant, not merely an excluding predicate.
  {
    name: "rterr-ilike-and-impossible-eq",
    query: `{ SimulateTestEvent(where: {_and: [{id: {_nilike: "\\\\"}}, {timestamp: {_eq: -1}}]}, order_by: {id: asc}) { id } }`,
  },
  // With a predicate that excludes nothing, both engines must evaluate the
  // pattern and both must raise.
  {
    name: "rterr-ilike-and-always-true",
    query: `{ SimulateTestEvent(where: {_and: [{id: {_nilike: "\\\\"}}, {id: {_is_null: false}}]}, order_by: {id: asc}) { id } }`,
  },
]);
