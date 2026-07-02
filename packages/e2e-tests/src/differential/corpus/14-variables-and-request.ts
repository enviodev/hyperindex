import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "vr-var-string-where",
    query: `query ($v: String!) { SimpleEntity(where: {value: {_eq: $v}}, order_by: {id: asc}) { id value } }`,
    variables: { v: "v3" },
  },
  {
    name: "vr-var-int-limit-offset",
    query: `query ($l: Int!, $o: Int!) { SimpleEntity(order_by: {id: asc}, limit: $l, offset: $o) { id } }`,
    variables: { l: 3, o: 2 },
  },
  {
    name: "vr-var-float8-number",
    query: `query ($f: float8!) { EntityWithAllNonArrayTypes(where: {float_: {_gt: $f}}, order_by: {id: asc}) { id float_ } }`,
    variables: { f: 0.5 },
  },
  {
    // Hasura accepts a JSON string for a float8 variable.
    name: "vr-var-float8-string-coerced",
    query: `query ($f: float8!) { EntityWithAllNonArrayTypes(where: {float_: {_eq: $f}}, order_by: {id: asc}) { id float_ } }`,
    variables: { f: "1.5" },
  },
  {
    // A JSON string "true" coerces to boolean in a column comparison…
    name: "vr-var-boolean-string-in-where-coerced",
    query: `query ($b: Boolean!) { EntityWithAllNonArrayTypes(where: {bool: {_eq: $b}}, order_by: {id: asc}) { id bool } }`,
    variables: { b: "true" },
  },
  {
    // …but the same string is rejected when used in a directive's if.
    name: "vr-error-boolean-string-in-include-directive",
    query: `query ($b: Boolean!) { SimpleEntity(order_by: {id: asc}, limit: 1) { id value @include(if: $b) } }`,
    variables: { b: "true" },
  },
  {
    name: "vr-var-numeric-as-string",
    query: `query ($n: numeric!) { Token(where: {tokenId: {_eq: $n}}, order_by: {id: asc}) { id tokenId } }`,
    variables: { n: "1000000000000000000000000000000" },
  },
  {
    name: "vr-var-numeric-as-number",
    query: `query ($n: numeric!) { Token(where: {tokenId: {_eq: $n}}, order_by: {id: asc}) { id tokenId } }`,
    variables: { n: 8 },
  },
  {
    name: "vr-var-numeric-decimal-number",
    query: `query ($n: numeric!) { EntityWithAllNonArrayTypes(where: {bigDecimal: {_eq: $n}}, order_by: {id: asc}) { id bigDecimal } }`,
    variables: { n: 1.25 },
  },
  {
    name: "vr-var-timestamptz-string",
    query: `query ($ts: timestamptz!) { EntityWithTimestamp(where: {timestamp: {_eq: $ts}}, order_by: {id: asc}) { id timestamp } }`,
    variables: { ts: "2024-01-15T12:34:56.123456+00:00" },
  },
  {
    name: "vr-var-enum-scalar-accounttype",
    query: `query ($t: accounttype!) { User(where: {accountType: {_eq: $t}}, order_by: {id: asc}) { id accountType } }`,
    variables: { t: "ADMIN" },
  },
  {
    // Passes GraphQL validation (accounttype is a scalar) and fails in
    // Postgres with a data-exception.
    name: "vr-error-enum-scalar-invalid-value",
    query: `query ($t: accounttype!) { User(where: {accountType: {_eq: $t}}, order_by: {id: asc}) { id } }`,
    variables: { t: "SUPERADMIN" },
  },
  {
    name: "vr-var-jsonb-object-contains",
    query: `query ($j: jsonb!) { EntityWithAllTypes(where: {json: {_contains: $j}}, order_by: {id: asc}) { id json } }`,
    variables: { j: { kind: "object" } },
  },
  {
    name: "vr-var-jsonb-unicode-contains",
    query: `query ($j: jsonb!) { EntityWithAllTypes(where: {json: {_contains: $j}}, order_by: {id: asc}) { id } }`,
    variables: { j: { héllo: "wörld 🚀" } },
  },
  {
    name: "vr-var-string-list-in",
    query: `query ($ids: [String!]!) { SimpleEntity(where: {id: {_in: $ids}}, order_by: {id: asc}) { id } }`,
    variables: { ids: ["simple-1", "simple-9", "missing"] },
  },
  {
    name: "vr-var-string-list-single-value-coercion",
    query: `query ($ids: [String!]!) { SimpleEntity(where: {id: {_in: $ids}}, order_by: {id: asc}) { id } }`,
    variables: { ids: "simple-1" },
  },
  {
    name: "vr-error-string-list-int-element",
    query: `query ($ids: [String!]!) { SimpleEntity(where: {id: {_in: $ids}}, order_by: {id: asc}) { id } }`,
    variables: { ids: 5 },
  },
  {
    name: "vr-var-bool-exp-token",
    query: `query ($w: Token_bool_exp!) { Token(where: $w, order_by: {id: asc}) { id tokenId } }`,
    variables: { w: { tokenId: { _gte: 7 } } },
  },
  {
    name: "vr-var-order-by-list",
    query: `query ($ord: [Token_order_by!]!) { Token(order_by: $ord, limit: 4) { id tokenId owner_id } }`,
    variables: { ord: [{ owner_id: "asc" }, { tokenId: "desc" }, { id: "asc" }] },
  },
  {
    name: "vr-var-order-by-enum-in-object-default",
    query: `query ($dir: order_by = desc) { SimpleEntity(order_by: [{id: $dir}]) { id } }`,
  },
  {
    name: "vr-var-select-column-distinct-on",
    query: `query ($cols: [Token_select_column!]!) { Token(distinct_on: $cols, order_by: [{owner_id: asc}, {tokenId: desc}, {id: asc}]) { id owner_id } }`,
    variables: { cols: ["owner_id"] },
  },
  {
    name: "vr-var-select-column-single-value-coercion",
    query: `query ($cols: [Token_select_column!]!) { Token(distinct_on: $cols, order_by: [{collection_id: asc}, {tokenId: desc}, {id: asc}]) { id collection_id } }`,
    variables: { cols: "collection_id" },
  },
  {
    name: "vr-var-nested-relationship-args",
    query: `query ($tw: Token_bool_exp, $tl: Int, $tord: [Token_order_by!]) { User(order_by: {id: asc}) { id tokens(where: $tw, limit: $tl, order_by: $tord) { id tokenId } } }`,
    variables: {
      tw: { tokenId: { _gte: 0 } },
      tl: 2,
      tord: [{ tokenId: "desc" }, { id: "asc" }],
    },
  },
  {
    name: "vr-default-bool-exp-used",
    query: `query ($w: SimpleEntity_bool_exp = {id: {_eq: "simple-2"}}) { SimpleEntity(where: $w, order_by: {id: asc}) { id value } }`,
  },
  {
    name: "vr-default-int-overridden",
    query: `query ($lim: Int = 2) { SimpleEntity(order_by: {id: asc}, limit: $lim) { id } }`,
    variables: { lim: 1 },
  },
  {
    name: "vr-default-null-override",
    query: `query ($lim: Int = 2) { SimpleEntity(order_by: {id: asc}, limit: $lim) { id } }`,
    variables: { lim: null },
  },
  {
    name: "vr-var-missing-variables-object",
    query: `query ($w: SimpleEntity_bool_exp) { SimpleEntity(where: $w, order_by: {id: asc}) { id } }`,
  },
  {
    name: "vr-var-null-for-nullable-args",
    query: `query ($w: SimpleEntity_bool_exp, $l: Int) { SimpleEntity(where: $w, limit: $l, order_by: {id: asc}) { id } }`,
    variables: { w: null, l: null },
  },
  {
    name: "vr-error-int-var-float-json",
    query: `query ($l: Int!) { SimpleEntity(order_by: {id: asc}, limit: $l) { id } }`,
    variables: { l: 1.5 },
  },
  {
    name: "vr-error-int-var-string-json",
    query: `query ($l: Int!) { SimpleEntity(order_by: {id: asc}, limit: $l) { id } }`,
    variables: { l: "1" },
  },
  {
    name: "vr-error-numeric-var-bool",
    query: `query ($n: numeric!) { Token(where: {tokenId: {_eq: $n}}, order_by: {id: asc}) { id } }`,
    variables: { n: true },
  },
  {
    name: "vr-error-extra-undeclared-variable",
    query: `query ($l: Int) { SimpleEntity(order_by: {id: asc}, limit: $l) { id } }`,
    variables: { l: 2, extraneous: "ignored", another: 5 },
  },
  {
    name: "vr-error-id-type-variable",
    query: `query ($id: ID!) { User_by_pk(id: $id) { id } }`,
    variables: { id: "user-1" },
  },
  {
    name: "vr-error-opname-with-anonymous-op",
    query: `query A { SimpleEntity(order_by: {id: asc}, limit: 1) { id } } { User(order_by: {id: asc}, limit: 1) { id } }`,
    operationName: "A",
  },
  {
    name: "vr-opname-selects-op-with-vars",
    query: `query WithVar($v: String!) { SimpleEntity(where: {value: {_eq: $v}}, order_by: {id: asc}) { id value } } query NoVar { User(order_by: {id: asc}, limit: 1) { id } }`,
    operationName: "WithVar",
    variables: { v: "v2" },
  },
  {
    // Only the selected operation is validated: the mutation would be
    // invalid for the public role, yet the query still runs.
    name: "vr-opname-query-beside-mutation-public",
    query: `query Q { SimpleEntity(order_by: {id: asc}, limit: 1) { id } } mutation M { insert_Bogus(objects: []) { affected_rows } }`,
    operationName: "Q",
  },
  {
    name: "vr-admin-mutation-insert-unknown-table",
    role: "admin",
    query: `mutation { insert_Bogus(objects: []) { affected_rows } }`,
  },
  // envio serve is a read-only server: Hasura's admin mutation surface is
  // deliberately out of scope, so only mutation cases whose responses don't
  // depend on mutation types existing (unknown-table errors) are kept.
  {
    name: "vr-directive-include-fragment-spread",
    query: `query ($inc: Boolean!) { User(order_by: {id: asc}, limit: 2) { id ...Extra @include(if: $inc) } } fragment Extra on User { address accountType }`,
    variables: { inc: true },
  },
  {
    name: "vr-directive-include-fragment-spread-false",
    query: `query ($inc: Boolean!) { User(order_by: {id: asc}, limit: 2) { id ...Extra @include(if: $inc) } } fragment Extra on User { address accountType }`,
    variables: { inc: false },
  },
  {
    name: "vr-directive-skip-inline-fragment",
    query: `query ($skip: Boolean!) { User(order_by: {id: asc}, limit: 2) { id ... on User @skip(if: $skip) { address } } }`,
    variables: { skip: true },
  },
  {
    name: "vr-error-directive-include-on-operation",
    query: `query Q @include(if: true) { SimpleEntity(order_by: {id: asc}, limit: 1) { id } }`,
  },
  {
    name: "vr-alias-duplicate-root-different-args",
    query: `{ few: SimpleEntity(order_by: {id: asc}, limit: 2) { id } more: SimpleEntity(order_by: {id: desc}, limit: 3) { id value } one: SimpleEntity_by_pk(id: "simple-5") { id } miss: SimpleEntity_by_pk(id: "nope") { id } }`,
  },
  {
    name: "vr-error-same-alias-conflicting-args",
    query: `{ x: SimpleEntity(order_by: {id: asc}, limit: 1) { id } x: SimpleEntity(order_by: {id: desc}, limit: 1) { id } }`,
  },
  {
    name: "vr-fragment-chain-deep",
    query: `fragment L1 on User { id ...L2 } fragment L2 on User { gravatar { ...L3 } } fragment L3 on Gravatar { id owner { ...L4 } } fragment L4 on User { address tokens(order_by: {id: asc}, limit: 1) { ...L5 } } fragment L5 on Token { id tokenId } { User(order_by: {id: asc}) { ...L1 } }`,
  },
  {
    name: "vr-typename-nested-everywhere",
    query: `{ User(order_by: {id: asc}) { __typename id gravatar { __typename id } tokens(order_by: {id: asc}) { __typename id collection { __typename id } } } }`,
  },
  {
    name: "vr-typename-aggregate-admin",
    role: "admin",
    query: `{ Token_aggregate(order_by: {id: asc}) { __typename aggregate { __typename count sum { __typename tokenId } } nodes { __typename id } } }`,
  },
]);
