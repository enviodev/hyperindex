import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "am-token-numeric-full-matrix",
    role: "admin",
    query: `{ Token_aggregate { aggregate { count sum { tokenId } avg { tokenId } min { tokenId } max { tokenId } stddev { tokenId } stddev_pop { tokenId } stddev_samp { tokenId } var_pop { tokenId } var_samp { tokenId } variance { tokenId } } } }`,
  },
  {
    name: "am-user-int-full-matrix",
    role: "admin",
    query: `{ User_aggregate { aggregate { count sum { updatesCountOnUserForTesting } avg { updatesCountOnUserForTesting } min { updatesCountOnUserForTesting } max { updatesCountOnUserForTesting } stddev { updatesCountOnUserForTesting } stddev_pop { updatesCountOnUserForTesting } stddev_samp { updatesCountOnUserForTesting } var_pop { updatesCountOnUserForTesting } var_samp { updatesCountOnUserForTesting } variance { updatesCountOnUserForTesting } } } }`,
  },
  {
    name: "am-scalars-float8-full-matrix",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate(where: {id: {_in: ["scalar-1", "scalar-nulls", "scalar-unicode", "scalar-quotes", "scalar-empty"]}}) { aggregate { count sum { float_ } avg { float_ } min { float_ } max { float_ } stddev { float_ } stddev_pop { float_ } stddev_samp { float_ } var_pop { float_ } var_samp { float_ } variance { float_ } } } }`,
  },
  {
    name: "am-scalars-int-full-matrix",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { count sum { int_ } avg { int_ } min { int_ } max { int_ } stddev { int_ } stddev_pop { int_ } stddev_samp { int_ } var_pop { int_ } var_samp { int_ } variance { int_ } } } }`,
  },
  {
    name: "am-scalars-bigint-full-matrix",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { count sum { bigInt } avg { bigInt } min { bigInt } max { bigInt } stddev { bigInt } stddev_pop { bigInt } stddev_samp { bigInt } var_pop { bigInt } var_samp { bigInt } variance { bigInt } } } }`,
  },
  {
    name: "am-scalars-bigdecimal-full-matrix",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { count sum { bigDecimal bigDecimalWithConfig } avg { bigDecimal bigDecimalWithConfig } min { bigDecimal bigDecimalWithConfig } max { bigDecimal bigDecimalWithConfig } stddev { bigDecimal } var_samp { bigDecimalWithConfig } } } }`,
  },
  {
    name: "am-sim-int-full-matrix",
    role: "admin",
    query: `{ SimulateTestEvent_aggregate { aggregate { count sum { blockNumber logIndex timestamp } avg { blockNumber logIndex timestamp } min { blockNumber logIndex timestamp } max { blockNumber logIndex timestamp } stddev { logIndex } stddev_pop { logIndex } stddev_samp { logIndex } var_pop { timestamp } var_samp { timestamp } variance { timestamp } } } }`,
  },
  {
    name: "am-minmax-text-columns",
    role: "admin",
    query: `{ Token_aggregate { aggregate { min { id collection_id owner_id } max { id collection_id owner_id } } } }`,
  },
  {
    name: "am-minmax-text-unicode-empty",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { min { string optString } max { string optString } } } }`,
  },
  {
    name: "am-minmax-enum",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { min { enumField optEnumField } max { enumField optEnumField } } } }`,
  },
  {
    name: "am-minmax-timestamptz",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { min { timestamp optTimestamp } max { timestamp optTimestamp } } } }`,
  },
  {
    name: "am-minmax-user-mixed",
    role: "admin",
    query: `{ User_aggregate { aggregate { min { accountType address gravatar_id } max { accountType address gravatar_id } } } }`,
  },
  {
    name: "am-float8-sum-infinity-nan",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { sum { float_ } } } }`,
  },
  {
    name: "am-float8-minmax-infinity",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { min { float_ } max { float_ optFloat } } } }`,
  },
  {
    name: "am-float8-avg-nan",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { avg { optFloat } } } }`,
  },
  {
    name: "am-scalars-optint-null-handling",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { count(columns: optInt) sum { optInt } avg { optInt } min { optInt } max { optInt } } } }`,
  },
  {
    name: "am-empty-numeric-all-operators",
    role: "admin",
    query: `{ Token_aggregate(where: {id: {_eq: "missing"}}) { aggregate { count sum { tokenId } avg { tokenId } min { tokenId } max { tokenId } stddev { tokenId } stddev_pop { tokenId } stddev_samp { tokenId } var_pop { tokenId } var_samp { tokenId } variance { tokenId } } } }`,
  },
  {
    name: "am-empty-minmax-mixed-types",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate(where: {id: {_eq: "missing"}}) { aggregate { count min { id enumField timestamp int_ float_ } max { id enumField timestamp int_ float_ } } } }`,
  },
  {
    name: "am-empty-count-variants",
    role: "admin",
    query: `{ Token_aggregate(where: {id: {_eq: "missing"}}) { aggregate { count plain: count(columns: owner_id) dist: count(columns: owner_id, distinct: true) } } }`,
  },
  {
    name: "am-empty-with-nodes",
    role: "admin",
    query: `{ Token_aggregate(where: {id: {_eq: "missing"}}) { aggregate { count } nodes { id tokenId owner { id } } } }`,
  },
  {
    name: "am-single-row-stddev-null",
    role: "admin",
    query: `{ Token_aggregate(where: {id: {_eq: "tok-1"}}) { aggregate { count stddev { tokenId } stddev_pop { tokenId } stddev_samp { tokenId } var_pop { tokenId } var_samp { tokenId } variance { tokenId } } } }`,
  },
  {
    name: "am-count-multi-columns",
    role: "admin",
    query: `{ User_aggregate { aggregate { count(columns: [gravatar_id, accountType]) } } }`,
  },
  {
    name: "am-count-multi-columns-distinct",
    role: "admin",
    query: `{ Token_aggregate { aggregate { count(columns: [owner_id, collection_id], distinct: true) } } }`,
  },
  {
    name: "am-count-distinct-with-nulls",
    role: "admin",
    query: `{ User_aggregate { aggregate { total: count all: count(columns: gravatar_id) dist: count(columns: gravatar_id, distinct: true) } } }`,
  },
  {
    name: "am-count-distinct-no-nulls",
    role: "admin",
    query: `{ Token_aggregate { aggregate { total: count all: count(columns: owner_id) dist: count(columns: owner_id, distinct: true) } } }`,
  },
  {
    name: "am-count-distinct-no-columns",
    role: "admin",
    query: `{ User_aggregate { aggregate { count(distinct: true) } } }`,
  },
  {
    name: "am-nested-full-combo",
    role: "admin",
    query: `{ User(order_by: {id: asc}) { id tokens_aggregate(where: {tokenId: {_gte: 0}}, distinct_on: collection_id, order_by: [{collection_id: asc}, {tokenId: desc}], limit: 2, offset: 1) { aggregate { count sum { tokenId } min { tokenId } } nodes { id collection_id tokenId } } } }`,
  },
  {
    name: "am-nested-agg-empty-owner",
    role: "admin",
    query: `{ User_by_pk(id: "user-dangling") { id tokens_aggregate { aggregate { count sum { tokenId } avg { tokenId } min { tokenId } max { tokenId } } nodes { id } } } }`,
  },
  {
    name: "am-nested-count-distinct",
    role: "admin",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate { aggregate { count(columns: owner_id, distinct: true) } } } }`,
  },
  {
    name: "am-nested-agg-where-order-nodes",
    role: "admin",
    query: `{ NftCollection(order_by: {id: asc}) { id tokens_aggregate(where: {owner_id: {_like: "user-%"}}, order_by: {tokenId: asc}, limit: 3) { aggregate { count max { tokenId } } nodes { id tokenId } } } }`,
  },
  {
    name: "am-root-distinct-on-aggregate",
    role: "admin",
    query: `{ Token_aggregate(distinct_on: collection_id, order_by: [{collection_id: asc}, {id: asc}]) { aggregate { count sum { tokenId } } nodes { id collection_id } } }`,
  },
  {
    name: "am-raw-bigint-sum",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { sum { event_id serial } } } }`,
  },
  {
    name: "am-raw-bigint-avg-vs-int-avg",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { avg { event_id log_index } } } }`,
  },
  {
    name: "am-raw-bigint-minmax",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { min { event_id serial } max { event_id serial } } } }`,
  },
  {
    name: "am-raw-int-sum-overflows-int32",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { sum { chain_id block_number block_timestamp log_index } } } }`,
  },
  {
    name: "am-raw-bigint-stddev-variance",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { stddev { event_id } stddev_pop { event_id } var_pop { event_id } variance { event_id } } } }`,
  },
  {
    name: "am-raw-count-distinct-text-and-pair",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { hashes: count(columns: block_hash, distinct: true) pairs: count(columns: [chain_id, block_number], distinct: true) } } }`,
  },
  {
    name: "am-meta-float4-matrix",
    role: "admin",
    query: `{ _meta_aggregate { aggregate { count sum { eventsProcessed } avg { eventsProcessed } min { eventsProcessed } max { eventsProcessed } stddev { eventsProcessed } var_pop { eventsProcessed } } } }`,
  },
  {
    name: "am-meta-int-sum-nullable",
    role: "admin",
    query: `{ _meta_aggregate { aggregate { sum { endBlock firstEventBlock startBlock progressBlock } } } }`,
  },
  {
    name: "am-chainmeta-float4-matrix",
    role: "admin",
    query: `{ chain_metadata_aggregate { aggregate { count sum { num_events_processed } avg { num_events_processed } min { num_events_processed } max { num_events_processed } } } }`,
  },
  {
    name: "am-meta-minmax-timestamptz",
    role: "admin",
    query: `{ _meta_aggregate { aggregate { min { readyAt } max { readyAt } } } chain_metadata_aggregate { aggregate { min { timestamp_caught_up_to_head_or_endblock } max { timestamp_caught_up_to_head_or_endblock } } } }`,
  },
  {
    name: "am-user-avg-precision",
    role: "admin",
    query: `{ User_aggregate { aggregate { avg { updatesCountOnUserForTesting } } } }`,
  },
  {
    name: "am-agg-variables-where",
    role: "admin",
    query: `query ($w: Token_bool_exp) { Token_aggregate(where: $w) { aggregate { count sum { tokenId } } } }`,
    variables: { w: { collection_id: { _eq: "coll-1" } } },
  },
  {
    name: "am-error-min-bool",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { min { bool } } } }`,
  },
  {
    name: "am-error-sum-text-column",
    role: "admin",
    query: `{ Token_aggregate { aggregate { sum { id } } } }`,
  },
  {
    name: "am-error-avg-timestamp",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { avg { timestamp } } } }`,
  },
  {
    name: "am-error-variance-enum",
    role: "admin",
    query: `{ EntityWithAllNonArrayTypes_aggregate { aggregate { variance { enumField } } } }`,
  },
  {
    name: "am-error-count-unknown-column",
    role: "admin",
    query: `{ User_aggregate { aggregate { count(columns: [notAColumn]) } } }`,
  },
  {
    name: "am-error-sum-jsonb",
    role: "admin",
    query: `{ raw_events_aggregate { aggregate { sum { params } } } }`,
  },
  {
    name: "am-error-count-distinct-wrong-type",
    role: "admin",
    query: `{ User_aggregate { aggregate { count(distinct: "yes") } } }`,
  },
]);
