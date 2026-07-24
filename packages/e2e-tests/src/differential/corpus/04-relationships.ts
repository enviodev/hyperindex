import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "rel-object-basic",
    query: `{ Gravatar(order_by: {id: asc}) { id owner { id address accountType } } }`,
    bench: true,
  },
  {
    name: "rel-object-dangling",
    query: `{ Gravatar(where: {id: {_eq: "grav-3"}}) { id owner { id } } }`,
  },
  {
    name: "rel-object-nullable-fk",
    query: `{ User(order_by: {id: asc}) { id gravatar { id displayName size } } }`,
  },
  {
    name: "rel-array-basic",
    query: `{ User(order_by: {id: asc}) { id tokens(order_by: {id: asc}) { id tokenId } } }`,
    bench: true,
  },
  {
    name: "rel-array-empty",
    query: `{ User(where: {id: {_eq: "user-dangling"}}) { id tokens(order_by: {id: asc}) { id } } }`,
  },
  {
    name: "rel-array-nested-args",
    query: `{ User(order_by: {id: asc}) { id tokens(where: {tokenId: {_gte: 2}}, order_by: {tokenId: desc}, limit: 2) { id tokenId } } }`,
  },
  {
    name: "rel-array-nested-offset",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens(order_by: {tokenId: asc}, limit: 2, offset: 1) { id tokenId } } }`,
  },
  {
    name: "rel-array-distinct-on",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens(distinct_on: owner_id, order_by: [{owner_id: asc}, {tokenId: desc}]) { id owner_id } } }`,
  },
  {
    name: "rel-deep-nesting",
    query: `{ NftCollection(order_by: {id: asc}, limit: 2) { id tokens(order_by: {id: asc}, limit: 3) { id owner { id gravatar { id displayName } } } } }`,
  },
  {
    name: "rel-circular-nesting",
    query: `{ User(where: {id: {_eq: "user-1"}}) { id tokens(order_by: {id: asc}) { id owner { id tokens(order_by: {id: asc}, limit: 1) { id } } } } }`,
  },
  {
    name: "rel-abcd-chain",
    query: `{ B(order_by: {id: asc}) { id c { id a { id b { id } } } a(order_by: {id: asc}) { id optionalStringToTestLinkedEntities } } }`,
  },
  {
    name: "rel-derived-from-id-typed-key",
    query: `{ C(order_by: {id: asc}) { id d(order_by: {id: asc}) { id c } } }`,
  },
  {
    name: "rel-aliases-multiple-same-relationship",
    query: `{ User(where: {id: {_eq: "user-1"}}) { id low: tokens(where: {tokenId: {_lt: 1}}, order_by: {id: asc}) { id } high: tokens(where: {tokenId: {_gte: 1}}, order_by: {id: asc}) { id } } }`,
  },
  {
    name: "rel-fragment-on-relationship",
    query: `fragment TokenBits on Token { id tokenId collection { symbol } } { User(order_by: {id: asc}, limit: 3) { id tokens(order_by: {id: asc}) { ...TokenBits } } }`,
  },
  {
    name: "rel-typename-in-nested",
    query: `{ Gravatar(order_by: {id: asc}, limit: 2) { __typename owner { __typename id } } }`,
  },
  {
    name: "rel-where-on-parent-and-child",
    query: `{ User(where: {tokens: {collection: {symbol: {_eq: "ALPHA"}}}}, order_by: {id: asc}) { id tokens(where: {collection: {symbol: {_eq: "ALPHA"}}}, order_by: {id: asc}) { id collection { symbol } } } }`,
  },
  {
    name: "rel-order-parent-by-child-aggregate-count",
    query: `{ User(order_by: [{tokens_aggregate: {count: desc}}, {id: asc}]) { id } }`,
    role: "admin",
  },
  {
    name: "rel-order-parent-by-child-aggregate-max",
    query: `{ NftCollection(order_by: [{tokens_aggregate: {max: {tokenId: desc_nulls_last}}}, {id: asc}]) { id } }`,
    role: "admin",
  },
]);
