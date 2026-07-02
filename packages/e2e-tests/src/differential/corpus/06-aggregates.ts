import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "agg-count-basic",
    role: "admin",
    query: `{ User_aggregate { aggregate { count } } }`,
    bench: true,
  },
  {
    name: "agg-count-with-where",
    role: "admin",
    query: `{ User_aggregate(where: {accountType: {_eq: "ADMIN"}}) { aggregate { count } } }`,
  },
  {
    name: "agg-count-column",
    role: "admin",
    query: `{ User_aggregate { aggregate { count(columns: gravatar_id) } } }`,
  },
  {
    name: "agg-count-distinct",
    role: "admin",
    query: `{ Token_aggregate { aggregate { count(columns: owner_id, distinct: true) } } }`,
  },
  {
    name: "agg-count-distinct-false",
    role: "admin",
    query: `{ Token_aggregate { aggregate { count(columns: owner_id, distinct: false) } } }`,
  },
  {
    name: "agg-min-max-int",
    role: "admin",
    query: `{ User_aggregate { aggregate { min { updatesCountOnUserForTesting } max { updatesCountOnUserForTesting } } } }`,
  },
  {
    name: "agg-min-max-string",
    role: "admin",
    query: `{ SimpleEntity_aggregate { aggregate { min { id value } max { id value } } } }`,
  },
  {
    name: "agg-min-max-numeric",
    role: "admin",
    query: `{ Token_aggregate { aggregate { min { tokenId } max { tokenId } } } }`,
  },
  {
    name: "agg-min-max-timestamp",
    role: "admin",
    query: `{ EntityWithTimestamp_aggregate { aggregate { min { timestamp } max { timestamp } } } }`,
  },
  {
    name: "agg-sum-avg-numeric",
    role: "admin",
    query: `{ Token_aggregate { aggregate { sum { tokenId } avg { tokenId } } } }`,
  },
  {
    name: "agg-sum-avg-int-float",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate(where: {id: {_in: ["scalar-1", "scalar-nulls", "scalar-empty"]}}) { aggregate { sum { int_ float_ bigInt bigDecimal } avg { int_ float_ } } } }`,
  },
  {
    name: "agg-stddev-variance",
    role: "admin",
    query: `{ SimulateTestEvent_aggregate { aggregate { stddev { blockNumber } stddev_pop { blockNumber } stddev_samp { blockNumber } variance { blockNumber } var_pop { blockNumber } var_samp { blockNumber } } } }`,
  },
  {
    name: "agg-empty-set",
    role: "admin",
    query: `{ User_aggregate(where: {id: {_eq: "missing"}}) { aggregate { count sum { updatesCountOnUserForTesting } avg { updatesCountOnUserForTesting } min { id } max { id } } } }`,
  },
  {
    name: "agg-nodes",
    role: "admin",
    query: `{ SimpleEntity_aggregate(order_by: {id: asc}, limit: 3) { aggregate { count } nodes { id value } } }`,
  },
  {
    name: "agg-nodes-only",
    role: "admin",
    query: `{ SimpleEntity_aggregate(order_by: {id: desc}, limit: 2) { nodes { id } } }`,
  },
  {
    name: "agg-with-limit-offset",
    role: "admin",
    query: `{ SimpleEntity_aggregate(order_by: {id: asc}, limit: 4, offset: 2) { aggregate { count } nodes { id } } }`,
  },
  {
    name: "agg-with-distinct-on",
    role: "admin",
    query: `{ Token_aggregate(distinct_on: owner_id, order_by: [{owner_id: asc}, {tokenId: desc}]) { aggregate { count } nodes { id owner_id } } }`,
  },
  {
    name: "agg-nested-array-relationship",
    role: "admin",
    query: `{ User(order_by: {id: asc}) { id tokens_aggregate { aggregate { count sum { tokenId } } } } }`,
    bench: true,
  },
  {
    name: "agg-nested-with-args",
    role: "admin",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate(where: {tokenId: {_gte: 1}}, order_by: {tokenId: asc}) { aggregate { count max { tokenId } } nodes { id } } } }`,
  },
  {
    name: "agg-aliases",
    role: "admin",
    query: `{ total: User_aggregate { aggregate { c: count } } admins: User_aggregate(where: {accountType: {_eq: "ADMIN"}}) { aggregate { count } } }`,
  },
  {
    name: "agg-typename",
    role: "admin",
    query: `{ User_aggregate { __typename aggregate { __typename count } } }`,
  },
  {
    name: "agg-public-role-denied",
    role: "public",
    query: `{ User_aggregate { aggregate { count } } }`,
  },
  {
    name: "agg-nested-public-role-denied",
    role: "public",
    query: `{ User(order_by: {id: asc}, limit: 1) { id tokens_aggregate { aggregate { count } } } }`,
  },
]);
