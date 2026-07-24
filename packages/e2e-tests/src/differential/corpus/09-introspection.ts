import { defineCases } from "../corpus.js";

const FULL_INTROSPECTION = `
query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types { ...FullType }
    directives { name description locations args { ...InputValue } }
  }
}
fragment FullType on __Type {
  kind name description
  fields(includeDeprecated: true) {
    name description
    args { ...InputValue }
    type { ...TypeRef }
    isDeprecated deprecationReason
  }
  inputFields { ...InputValue }
  interfaces { ...TypeRef }
  enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }
  possibleTypes { ...TypeRef }
}
fragment InputValue on __InputValue { name description type { ...TypeRef } defaultValue }
fragment TypeRef on __Type {
  kind name
  ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }
}`;

export default defineCases([
  {
    name: "introspection-full-public",
    query: FULL_INTROSPECTION,
  },
  // The admin schema is compared per-read-feature below instead of via full
  // introspection: envio serve is read-only, so Hasura's admin mutation
  // surface (mutation_root + insert_/update_/delete_ types) is out of scope.
  {
    name: "introspection-admin-query-root",
    role: "admin",
    query: `{ __type(name: "query_root") { fields { name description args { name description type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } defaultValue } type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } }`,
  },
  {
    name: "introspection-admin-subscription-root",
    role: "admin",
    query: `{ __type(name: "subscription_root") { fields { name description args { name type { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } type { kind name } } } }`,
  },
  {
    name: "introspection-full-public-limited",
    phases: ["limited"],
    query: FULL_INTROSPECTION,
  },
  {
    name: "introspection-typename-meta",
    query: `{ __schema { queryType { name } } }`,
  },
  {
    name: "introspection-type-entity",
    query: `{ __type(name: "User") { kind name description fields { name type { kind name ofType { kind name ofType { kind name } } } } } }`,
  },
  {
    name: "introspection-descriptions",
    query: `{ __type(name: "User") { description fields { name description } } }`,
  },
  {
    name: "introspection-descriptions-stream-cursor-value-input",
    query: `{ __type(name: "User_stream_cursor_value_input") { inputFields { name description } } }`,
  },
  {
    name: "introspection-descriptions-bool-exp-and-order-by",
    query: `{ bool_exp: __type(name: "User_bool_exp") { inputFields { name description } } order_by: __type(name: "User_order_by") { inputFields { name description } } }`,
  },
  {
    name: "introspection-type-bool-exp",
    query: `{ __type(name: "User_bool_exp") { kind name inputFields { name type { kind name ofType { kind name ofType { kind name } } } } } }`,
  },
  {
    name: "introspection-type-comparison-exp",
    query: `{ __type(name: "numeric_comparison_exp") { kind name inputFields { name type { kind name ofType { kind name } } } } }`,
  },
  {
    name: "introspection-type-order-by-enum",
    query: `{ __type(name: "order_by") { kind name enumValues { name description } } }`,
  },
  {
    name: "introspection-type-select-column",
    query: `{ __type(name: "Token_select_column") { kind name enumValues { name description } } }`,
  },
  {
    name: "introspection-type-pg-enum-scalar",
    query: `{ __type(name: "accounttype") { kind name description } }`,
  },
  {
    name: "introspection-type-missing",
    query: `{ __type(name: "DoesNotExist") { kind name } }`,
  },
  {
    name: "introspection-aggregate-types-admin",
    role: "admin",
    query: `{ agg: __type(name: "Token_aggregate_fields") { fields { name args { name defaultValue type { kind name ofType { kind name } } } type { kind name ofType { kind name } } } } sum: __type(name: "Token_sum_fields") { fields { name type { name } } } }`,
  },
  {
    name: "introspection-aggregate-types-hidden-public",
    query: `{ __type(name: "Token_aggregate_fields") { name } }`,
  },
  {
    name: "introspection-stream-cursor-types",
    query: `{ cursor: __type(name: "User_stream_cursor_input") { inputFields { name type { kind name ofType { kind name } } } } value: __type(name: "User_stream_cursor_value_input") { inputFields { name type { kind name } } } ordering: __type(name: "cursor_ordering") { enumValues { name description } } }`,
  },
  {
    name: "introspection-typename-on-typed-queries",
    query: `{ __type(name: "User") { __typename } __schema { __typename } }`,
  },
  {
    name: "introspection-mixed-with-data",
    query: `{ __schema { queryType { name } } User(order_by: {id: asc}, limit: 1) { id __typename } }`,
  },
  {
    name: "introspection-deprecated-flag",
    query: `{ __type(name: "query_root") { fields(includeDeprecated: true) { name isDeprecated } } }`,
  },
]);
