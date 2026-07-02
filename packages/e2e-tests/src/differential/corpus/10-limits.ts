import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "limits-response-limit-caps-rows",
    phases: ["limited"],
    query: `{ SimpleEntity(order_by: {id: asc}) { id } }`,
  },
  {
    name: "limits-response-limit-explicit-higher",
    phases: ["limited"],
    query: `{ SimpleEntity(order_by: {id: asc}, limit: 9) { id } }`,
  },
  {
    name: "limits-response-limit-explicit-lower",
    phases: ["limited"],
    query: `{ SimpleEntity(order_by: {id: asc}, limit: 2) { id } }`,
  },
  {
    name: "limits-response-limit-with-offset",
    phases: ["limited"],
    query: `{ SimpleEntity(order_by: {id: asc}, offset: 7) { id } }`,
  },
  {
    name: "limits-admin-not-capped",
    phases: ["limited"],
    role: "admin",
    query: `{ SimpleEntity(order_by: {id: asc}) { id } }`,
  },
  {
    name: "limits-nested-relationship-capped",
    phases: ["limited"],
    query: `{ User(where: {id: {_eq: "user-1"}}) { id tokens(order_by: {id: asc}) { id } } }`,
  },
  {
    name: "limits-by-pk-unaffected",
    phases: ["limited"],
    query: `{ SimpleEntity_by_pk(id: "simple-9") { id } }`,
  },
  {
    name: "limits-public-aggregate-enabled",
    phases: ["limited"],
    query: `{ User_aggregate { aggregate { count } } }`,
  },
  {
    name: "limits-public-aggregate-count-exceeds-limit",
    phases: ["limited"],
    query: `{ SimpleEntity_aggregate { aggregate { count } nodes { id } } }`,
  },
  {
    name: "limits-public-aggregate-not-enabled-table",
    phases: ["limited"],
    query: `{ Gravatar_aggregate { aggregate { count } } }`,
  },
  {
    name: "limits-public-nested-aggregate-enabled",
    phases: ["limited"],
    query: `{ User(order_by: {id: asc}, limit: 2) { id tokens_aggregate { aggregate { count } } } }`,
  },
  {
    name: "limits-meta-aggregate-enabled",
    phases: ["limited"],
    query: `{ _meta_aggregate { aggregate { count } } }`,
  },
  {
    name: "limits-raw-events-capped",
    phases: ["limited"],
    query: `{ raw_events(order_by: {serial: asc}) { serial } }`,
  },
]);
