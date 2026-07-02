import { defineCases } from "../corpus.js";

// Relationship edge matrix: existence filters ({rel: {}} / _not: {rel: {}}),
// dangling FKs for every object relationship in the fixture, multi-hop
// A→B→C→D traversals, cross-boundary boolean logic, child selection args
// combined, aggregate ordering with nulls, and alias/column shadowing.
export default defineCases([
  // ── array-rel existence: {rel: {}} = has any, _not: {rel: {}} = has none ──
  {
    name: "rm-exists-user-tokens-pair",
    query: `{ any: User(where: {tokens: {}}, order_by: {id: asc}) { id } none: User(where: {_not: {tokens: {}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rm-exists-collection-tokens-pair",
    query: `{ any: NftCollection(where: {tokens: {}}, order_by: {id: asc}) { id name } none: NftCollection(where: {_not: {tokens: {}}}, order_by: {id: asc}) { id name } }`,
  },
  {
    name: "rm-exists-b-a-pair",
    query: `{ any: B(where: {a: {}}, order_by: {id: asc}) { id } none: B(where: {_not: {a: {}}}, order_by: {id: asc}) { id } }`,
  },
  {
    // The `none` root is deliberately empty: every D row with a live c
    // reference makes its C non-empty, and dangling d-4 belongs to no C.
    name: "rm-exists-c-d-pair",
    query: `{ any: C(where: {d: {}}, order_by: {id: asc}) { id } none: C(where: {_not: {d: {}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rm-exists-bare-vs-predicate",
    query: `{ bare: NftCollection(where: {tokens: {}}, order_by: {id: asc}) { id } withPred: NftCollection(where: {tokens: {tokenId: {_gt: 1000}}}, order_by: {id: asc}) { id } }`,
  },

  // ── object-rel existence vs FK null-ness ─────────────────────────────
  {
    name: "rm-object-exists-gravatar-pair",
    query: `{ has: User(where: {gravatar: {}}, order_by: {id: asc}) { id gravatar_id } lacks: User(where: {_not: {gravatar: {}}}, order_by: {id: asc}) { id gravatar_id } }`,
  },
  {
    // user-dangling has a non-null gravatar_id pointing nowhere, so it is in
    // fkNotNull but not in exists.
    name: "rm-object-exists-vs-fk-not-null",
    query: `{ exists: User(where: {gravatar: {}}, order_by: {id: asc}) { id } fkNotNull: User(where: {gravatar_id: {_is_null: false}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rm-object-not-exists-token-owner",
    query: `{ Token(where: {_not: {owner: {}}}, order_by: {id: asc}) { id owner_id } }`,
  },
  {
    name: "rm-object-not-exists-token-collection",
    query: `{ Token(where: {_not: {collection: {}}}, order_by: {id: asc}) { id collection_id } }`,
  },
  {
    name: "rm-object-not-exists-gravatar-owner",
    query: `{ Gravatar(where: {_not: {owner: {}}}, order_by: {id: asc}) { id owner_id } }`,
  },
  {
    // b-2 (NULL c_id) and b-3 (dangling c_id) both count as "no c".
    name: "rm-object-not-exists-b-c",
    query: `{ B(where: {_not: {c: {}}}, order_by: {id: asc}) { id c_id } }`,
  },
  {
    name: "rm-object-exists-a-b-pair",
    query: `{ has: A(where: {b: {}}, order_by: {id: asc}) { id b_id } lacks: A(where: {_not: {b: {}}}, order_by: {id: asc}) { id b_id } }`,
  },

  // ── dangling FK output shape for every object relationship ───────────
  {
    name: "rm-dangling-token-collection",
    query: `{ Token_by_pk(id: "tok-7") { id collection_id collection { id name } } }`,
  },
  {
    name: "rm-dangling-token-owner",
    query: `{ Token_by_pk(id: "tok-6") { id owner_id owner { id address } } }`,
  },
  {
    name: "rm-dangling-gravatar-owner",
    query: `{ Gravatar_by_pk(id: "grav-3") { id owner_id owner { id address } } }`,
  },
  {
    name: "rm-dangling-user-gravatar",
    query: `{ User_by_pk(id: "user-dangling") { id gravatar_id gravatar { id displayName } } }`,
  },
  {
    name: "rm-dangling-b-c-all-rows",
    query: `{ B(order_by: {id: asc}) { id c_id c { id stringThatIsMirroredToA } } }`,
  },
  {
    name: "rm-dangling-a-b",
    query: `{ A_by_pk(id: "a-4") { id b_id b { id c_id } } }`,
  },
  {
    // d-4 references c-missing: reachable through its plain text column but
    // through no C.d relationship.
    name: "rm-dangling-d-via-rel-vs-column",
    query: `{ viaRel: C(where: {d: {id: {_eq: "d-4"}}}, order_by: {id: asc}) { id } viaColumn: D(where: {c: {_eq: "c-missing"}}, order_by: {id: asc}) { id c } }`,
  },

  // ── multi-hop A→B→C→D traversals ─────────────────────────────────────
  {
    name: "rm-multihop-a-b-c-d",
    query: `{ A(order_by: {id: asc}) { id optionalStringToTestLinkedEntities b { id c { id stringThatIsMirroredToA d(order_by: {id: asc}) { id c } } } } }`,
  },
  {
    name: "rm-multihop-c-both-directions",
    query: `{ C(order_by: {id: asc}) { id a { id b { id c { id } } } d(order_by: {id: asc}) { id } } }`,
  },
  {
    name: "rm-multihop-b-both-directions",
    query: `{ B(order_by: {id: asc}) { id a(order_by: {id: asc}) { id b { id } } c { id d(order_by: {id: asc}) { id } } } }`,
  },
  {
    // In D_bool_exp `c` is a plain String comparison, not a relationship.
    name: "rm-multihop-d-plain-column-filter",
    query: `{ C(where: {d: {c: {_eq: "c-1"}}}, order_by: {id: asc}) { id d(where: {c: {_eq: "c-1"}}, order_by: {id: asc}) { id c } } }`,
  },
  {
    name: "rm-multihop-a-b-a-siblings",
    query: `{ A(order_by: {id: asc}) { id b { id a(order_by: {id: asc}) { id } } } }`,
  },

  // ── array rel with where + distinct_on + order_by + limit + offset ───
  {
    name: "rm-child-all-args-user-tokens",
    query: `{ User(order_by: {id: asc}) { id tokens(where: {tokenId: {_gte: 0}}, distinct_on: collection_id, order_by: [{collection_id: asc}, {tokenId: desc}, {id: asc}], limit: 2, offset: 1) { id collection_id tokenId } } }`,
  },
  {
    name: "rm-child-all-args-collection-tokens",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens(where: {owner: {accountType: {_eq: "USER"}}}, distinct_on: owner_id, order_by: [{owner_id: asc}, {tokenId: desc}, {id: asc}], limit: 2, offset: 1) { id owner_id tokenId } } }`,
  },
  {
    // Deliberately empty child arrays: offset beyond every child row set.
    name: "rm-child-window-beyond-rows",
    query: `{ User(where: {id: {_in: ["user-1", "user-2"]}}, order_by: {id: asc}) { id tokens(order_by: {id: asc}, limit: 3, offset: 50) { id } } }`,
  },

  // ── _and/_or/_not spanning the relationship boundary ─────────────────
  {
    name: "rm-cross-and-parent-child",
    query: `{ User(where: {_and: [{accountType: {_eq: "ADMIN"}}, {tokens: {collection: {symbol: {_eq: "ALPHA"}}}}]}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rm-cross-or-three-branches",
    query: `{ Token(where: {_or: [{tokenId: {_lt: 0}}, {owner: {accountType: {_eq: "ADMIN"}}}, {collection: {name: {_eq: ""}}}]}, order_by: {id: asc}) { id tokenId owner_id collection_id } }`,
  },
  {
    // Users owning a token whose collection row is missing (tok-7).
    name: "rm-cross-not-inside-rel",
    query: `{ User(where: {tokens: {_not: {collection: {}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rm-cross-and-inside-rel",
    query: `{ User(where: {tokens: {_and: [{tokenId: {_gte: 0}}, {collection: {symbol: {_eq: "BÉTA"}}}]}}, order_by: {id: asc}) { id } }`,
  },
  {
    name: "rm-cross-or-two-rel-paths",
    query: `{ User(where: {_or: [{gravatar: {size: {_eq: "MEDIUM"}}}, {tokens: {tokenId: {_eq: "9999999999999999999999999999999999999999999999999999999999999999999999999999"}}}]}, order_by: {id: asc}) { id } }`,
  },

  // ── same table reached via different relationship paths ──────────────
  {
    name: "rm-same-table-two-paths",
    query: `{ User(where: {tokens: {collection: {tokens: {owner: {accountType: {_eq: "USER"}}}}}}, order_by: {id: asc}) { id } }`,
  },
  {
    // ADMIN-owned tokens whose collection also holds a USER-owned sibling.
    name: "rm-same-table-token-and-sibling",
    query: `{ Token(where: {_and: [{owner: {accountType: {_eq: "ADMIN"}}}, {collection: {tokens: {owner: {accountType: {_eq: "USER"}}}}}]}, order_by: {id: asc}) { id owner_id collection_id } }`,
  },
  {
    name: "rm-same-table-b-self-join",
    query: `{ A(where: {b: {a: {id: {_eq: "a-2"}}}}, order_by: {id: asc}) { id b_id } }`,
  },

  // ── self-referential deep nesting ────────────────────────────────────
  {
    name: "rm-deep-self-nesting-depth7",
    query: `{ User(where: {id: {_eq: "user-1"}}) { id tokens(order_by: {id: asc}, limit: 2) { id owner { id tokens(order_by: {id: asc}, limit: 2) { id owner { id tokens(order_by: {id: asc}, limit: 2) { id tokenId owner { id } } } } } } } }`,
  },
  {
    name: "rm-deep-where-self-referential",
    query: `{ User(where: {tokens: {owner: {tokens: {owner: {tokens: {tokenId: {_eq: "8"}}}}}}}, order_by: {id: asc}) { id } }`,
  },

  // ── parent ordered by child aggregate, with nulls from empty sets ────
  {
    // coll-3 has no tokens, so its max is NULL and sorts first.
    name: "rm-agg-order-max-nulls-first",
    query: `{ NftCollection(order_by: [{tokens_aggregate: {max: {tokenId: asc_nulls_first}}}, {id: asc}]) { id } }`,
  },
  {
    name: "rm-agg-order-count-asc-empty-first",
    query: `{ NftCollection(order_by: [{tokens_aggregate: {count: asc}}, {id: asc}]) { id currentSupply } }`,
  },
  {
    name: "rm-agg-order-sum-desc-nulls-last",
    query: `{ User(order_by: [{tokens_aggregate: {sum: {tokenId: desc_nulls_last}}}, {id: asc}]) { id } }`,
  },
  {
    name: "rm-agg-order-min-asc-nulls-first",
    query: `{ User(order_by: [{tokens_aggregate: {min: {tokenId: asc_nulls_first}}}, {id: asc}]) { id } }`,
  },
  {
    // tok-7's dangling collection yields a NULL join, sorting first.
    name: "rm-order-object-rel-dangling-nulls-first",
    query: `{ Token(order_by: [{collection: {name: asc_nulls_first}}, {id: asc}]) { id collection_id } }`,
  },

  // ── alias shadowing between relationships and columns ────────────────
  {
    name: "rm-alias-swap-column-and-rel",
    query: `{ Token(order_by: {id: asc}, limit: 4) { id owner: owner_id owner_id: owner { id } collection: collection_id collection_id: collection { id name } } }`,
  },
  {
    name: "rm-alias-user-gravatar-shadow",
    query: `{ User(order_by: {id: asc}, limit: 3) { id gravatar: gravatar_id gravatar_id: gravatar { id displayName } tokens: address address: tokens(order_by: {id: asc}, limit: 1) { id } } }`,
  },
  {
    // Field-merge conflict: response key "owner" bound to both the scalar
    // owner_id column and the owner relationship.
    name: "rm-alias-conflict-rel-vs-column",
    query: `{ Token(limit: 1) { owner: owner_id owner { id } } }`,
  },
]);
