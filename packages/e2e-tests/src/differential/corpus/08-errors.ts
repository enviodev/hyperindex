import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "error-unknown-root-field",
    query: `{ NotATable { id } }`,
  },
  {
    name: "error-unknown-column",
    query: `{ User { id notAColumn } }`,
  },
  {
    name: "error-unknown-argument",
    query: `{ User(bogus: 1) { id } }`,
  },
  {
    name: "error-syntax",
    query: `{ User { id `,
  },
  {
    name: "error-empty-query",
    query: ``,
  },
  {
    name: "error-no-selection-set",
    query: `{ User }`,
  },
  {
    name: "error-scalar-with-selection",
    query: `{ User(limit: 1) { id { nested } } }`,
  },
  {
    name: "error-by-pk-missing-arg",
    query: `{ User_by_pk { id } }`,
  },
  {
    name: "error-by-pk-wrong-arg-type",
    query: `{ User_by_pk(id: 5) { id } }`,
  },
  {
    name: "error-invalid-enum-value",
    query: `{ User(where: {accountType: {_eq: "NOPE"}}) { id } }`,
  },
  {
    name: "error-enum-as-string-order-by",
    query: `{ User(order_by: {id: "asc"}) { id } }`,
  },
  {
    name: "error-limit-string",
    query: `{ User(limit: "5") { id } }`,
  },
  {
    name: "error-negative-limit",
    query: `{ User(limit: -1) { id } }`,
  },
  {
    name: "error-negative-offset",
    query: `{ SimpleEntity(order_by: {id: asc}, offset: -5) { id } }`,
  },
  {
    name: "error-unknown-op-in-bool-exp",
    query: `{ User(where: {id: {_bogus: "x"}}) { id } }`,
  },
  {
    name: "error-eq-null-literal",
    query: `{ User(where: {gravatar_id: {_eq: null}}) { id } }`,
  },
  {
    name: "error-where-wrong-type",
    query: `{ User(where: {updatesCountOnUserForTesting: {_eq: "not-an-int"}}) { id } }`,
  },
  {
    name: "error-int-overflow-filter",
    query: `{ User(where: {updatesCountOnUserForTesting: {_eq: 99999999999999}}) { id } }`,
  },
  {
    name: "error-float-for-int-filter",
    query: `{ User(where: {updatesCountOnUserForTesting: {_eq: 1.5}}) { id } }`,
  },
  {
    name: "error-missing-required-variable",
    query: `query ($id: String!) { User_by_pk(id: $id) { id } }`,
  },
  {
    name: "error-null-for-required-variable",
    query: `query ($id: String!) { User_by_pk(id: $id) { id } }`,
    variables: { id: null },
  },
  {
    name: "error-variable-wrong-type",
    query: `query ($id: String!) { User_by_pk(id: $id) { id } }`,
    variables: { id: 42 },
  },
  {
    name: "error-unused-variable",
    query: `query ($unused: Int) { SimpleEntity(order_by: {id: asc}, limit: 1) { id } }`,
    variables: { unused: 1 },
  },
  {
    name: "error-undeclared-variable-used",
    query: `{ User(limit: $lim) { id } }`,
    variables: { lim: 1 },
  },
  {
    name: "error-unknown-variable-type",
    query: `query ($w: Bogus_bool_exp) { User { id } }`,
  },
  {
    name: "error-multiple-anonymous-operations",
    query: `{ User(limit: 1) { id } } { Gravatar(limit: 1) { id } }`,
  },
  {
    name: "error-operation-name-not-found",
    query: `query A { User(limit: 1) { id } }`,
    operationName: "B",
  },
  {
    name: "error-multiple-ops-no-operation-name",
    query: `query A { User(limit: 1) { id } } query B { Gravatar(limit: 1) { id } }`,
  },
  {
    name: "error-duplicate-operation-names",
    query: `query A { User(limit: 1) { id } } query A { Gravatar(limit: 1) { id } }`,
    operationName: "A",
  },
  {
    name: "error-fragment-unknown-type",
    query: `fragment F on Bogus { id } { User(limit: 1) { ...F } }`,
  },
  {
    name: "error-fragment-undefined",
    query: `{ User(limit: 1) { ...NoSuchFragment } }`,
  },
  {
    name: "error-fragment-unused",
    query: `fragment Unused on User { id } { User(limit: 1) { id } }`,
  },
  {
    name: "error-fragment-cycle",
    query: `fragment A1 on User { ...B1 } fragment B1 on User { ...A1 } { User(limit: 1) { ...A1 } }`,
  },
  {
    name: "error-mutation-public",
    query: `mutation { insert_User(objects: [{id: "x", address: "0x", updatesCountOnUserForTesting: 0, accountType: "USER"}]) { affected_rows } }`,
  },
  {
    name: "error-subscription-over-http",
    query: `subscription { User(limit: 1) { id } }`,
  },
  {
    name: "error-aggregate-public-not-exposed",
    query: `{ Token_aggregate { aggregate { count } } }`,
  },
  {
    name: "error-distinct-on-without-matching-order",
    query: `{ Token(distinct_on: owner_id, order_by: {tokenId: asc}) { id } }`,
  },
  {
    name: "error-jsonb-path-invalid",
    query: `{ EntityWithAllTypes(where: {id: {_eq: "all-1"}}) { json(path: "totally broken [") } }`,
  },
  {
    name: "error-like-on-int-column",
    query: `{ User(where: {updatesCountOnUserForTesting: {_like: "%1%"}}) { id } }`,
  },
  {
    name: "error-directive-unknown",
    query: `{ User(limit: 1) { id @bogus } }`,
  },
  {
    name: "error-skip-missing-if",
    query: `{ User(limit: 1) { id @skip } }`,
  },
  {
    name: "error-admin-secret-wrong",
    role: "admin-wrong",
    query: `{ User(limit: 1) { id } }`,
  },
]);
