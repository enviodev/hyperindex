import { defineCases } from "../corpus.js";

export default defineCases([
  {
    name: "internal-meta-view",
    query: `{ _meta { chainId startBlock endBlock progressBlock bufferBlock firstEventBlock eventsProcessed sourceBlock readyAt isReady } }`,
    bench: true,
  },
  {
    name: "internal-meta-float4-precision",
    query: `{ _meta(where: {chainId: {_eq: 1}}) { chainId eventsProcessed } }`,
  },
  {
    name: "internal-meta-where-ready",
    query: `{ _meta(where: {isReady: {_eq: true}}) { chainId readyAt } }`,
  },
  {
    name: "internal-chain-metadata-view",
    query: `{ chain_metadata(order_by: {chain_id: asc}) { block_height chain_id end_block first_event_block_number is_hyper_sync latest_fetched_block_number latest_processed_block num_batches_fetched num_events_processed start_block timestamp_caught_up_to_head_or_endblock } }`,
  },
  {
    name: "internal-raw-events-full",
    query: `{ raw_events(order_by: {serial: asc}) { chain_id event_id event_name contract_name block_number log_index src_address block_hash block_timestamp block_fields transaction_fields params serial } }`,
    bench: true,
  },
  {
    name: "internal-raw-events-by-pk",
    query: `{ raw_events_by_pk(serial: 1) { serial event_name params } }`,
  },
  {
    name: "internal-raw-events-by-pk-miss",
    query: `{ raw_events_by_pk(serial: 999999) { serial } }`,
  },
  {
    name: "internal-raw-events-bigint-filter",
    query: `{ raw_events(where: {event_id: {_gt: "4611686018427387904"}}, order_by: {serial: asc}) { serial event_id } }`,
  },
  {
    name: "internal-raw-events-jsonb-filter",
    query: `{ raw_events(where: {params: {_has_key: "from"}}, order_by: {serial: asc}) { serial params } }`,
  },
  {
    name: "internal-raw-events-jsonb-path",
    query: `{ raw_events(where: {event_name: {_eq: "NewGravatar"}}) { serial params(path: "$.nested.deep[0]") } }`,
  },
  {
    name: "internal-no-relationships-on-internal-tables",
    query: `{ raw_events(limit: 1, order_by: {serial: asc}) { serial } _meta(limit: 1) { chainId } }`,
  },
  {
    name: "internal-meta-aggregate-admin",
    role: "admin",
    query: `{ _meta_aggregate { aggregate { count max { eventsProcessed } } } }`,
  },
  {
    name: "internal-chain-metadata-no-by-pk",
    query: `{ chain_metadata(where: {chain_id: {_eq: 1337}}) { chain_id end_block timestamp_caught_up_to_head_or_endblock } }`,
  },
]);
