/**
 * Transport-level parity: the HTTP envelope around the GraphQL body —
 * response compression, batched (JSON array) requests, plain GET, and the
 * request-id response header.
 *
 * Every other corpus file compares response bodies over one fixed request
 * shape (POST, JSON object, no interesting headers). These cases vary the
 * shape itself, so they are the only ones that can see the gaps between
 * `envio serve` and Hasura at this layer. Cases carrying `knownGap` are
 * failing reproductions: recorded from Hasura as the spec, reported as
 * known gaps against serve until the gap closes, and hard failures the
 * moment serve starts matching (so the annotation gets removed).
 */

import { defineCases } from "../corpus.js";

/**
 * Deterministic, and a few KB on the small fixture — comfortably past any
 * minimum-size threshold a compression layer might apply.
 */
const LIST_QUERY = `{ User(order_by: {id: asc}) { id address gravatar_id updatesCountOnUserForTesting accountType } Token(order_by: {id: asc}) { id tokenId collection_id owner_id } raw_events(order_by: {serial: asc}) { chain_id event_id event_name contract_name block_number log_index src_address block_hash block_timestamp block_fields transaction_fields params serial } }`;

export default defineCases([
  // -------------------------------------------------------------------------
  // gzip response compression.
  //
  // Hasura compresses when the client offers gzip; serve has no compression
  // layer at all, so the same response costs ~2.4x the egress. `contentEncoding`
  // in the snapshot is what pins this — bodies match either way, since the
  // probe decompresses before comparing.
  {
    name: "tr-gzip-accept-gzip",
    query: LIST_QUERY,
    knownGap: "serve sends no content-encoding: no compression layer",
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip" },
      compareHeaders: ["vary"],
    },
  },
  {
    name: "tr-gzip-accept-gzip-deflate-br",
    query: LIST_QUERY,
    knownGap: "serve sends no content-encoding: no compression layer",
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip, deflate, br" },
      compareHeaders: ["vary"],
    },
  },
  // Guards the other direction once compression lands: a client that asks
  // for no encoding must still get an identity body.
  {
    name: "tr-gzip-accept-identity",
    query: LIST_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "identity" },
      compareHeaders: ["vary"],
    },
  },
  {
    name: "tr-gzip-no-accept-encoding",
    query: LIST_QUERY,
    transport: { compareHeaders: ["vary"] },
  },
  // An error response takes a different path out of the server than a data
  // response; it must not skip the encoding negotiation.
  {
    name: "tr-gzip-error-response",
    query: `{ User { nonexistentField } }`,
    knownGap: "serve sends no content-encoding: no compression layer",
    transport: { requestHeaders: { "Accept-Encoding": "gzip" } },
  },

  // -------------------------------------------------------------------------
  // Batched (JSON array) requests.
  //
  // Hasura executes a JSON array of operations and answers with an array of
  // results; serve's body decoder only accepts an object, so it answers with
  // a parse-failed error and every client on a batching HTTP link breaks.
  {
    name: "tr-batch-two-queries",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}, limit: 1) { id } }` },
        { query: `{ Token(order_by: {id: asc}, limit: 1) { id } }` },
      ]),
    },
  },
  {
    name: "tr-batch-single-element",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}, limit: 1) { id } }` },
      ]),
    },
  },
  {
    name: "tr-batch-empty-array",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: { rawBody: `[]` },
  },
  // Per-element isolation: one failing operation must not take down the
  // whole batch, and the results must stay positional.
  {
    name: "tr-batch-mixed-valid-and-invalid",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}, limit: 1) { id } }` },
        { query: `{ User { nonexistentField } }` },
        { query: `{ Token(order_by: {id: asc}, limit: 1) { id } }` },
      ]),
    },
  },
  {
    name: "tr-batch-with-variables",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: {
      rawBody: JSON.stringify([
        {
          query: `query ($limit: Int!) { User(order_by: {id: asc}, limit: $limit) { id } }`,
          variables: { limit: 2 },
        },
        {
          query: `query ($limit: Int!) { User(order_by: {id: asc}, limit: $limit) { id } }`,
          variables: { limit: 1 },
        },
      ]),
    },
  },
  // Auth is resolved once for the request, not per element.
  {
    name: "tr-batch-admin-secret-wrong",
    role: "admin-wrong",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}, limit: 1) { id } }` },
      ]),
    },
  },
  // Row limits and aggregate gating are per-role, not per-request-shape:
  // a batched element must be limited exactly like a single POST.
  {
    name: "tr-batch-respects-response-limit",
    phases: ["limited"],
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}) { id } }` },
      ]),
    },
  },
  // Malformed batches: shapes a client can plausibly send by accident.
  {
    name: "tr-batch-element-not-an-object",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: { rawBody: `[42]` },
  },
  {
    name: "tr-batch-element-missing-query",
    knownGap: "serve rejects an array body as parse-failed instead of executing it",
    transport: { rawBody: `[{"variables":{}}]` },
  },
  {
    name: "tr-batch-nested-array",
    transport: { rawBody: `[[{"query":"{ __typename }"}]]` },
  },

  // -------------------------------------------------------------------------
  // Plain GET.
  //
  // serve routes every GET on /v1/graphql into the WebSocket upgrade
  // extractor, so a health check or a curl gets HTTP 400 "Connection header
  // did not include 'upgrade'" instead of anything GraphQL-shaped.
  {
    name: "tr-get-query",
    query: `{ User(order_by: {id: asc}, limit: 2) { id } }`,
    knownGap: "serve 400s every GET: the route is WebSocket-upgrade-only",
    transport: { method: "GET" },
  },
  {
    name: "tr-get-query-with-variables",
    query: `query ($limit: Int!) { User(order_by: {id: asc}, limit: $limit) { id } }`,
    variables: { limit: 1 },
    knownGap: "serve 400s every GET: the route is WebSocket-upgrade-only",
    transport: { method: "GET" },
  },
  {
    name: "tr-get-operation-name",
    query: `query A { User(order_by: {id: asc}, limit: 1) { id } }\nquery B { Token(order_by: {id: asc}, limit: 1) { id } }`,
    operationName: "B",
    knownGap: "serve 400s every GET: the route is WebSocket-upgrade-only",
    transport: { method: "GET" },
  },
  // The bare-GET case from the gap report: a health check or a browser
  // hitting the endpoint by hand.
  {
    name: "tr-get-no-query",
    knownGap: "serve 400s every GET: the route is WebSocket-upgrade-only",
    transport: { method: "GET", path: "/v1/graphql" },
  },
  {
    name: "tr-get-admin-secret",
    query: `{ User(order_by: {id: asc}, limit: 1) { id } }`,
    role: "admin",
    knownGap: "serve 400s every GET: the route is WebSocket-upgrade-only",
    transport: { method: "GET" },
  },
  // Hasura rejects a mutation/subscription over GET (it is not a safe
  // method); pins that the eventual GET path keeps that restriction.
  {
    name: "tr-get-subscription-rejected",
    query: `subscription { User(order_by: {id: asc}, limit: 1) { id } }`,
    knownGap: "serve 400s every GET: the route is WebSocket-upgrade-only",
    transport: { method: "GET" },
  },
  // A real WebSocket upgrade on the same route must keep working — the GET
  // fix must not swallow upgrades. 101 has no body to compare.
  {
    name: "tr-get-websocket-upgrade-still-works",
    query: `{ __typename }`,
    transport: {
      method: "GET",
      path: "/v1/graphql",
      requestHeaders: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Protocol": "graphql-transport-ws",
      },
      compareHeaders: ["upgrade", "sec-websocket-protocol"],
    },
  },

  // -------------------------------------------------------------------------
  // x-request-id.
  //
  // Hasura emits one per response and echoes a client-supplied value; serve
  // emits none, so a support ticket cannot be joined to a log line.
  {
    name: "tr-request-id-generated",
    query: `{ __typename }`,
    knownGap: "serve emits no x-request-id",
    transport: { compareHeaders: ["x-request-id"] },
  },
  {
    name: "tr-request-id-echoed",
    query: `{ __typename }`,
    knownGap: "serve emits no x-request-id",
    transport: {
      requestHeaders: { "X-Request-Id": "differential-fixed-request-id" },
      compareHeaders: ["x-request-id"],
    },
  },
  {
    name: "tr-request-id-on-error",
    query: `{ User { nonexistentField } }`,
    knownGap: "serve emits no x-request-id",
    transport: { compareHeaders: ["x-request-id"] },
  },

  // -------------------------------------------------------------------------
  // Observability endpoints, recorded for information only.
  //
  // Prometheus metrics are a serve requirement regardless of what the Hasura
  // edition under test exposes (v2 CE serves no /v1/metrics; it is an EE
  // feature), so these are recordOnly: the snapshot settles what Hasura
  // actually answers without making serve's metrics endpoint a parity
  // violation.
  {
    name: "tr-probe-metrics-endpoint",
    recordOnly: true,
    transport: {
      method: "GET",
      path: "/v1/metrics",
      compareHeaders: ["content-type"],
      // A live scrape's counters change every request; status plus
      // content-type is what settles whether the endpoint exists at all.
      recordBody: false,
    },
  },
  {
    name: "tr-probe-version-endpoint",
    recordOnly: true,
    transport: {
      method: "GET",
      path: "/v1/version",
      compareHeaders: ["content-type"],
    },
  },
]);
