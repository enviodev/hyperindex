import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "om-order-text-asc",
    query: `{ SimpleEntity(order_by: [{value: asc}, {id: asc}]) { id value } }`,
  },
  {
    name: "om-order-int-asc",
    query: `{ User(order_by: [{updatesCountOnUserForTesting: asc}, {id: asc}]) { id updatesCountOnUserForTesting } }`,
  },
  {
    name: "om-order-int-desc",
    query: `{ User(order_by: [{updatesCountOnUserForTesting: desc}, {id: asc}]) { id updatesCountOnUserForTesting } }`,
  },
  {
    name: "om-order-numeric-bigint-asc",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{bigInt: asc}, {id: asc}]) { id bigInt } }`,
  },
  {
    name: "om-order-numeric-bigdecimal-desc",
    query: `{ EntityWithBigDecimal(order_by: [{bigDecimal: desc}, {id: asc}]) { id bigDecimal } }`,
  },
  {
    name: "om-order-bool-desc",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{bool: desc}, {id: asc}]) { id bool } }`,
  },
  {
    name: "om-order-enum-desc",
    query: `{ Gravatar(order_by: [{size: desc}, {id: asc}]) { id size } }`,
  },
  {
    name: "om-order-timestamp-desc",
    query: `{ EntityWithTimestamp(order_by: [{timestamp: desc}, {id: asc}]) { id timestamp } }`,
  },
  {
    name: "om-order-bigint-raw-events-asc",
    query: `{ raw_events(order_by: [{event_id: asc}, {serial: asc}]) { serial chain_id event_id } }`,
  },
  {
    name: "om-order-bigint-raw-events-desc",
    query: `{ raw_events(order_by: [{event_id: desc}, {serial: asc}]) { serial chain_id event_id } }`,
  },
  {
    // jsonb columns are orderable: PG jsonb btree order ranks
    // Object > Array > Boolean > Number > String > Null.
    name: "om-order-jsonb-asc",
    query: `{ EntityWithAllTypes(order_by: [{json: asc}, {id: asc}]) { id json } }`,
  },
  {
    name: "om-order-jsonb-desc-raw-events",
    query: `{ raw_events(order_by: [{params: desc}, {serial: asc}]) { serial params } }`,
  },
  {
    name: "om-order-float-special-desc",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{float_: desc}, {id: asc}]) { id float_ } }`,
  },
  {
    // PG sorts NaN greater than every other float, including Infinity,
    // but null ordering still applies separately (asc defaults to nulls last).
    name: "om-order-optfloat-nan-asc",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{optFloat: asc}, {id: asc}]) { id optFloat } }`,
  },
  {
    name: "om-order-optfloat-nan-desc-nulls-last",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{optFloat: desc_nulls_last}, {id: asc}]) { id optFloat } }`,
  },
  {
    name: "om-order-directions-opt-text",
    query: `{ d1: User(order_by: [{gravatar_id: asc}, {id: asc}]) { id gravatar_id } d2: User(order_by: [{gravatar_id: desc}, {id: asc}]) { id gravatar_id } d3: User(order_by: [{gravatar_id: asc_nulls_first}, {id: asc}]) { id gravatar_id } d4: User(order_by: [{gravatar_id: asc_nulls_last}, {id: asc}]) { id gravatar_id } d5: User(order_by: [{gravatar_id: desc_nulls_first}, {id: asc}]) { id gravatar_id } d6: User(order_by: [{gravatar_id: desc_nulls_last}, {id: asc}]) { id gravatar_id } }`,
  },
  {
    name: "om-order-directions-opt-int",
    query: `{ d1: EntityWithAllNonArrayTypes(order_by: [{optInt: asc}, {id: asc}]) { id optInt } d2: EntityWithAllNonArrayTypes(order_by: [{optInt: desc}, {id: asc}]) { id optInt } d3: EntityWithAllNonArrayTypes(order_by: [{optInt: asc_nulls_first}, {id: asc}]) { id optInt } d4: EntityWithAllNonArrayTypes(order_by: [{optInt: asc_nulls_last}, {id: asc}]) { id optInt } d5: EntityWithAllNonArrayTypes(order_by: [{optInt: desc_nulls_first}, {id: asc}]) { id optInt } d6: EntityWithAllNonArrayTypes(order_by: [{optInt: desc_nulls_last}, {id: asc}]) { id optInt } }`,
  },
  {
    name: "om-order-directions-opt-float",
    query: `{ d1: EntityWithAllNonArrayTypes(order_by: [{optFloat: asc}, {id: asc}]) { id optFloat } d2: EntityWithAllNonArrayTypes(order_by: [{optFloat: desc}, {id: asc}]) { id optFloat } d3: EntityWithAllNonArrayTypes(order_by: [{optFloat: asc_nulls_first}, {id: asc}]) { id optFloat } d4: EntityWithAllNonArrayTypes(order_by: [{optFloat: asc_nulls_last}, {id: asc}]) { id optFloat } d5: EntityWithAllNonArrayTypes(order_by: [{optFloat: desc_nulls_first}, {id: asc}]) { id optFloat } d6: EntityWithAllNonArrayTypes(order_by: [{optFloat: desc_nulls_last}, {id: asc}]) { id optFloat } }`,
  },
  {
    name: "om-order-directions-opt-bigint",
    query: `{ d1: EntityWithAllNonArrayTypes(order_by: [{optBigInt: asc}, {id: asc}]) { id optBigInt } d2: EntityWithAllNonArrayTypes(order_by: [{optBigInt: desc}, {id: asc}]) { id optBigInt } d3: EntityWithAllNonArrayTypes(order_by: [{optBigInt: asc_nulls_first}, {id: asc}]) { id optBigInt } d4: EntityWithAllNonArrayTypes(order_by: [{optBigInt: asc_nulls_last}, {id: asc}]) { id optBigInt } d5: EntityWithAllNonArrayTypes(order_by: [{optBigInt: desc_nulls_first}, {id: asc}]) { id optBigInt } d6: EntityWithAllNonArrayTypes(order_by: [{optBigInt: desc_nulls_last}, {id: asc}]) { id optBigInt } }`,
  },
  {
    name: "om-order-directions-opt-timestamp",
    query: `{ d1: EntityWithAllNonArrayTypes(order_by: [{optTimestamp: asc}, {id: asc}]) { id optTimestamp } d2: EntityWithAllNonArrayTypes(order_by: [{optTimestamp: desc}, {id: asc}]) { id optTimestamp } d3: EntityWithAllNonArrayTypes(order_by: [{optTimestamp: asc_nulls_first}, {id: asc}]) { id optTimestamp } d4: EntityWithAllNonArrayTypes(order_by: [{optTimestamp: asc_nulls_last}, {id: asc}]) { id optTimestamp } d5: EntityWithAllNonArrayTypes(order_by: [{optTimestamp: desc_nulls_first}, {id: asc}]) { id optTimestamp } d6: EntityWithAllNonArrayTypes(order_by: [{optTimestamp: desc_nulls_last}, {id: asc}]) { id optTimestamp } }`,
  },
  {
    name: "om-order-directions-opt-enum",
    query: `{ d1: EntityWithAllNonArrayTypes(order_by: [{optEnumField: asc}, {id: asc}]) { id optEnumField } d2: EntityWithAllNonArrayTypes(order_by: [{optEnumField: desc}, {id: asc}]) { id optEnumField } d3: EntityWithAllNonArrayTypes(order_by: [{optEnumField: asc_nulls_first}, {id: asc}]) { id optEnumField } d4: EntityWithAllNonArrayTypes(order_by: [{optEnumField: asc_nulls_last}, {id: asc}]) { id optEnumField } d5: EntityWithAllNonArrayTypes(order_by: [{optEnumField: desc_nulls_first}, {id: asc}]) { id optEnumField } d6: EntityWithAllNonArrayTypes(order_by: [{optEnumField: desc_nulls_last}, {id: asc}]) { id optEnumField } }`,
  },
  {
    name: "om-order-multi-conflicting",
    query: `{ SimulateTestEvent(order_by: [{blockNumber: asc}, {logIndex: desc}, {id: asc}]) { id blockNumber logIndex } }`,
  },
  {
    name: "om-order-multi-conflicting-flipped",
    query: `{ SimulateTestEvent(order_by: [{blockNumber: desc}, {logIndex: asc}, {id: asc}]) { id blockNumber logIndex } }`,
  },
  {
    name: "om-order-multi-list-respects-order",
    query: `{ SimulateTestEvent(order_by: [{logIndex: desc}, {blockNumber: asc}, {id: asc}]) { id blockNumber logIndex } }`,
  },
  {
    // Key order inside a single multi-key order_by object is NOT preserved:
    // Hasura canonicalizes the keys, so this and the case below return the
    // same rows, both differing from the list form above.
    name: "om-order-object-keys-logindex-first",
    query: `{ SimulateTestEvent(order_by: {logIndex: desc, blockNumber: asc, id: asc}) { id blockNumber logIndex } }`,
  },
  {
    name: "om-order-object-keys-blocknumber-first",
    query: `{ SimulateTestEvent(order_by: {blockNumber: asc, logIndex: desc, id: asc}) { id blockNumber logIndex } }`,
  },
  {
    name: "om-order-mixed-list-with-multikey-object",
    query: `{ SimulateTestEvent(order_by: [{blockNumber: desc, logIndex: desc}, {id: asc}]) { id blockNumber logIndex } }`,
  },
  {
    name: "om-order-same-column-twice-list",
    query: `{ SimulateTestEvent(order_by: [{blockNumber: asc}, {blockNumber: desc}, {id: asc}]) { id blockNumber } }`,
  },
  {
    name: "om-order-object-rel-owner-id",
    query: `{ Token(order_by: [{owner: {id: asc}}, {id: asc}]) { id owner { id } } }`,
  },
  {
    name: "om-order-object-rel-two-levels",
    query: `{ Token(order_by: [{owner: {gravatar: {displayName: asc}}}, {id: asc}]) { id } }`,
  },
  {
    // Aggregate ordering through relationships is exposed regardless of the
    // allow_aggregations permission; both phases pin that.
    name: "om-order-object-rel-nested-aggregate",
    query: `{ Token(order_by: [{collection: {tokens_aggregate: {count: asc}}}, {id: asc}]) { id collection_id } }`,
    phases: ["default", "limited"],
  },
  {
    name: "om-order-array-rel-aggregate-count-desc",
    query: `{ User(order_by: [{tokens_aggregate: {count: desc}}, {id: asc}]) { id } }`,
    phases: ["default", "limited"],
  },
  {
    name: "om-order-array-rel-aggregate-max",
    query: `{ User(order_by: [{tokens_aggregate: {max: {tokenId: desc}}}, {id: asc}]) { id } }`,
    phases: ["default", "limited"],
  },
  {
    name: "om-introspect-user-order-by",
    query: `{ __type(name: "User_order_by") { inputFields { name type { name kind } } } }`,
    phases: ["default", "limited"],
  },
  {
    name: "om-introspect-token-aggregate-order-by",
    query: `{ __type(name: "Token_aggregate_order_by") { inputFields { name type { name kind } } } }`,
    phases: ["default", "limited"],
  },
  {
    name: "om-distinct-extra-order-keys",
    query: `{ Token(distinct_on: owner_id, order_by: [{owner_id: asc}, {tokenId: desc}, {id: asc}]) { owner_id tokenId id } }`,
  },
  {
    name: "om-distinct-same-column-twice",
    query: `{ Token(distinct_on: [owner_id, owner_id], order_by: [{owner_id: asc}, {id: asc}]) { owner_id id } }`,
  },
  {
    // The order_by prefix must contain the distinct_on columns but may list
    // them in a different order.
    name: "om-distinct-multi-prefix-swapped",
    query: `{ SimulateTestEvent(distinct_on: [blockNumber, logIndex], order_by: [{logIndex: asc}, {blockNumber: asc}, {id: asc}]) { id blockNumber logIndex } }`,
  },
  {
    name: "om-distinct-no-order-by",
    query: `{ Token(distinct_on: owner_id) { owner_id } }`,
    compare: "rootSet",
  },
  {
    name: "om-order-by-empty-list",
    query: `{ SimpleEntity(order_by: []) { id value } }`,
    compare: "rootSet",
  },
  {
    name: "om-order-by-empty-object",
    query: `{ SimpleEntity(order_by: {}) { id } }`,
    compare: "rootSet",
  },
  {
    name: "om-order-by-null",
    query: `{ SimpleEntity(order_by: null) { id } }`,
    compare: "rootSet",
  },
  {
    name: "om-order-by-list-with-empty-object",
    query: `{ SimpleEntity(order_by: [{}]) { id } }`,
    compare: "rootSet",
  },
  {
    name: "om-order-by-variable-null",
    query: `query ($ord: [SimpleEntity_order_by!]) { SimpleEntity(order_by: $ord) { id } }`,
    variables: { ord: null },
    compare: "rootSet",
  },
  {
    name: "om-error-order-unknown-column",
    query: `{ User(order_by: {bogus: asc}) { id } }`,
  },
  {
    name: "om-error-order-array-rel-column",
    query: `{ User(order_by: {tokens: {tokenId: asc}}) { id } }`,
  },
  {
    name: "om-error-order-duplicate-key-in-object",
    query: `{ SimulateTestEvent(order_by: {blockNumber: asc, blockNumber: desc}) { id } }`,
  },
  {
    name: "om-error-distinct-not-first-in-order",
    query: `{ Token(distinct_on: owner_id, order_by: [{tokenId: asc}, {owner_id: asc}]) { id } }`,
  },
  {
    name: "om-error-distinct-unknown-column",
    query: `{ Token(distinct_on: bogus) { id } }`,
  },
]);
