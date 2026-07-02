import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "basic-select-all-users",
    query: `{ User(order_by: {id: asc}) { id address gravatar_id updatesCountOnUserForTesting accountType } }`,
    bench: true,
  },
  {
    name: "basic-select-no-order",
    query: `{ SimpleEntity { id value } }`,
    compare: "rootSet",
  },
  {
    name: "basic-by-pk-hit",
    query: `{ User_by_pk(id: "user-1") { id address accountType } }`,
    bench: true,
  },
  {
    name: "basic-by-pk-miss",
    query: `{ User_by_pk(id: "nope") { id } }`,
  },
  {
    name: "basic-by-pk-special-chars",
    query: `{ User_by_pk(id: "user \\"quoted\\" 🚀") { id address } }`,
  },
  {
    name: "basic-typename-root",
    query: `{ __typename User(order_by: {id: asc}, limit: 1) { __typename id } }`,
  },
  {
    name: "basic-typename-by-pk",
    query: `{ User_by_pk(id: "user-1") { __typename } }`,
  },
  {
    name: "basic-aliases",
    query: `{ renamed: User(order_by: {id: asc}, limit: 2) { theId: id addr: address t: __typename } }`,
  },
  {
    name: "basic-same-field-twice",
    query: `{ User(order_by: {id: asc}, limit: 1) { id id address address } }`,
  },
  {
    name: "basic-alias-two-roots-same-table",
    query: `{ first: User(order_by: {id: asc}, limit: 1) { id } last: User(order_by: {id: desc}, limit: 1) { id } }`,
  },
  {
    name: "basic-multiple-root-fields",
    query: `{ User(order_by: {id: asc}) { id } Gravatar(order_by: {id: asc}) { id } Token(order_by: {id: asc}, limit: 3) { id } }`,
  },
  {
    name: "basic-fragment-spread",
    query: `fragment UserFields on User { id address accountType } { User(order_by: {id: asc}, limit: 2) { ...UserFields } }`,
  },
  {
    name: "basic-inline-fragment",
    query: `{ User(order_by: {id: asc}, limit: 2) { ... on User { id accountType } } }`,
  },
  {
    name: "basic-nested-fragments",
    query: `fragment A1 on User { id ...B1 } fragment B1 on User { address } { User(order_by: {id: asc}, limit: 1) { ...A1 } }`,
  },
  {
    name: "basic-variables-string",
    query: `query ($id: String!) { User_by_pk(id: $id) { id address } }`,
    variables: { id: "user-2" },
  },
  {
    name: "basic-variables-default-value",
    query: `query ($lim: Int = 2) { User(order_by: {id: asc}, limit: $lim) { id } }`,
  },
  {
    name: "basic-variables-null-optional",
    query: `query ($lim: Int) { User(order_by: {id: asc}, limit: $lim) { id } }`,
    variables: { lim: null },
  },
  {
    name: "basic-operation-name-selection",
    query: `query GetUsers { User(order_by: {id: asc}, limit: 1) { id } } query GetGravatars { Gravatar(order_by: {id: asc}, limit: 1) { id } }`,
    operationName: "GetGravatars",
  },
  {
    name: "basic-named-operation",
    query: `query Q { SimpleEntity(order_by: {id: asc}, limit: 1) { id value } }`,
  },
  {
    name: "basic-skip-include",
    query: `query ($withAddr: Boolean!, $skipType: Boolean!) { User(order_by: {id: asc}, limit: 2) { id address @include(if: $withAddr) accountType @skip(if: $skipType) } }`,
    variables: { withAddr: true, skipType: true },
  },
  {
    name: "basic-skip-include-false",
    query: `query ($withAddr: Boolean!, $skipType: Boolean!) { User(order_by: {id: asc}, limit: 2) { id address @include(if: $withAddr) accountType @skip(if: $skipType) } }`,
    variables: { withAddr: false, skipType: false },
  },
  {
    name: "basic-empty-table",
    query: `{ CustomSelectionTestPass(where: {id: {_eq: "missing"}}) { id } }`,
  },
  {
    name: "basic-63-char-table",
    query: `{ EntityWith63LenghtName______________________________________one(order_by: {id: asc}) { id } }`,
  },
  {
    name: "basic-restricted-field-name",
    query: `{ EntityWithRestrictedReScriptField(order_by: {id: asc}) { id type } }`,
  },
  {
    name: "basic-admin-role",
    role: "admin",
    query: `{ User(order_by: {id: asc}) { id address } }`,
  },
]);
