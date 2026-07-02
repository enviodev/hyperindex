import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "where-string-eq",
    query: `{ SimpleEntity(where: {value: {_eq: "v3"}}, order_by: {id: asc}) { id value } }`,
    bench: true,
  },
  {
    name: "where-string-neq",
    query: `{ SimpleEntity(where: {value: {_neq: "v3"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-string-in",
    query: `{ SimpleEntity(where: {id: {_in: ["simple-1", "simple-3", "missing"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-string-in-empty",
    query: `{ SimpleEntity(where: {id: {_in: []}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-string-nin",
    query: `{ SimpleEntity(where: {id: {_nin: ["simple-1", "simple-2"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-string-gt-lt",
    query: `{ SimpleEntity(where: {id: {_gt: "simple-2", _lt: "simple-5"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-string-gte-lte",
    query: `{ SimpleEntity(where: {id: {_gte: "simple-2", _lte: "simple-5"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-like",
    query: `{ User(where: {address: {_like: "%000001"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-nlike",
    query: `{ User(where: {address: {_nlike: "%000001"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-ilike",
    query: `{ User(where: {address: {_ilike: "0XAAAA%"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-nilike",
    query: `{ User(where: {address: {_nilike: "0XAAAA%02"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-similar",
    query: `{ SimpleEntity(where: {value: {_similar: "v(1|2)"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-nsimilar",
    query: `{ SimpleEntity(where: {value: {_nsimilar: "v(1|2)"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-regex",
    query: `{ SimpleEntity(where: {value: {_regex: "^v[13]$"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-iregex",
    query: `{ SimpleEntity(where: {value: {_iregex: "^V[13]$"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-niregex",
    query: `{ SimpleEntity(where: {value: {_niregex: "^V[13]$"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-like-escape-chars",
    query: `{ EntityWithAllNonArrayTypes(where: {string: {_like: "%\\"double\\"%"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-is-null-true",
    query: `{ User(where: {gravatar_id: {_is_null: true}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-is-null-false",
    query: `{ User(where: {gravatar_id: {_is_null: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-int-comparisons",
    query: `{ User(where: {updatesCountOnUserForTesting: {_gte: 0, _lt: 100}}, order_by: {id: asc}) { id updatesCountOnUserForTesting } }`,
  },
  {
    name: "where-int-negative",
    query: `{ User(where: {updatesCountOnUserForTesting: {_lt: 0}}, order_by: {id: asc}) { id updatesCountOnUserForTesting } }`,
  },
  {
    name: "where-numeric-eq-string-literal",
    query: `{ Token(where: {tokenId: {_eq: "1000000000000000000000000000000"}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "where-numeric-eq-int-literal",
    query: `{ Token(where: {tokenId: {_eq: 1}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "where-numeric-gt-huge",
    query: `{ Token(where: {tokenId: {_gt: "99999999999999999999999999999"}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "where-numeric-in-mixed",
    query: `{ Token(where: {tokenId: {_in: [0, "8", 10]}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "where-numeric-negative",
    query: `{ Token(where: {tokenId: {_lt: 0}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "where-float-eq",
    query: `{ EntityWithAllNonArrayTypes(where: {float_: {_eq: "3.14159"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-float-gt",
    query: `{ EntityWithAllNonArrayTypes(where: {float_: {_gt: 0}}, order_by: {id: asc}) { id float_ } }`,
  },
  {
    name: "where-bool-eq",
    query: `{ EntityWithAllNonArrayTypes(where: {bool: {_eq: true}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-enum-eq",
    query: `{ User(where: {accountType: {_eq: "ADMIN"}}, order_by: {id: asc}) { id accountType } }`,
  },
  {
    name: "where-enum-in",
    query: `{ User(where: {accountType: {_in: ["ADMIN", "USER"]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-enum-neq",
    query: `{ Gravatar(where: {size: {_neq: "SMALL"}}, order_by: {id: asc}) { id size } }`,
  },
  {
    name: "where-timestamp-eq",
    query: `{ EntityWithTimestamp(where: {timestamp: {_eq: "2024-01-15T12:34:56.123456+00:00"}}, order_by: {id: asc}) { id timestamp } }`,
  },
  {
    name: "where-timestamp-range",
    query: `{ EntityWithTimestamp(where: {timestamp: {_gte: "1970-01-01", _lt: "2025-01-01"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-timestamp-zoned-literal",
    query: `{ EntityWithTimestamp(where: {timestamp: {_eq: "2024-06-15T12:00:00+09:30"}}, order_by: {id: asc}) { id timestamp } }`,
  },
  {
    name: "where-and-implicit",
    query: `{ User(where: {accountType: {_eq: "USER"}, gravatar_id: {_is_null: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-and-explicit",
    query: `{ User(where: {_and: [{accountType: {_eq: "USER"}}, {updatesCountOnUserForTesting: {_gt: 0}}]}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-or",
    query: `{ User(where: {_or: [{id: {_eq: "user-1"}}, {id: {_eq: "user-2"}}]}, order_by: {id: asc}) { id } }`,
    bench: true,
  },
  {
    name: "where-not",
    query: `{ User(where: {_not: {accountType: {_eq: "ADMIN"}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-nested-and-or-not",
    query: `{ User(where: {_or: [{_and: [{accountType: {_eq: "ADMIN"}}, {_not: {updatesCountOnUserForTesting: {_lt: 0}}}]}, {id: {_like: "%quoted%"}}]}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-empty-bool-exp",
    query: `{ SimpleEntity(where: {}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-and-empty-list",
    query: `{ SimpleEntity(where: {_and: []}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-or-empty-list",
    query: `{ SimpleEntity(where: {_or: []}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-object-relationship",
    query: `{ Gravatar(where: {owner: {accountType: {_eq: "ADMIN"}}}, order_by: {id: asc}) { id owner { id } } }`,
  },
  {
    name: "where-array-relationship",
    query: `{ User(where: {tokens: {tokenId: {_gte: "9"}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-relationship-nested-two-levels",
    query: `{ NftCollection(where: {tokens: {owner: {accountType: {_eq: "ADMIN"}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-relationship-is-null-object",
    query: `{ User(where: {gravatar: {id: {_is_null: false}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-multiple-ops-same-column",
    query: `{ Token(where: {tokenId: {_gte: 1, _lte: 10, _neq: 8}}, order_by: {id: asc}) { id tokenId } }`,
  },
  {
    name: "where-unicode-value",
    query: `{ EntityWithAllNonArrayTypes(where: {string: {_eq: "héllo wörld 中文测试 🚀🎉"}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-empty-string-eq",
    query: `{ EntityWithAllNonArrayTypes(where: {string: {_eq: ""}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "where-variables-bool-exp",
    query: `query ($w: User_bool_exp!) { User(where: $w, order_by: {id: asc}) { id } }`,
    variables: { w: { accountType: { _eq: "ADMIN" } } },
  },
  {
    name: "where-variables-nested-exp",
    query: `query ($w: User_bool_exp) { User(where: $w, order_by: {id: asc}) { id } }`,
    variables: {
      w: { _or: [{ id: { _eq: "user-1" } }, { tokens: { tokenId: { _eq: 8 } } }] },
    },
  },
]);
