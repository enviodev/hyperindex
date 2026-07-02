import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "order-asc",
    query: `{ Token(order_by: {tokenId: asc}) { id tokenId } }`,
    bench: true,
  },
  {
    name: "order-desc",
    query: `{ Token(order_by: {tokenId: desc}) { id tokenId } }`,
  },
  {
    name: "order-nulls-first",
    query: `{ User(order_by: {gravatar_id: asc_nulls_first, id: asc}) { id gravatar_id } }`,
  },
  {
    name: "order-nulls-last",
    query: `{ User(order_by: {gravatar_id: asc_nulls_last, id: asc}) { id gravatar_id } }`,
  },
  {
    name: "order-desc-nulls-first",
    query: `{ User(order_by: {gravatar_id: desc_nulls_first, id: asc}) { id gravatar_id } }`,
  },
  {
    name: "order-desc-nulls-last",
    query: `{ User(order_by: {gravatar_id: desc_nulls_last, id: asc}) { id gravatar_id } }`,
  },
  {
    name: "order-default-nulls-asc",
    query: `{ User(order_by: {gravatar_id: asc, id: asc}) { id gravatar_id } }`,
  },
  {
    name: "order-default-nulls-desc",
    query: `{ User(order_by: {gravatar_id: desc, id: asc}) { id gravatar_id } }`,
  },
  {
    name: "order-multi-key-list",
    query: `{ SimulateTestEvent(order_by: [{blockNumber: desc}, {logIndex: asc}]) { id blockNumber logIndex } }`,
  },
  {
    name: "order-multi-key-single-object",
    query: `{ SimulateTestEvent(order_by: {blockNumber: desc, logIndex: desc}) { id blockNumber logIndex } }`,
  },
  {
    name: "order-by-enum-column",
    query: `{ Gravatar(order_by: [{size: asc}, {id: asc}]) { id size } }`,
  },
  {
    name: "order-by-numeric",
    query: `{ Token(order_by: [{tokenId: desc}, {id: asc}]) { id tokenId } }`,
  },
  {
    name: "order-by-timestamp",
    query: `{ EntityWithTimestamp(order_by: [{timestamp: asc}, {id: asc}]) { id timestamp } }`,
  },
  {
    name: "order-by-bool",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{bool: asc}, {id: asc}]) { id bool } }`,
  },
  {
    name: "order-by-float-with-special",
    query: `{ EntityWithAllNonArrayTypes(order_by: [{float_: asc}, {id: asc}]) { id float_ } }`,
  },
  {
    name: "order-by-object-relationship-column",
    query: `{ Gravatar(order_by: [{owner: {updatesCountOnUserForTesting: desc}}, {id: asc}]) { id owner { updatesCountOnUserForTesting } } }`,
  },
  {
    name: "order-by-relationship-nested",
    query: `{ Token(order_by: [{collection: {name: asc}}, {id: asc}]) { id collection { name } } }`,
  },
  {
    name: "limit-zero",
    query: `{ User(order_by: {id: asc}, limit: 0) { id } }`,
  },
  {
    name: "limit-basic",
    query: `{ SimpleEntity(order_by: {id: asc}, limit: 3) { id } }`,
    bench: true,
  },
  {
    name: "limit-larger-than-rows",
    query: `{ SimpleEntity(order_by: {id: asc}, limit: 5000) { id } }`,
  },
  {
    name: "offset-basic",
    query: `{ SimpleEntity(order_by: {id: asc}, offset: 3) { id } }`,
  },
  {
    name: "offset-beyond-rows",
    query: `{ SimpleEntity(order_by: {id: asc}, offset: 500) { id } }`,
  },
  {
    name: "limit-offset-combo",
    query: `{ SimpleEntity(order_by: {id: asc}, limit: 2, offset: 2) { id } }`,
  },
  {
    name: "offset-without-order",
    query: `{ SimpleEntity(offset: 8) { id } }`,
    compare: "rootSet",
  },
  {
    name: "distinct-on-basic",
    query: `{ Token(distinct_on: owner_id, order_by: [{owner_id: asc}, {tokenId: desc}]) { id owner_id tokenId } }`,
  },
  {
    name: "distinct-on-list",
    query: `{ SimulateTestEvent(distinct_on: [blockNumber], order_by: [{blockNumber: asc}, {logIndex: desc}]) { id blockNumber logIndex } }`,
  },
  {
    name: "distinct-on-multiple-columns",
    query: `{ SimulateTestEvent(distinct_on: [blockNumber, timestamp], order_by: [{blockNumber: asc}, {timestamp: asc}, {logIndex: asc}]) { id blockNumber timestamp } }`,
  },
  {
    name: "distinct-on-with-limit",
    query: `{ Token(distinct_on: collection_id, order_by: [{collection_id: asc}, {tokenId: desc}], limit: 2) { id collection_id } }`,
  },
  {
    name: "distinct-on-enum-column",
    query: `{ Gravatar(distinct_on: size, order_by: [{size: asc}, {id: asc}]) { id size } }`,
  },
  {
    name: "variables-limit-offset-order",
    query: `query ($l: Int, $o: Int, $ord: [SimpleEntity_order_by!]) { SimpleEntity(limit: $l, offset: $o, order_by: $ord) { id } }`,
    variables: { l: 3, o: 1, ord: [{ id: "desc" }] },
  },
]);
