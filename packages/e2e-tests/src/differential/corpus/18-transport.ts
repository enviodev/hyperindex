/**
 * Transport-level parity: the HTTP envelope around the GraphQL body —
 * response compression, batched (JSON array) requests, plain GET, and the
 * request-id response header.
 *
 * Every other corpus file compares response bodies over one fixed request
 * shape (POST, JSON object, no interesting headers). These cases vary the
 * shape itself, so they are the only ones that can see the gaps between
 * `envio serve` and Hasura at this layer. All four gaps they were written to
 * pin are now closed, and these cases are what keeps them closed.
 */

import { defineCases } from "../corpus.js";

/** A few KB on the small fixture — comfortably over Hasura's 700-byte cutoff. */
const LIST_QUERY = `{ User(order_by: {id: asc}) { id address gravatar_id updatesCountOnUserForTesting accountType } Token(order_by: {id: asc}) { id tokenId collection_id owner_id } raw_events(order_by: {serial: asc}) { chain_id event_id event_name contract_name block_number log_index src_address block_hash block_timestamp block_fields transaction_fields params serial } }`;

/** Well under the cutoff, so compression is skipped when it is optional. */
const SMALL_QUERY = `{ User_by_pk(id: "user-1") { id address } }`;

export default defineCases([
  // -------------------------------------------------------------------------
  // gzip response compression.
  //
  // `contentEncoding` in the snapshot is what pins this — bodies match either
  // way, since the probe decompresses before comparing.
  //
  // Hasura's negotiation is narrower than a stock compression middleware's
  // (Hasura/Server/Compression.hs, recorded behavior in the cases below):
  // gzip is the only supported encoding; a missing Accept-Encoding or a bare
  // `*` is treated as identity-only, NOT as permission to compress; and when
  // both identity and gzip are acceptable, responses under 700 bytes are left
  // uncompressed. Only when identity is explicitly rejected
  // (`identity;q=0`) is gzip applied regardless of size. A stock middleware
  // dropped in without these rules over-compresses on every one of those
  // edges, so each is pinned here.
  {
    name: "tr-gzip-accept-gzip",
    query: LIST_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip" },
      compareHeaders: ["vary"],
    },
  },
  {
    name: "tr-gzip-accept-gzip-deflate-br",
    query: LIST_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip, deflate, br" },
      compareHeaders: ["vary"],
    },
  },
  // Forced compression: rejecting identity bypasses the size cutoff, so even
  // a tiny body comes back gzipped.
  {
    name: "tr-gzip-identity-rejected-small-body",
    query: SMALL_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip, identity;q=0" },
      compareHeaders: ["vary"],
    },
  },
  // The cases below are what a stock middleware gets wrong.
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
  // A bare `*` is permission to send anything, but Hasura conservatively
  // reads it as identity-only.
  {
    name: "tr-gzip-accept-star",
    query: LIST_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "*" },
      compareHeaders: ["vary"],
    },
  },
  {
    name: "tr-gzip-explicitly-refused",
    query: LIST_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip;q=0" },
      compareHeaders: ["vary"],
    },
  },
  // gzip is the only encoding Hasura implements: br is offered by most
  // browsers and must not be answered with it.
  {
    name: "tr-gzip-brotli-only-unsupported",
    query: LIST_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "br" },
      compareHeaders: ["vary"],
    },
  },
  // Under the 700-byte cutoff with compression merely optional.
  {
    name: "tr-gzip-below-size-cutoff",
    query: SMALL_QUERY,
    transport: {
      requestHeaders: { "Accept-Encoding": "gzip" },
      compareHeaders: ["vary"],
    },
  },
  // Error responses leave the server through logErrorAndResp, which sets
  // neither the encoding header nor x-request-id — so an error body is never
  // compressed, whatever its size or the request's Accept-Encoding.
  {
    name: "tr-gzip-error-response",
    query: `{ User { nonexistentField } }`,
    transport: { requestHeaders: { "Accept-Encoding": "gzip" } },
  },

  // -------------------------------------------------------------------------
  // Batched (JSON array) requests.
  //
  // A JSON array of operations is executed and answered with an array of
  // results, positionally. Both engines execute the elements in turn rather
  // than at once, so the batch's win is amortising the round trip and the
  // auth check.
  {
    name: "tr-batch-two-queries",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}, limit: 1) { id } }` },
        { query: `{ Token(order_by: {id: asc}, limit: 1) { id } }` },
      ]),
    },
  },
  {
    name: "tr-batch-single-element",
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}, limit: 1) { id } }` },
      ]),
    },
  },
  {
    name: "tr-batch-empty-array",
    transport: { rawBody: `[]` },
  },
  // Per-element isolation: one failing operation must not take down the
  // whole batch, and the results must stay positional.
  {
    name: "tr-batch-mixed-valid-and-invalid",
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
  // Auth is resolved before the body is parsed, so a bad secret answers the
  // same whatever the body's shape.
  {
    name: "tr-batch-admin-secret-wrong",
    role: "admin-wrong",
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
    transport: {
      rawBody: JSON.stringify([
        { query: `{ User(order_by: {id: asc}) { id } }` },
      ]),
    },
  },
  // Malformed batches: shapes a client can plausibly send by accident. A
  // batch that fails to parse answers with a single error object rather than
  // an array, and the error path is indexed to the offending element —
  // `$[0]`, not the `$` serve reports for the whole body.
  {
    name: "tr-batch-element-not-an-object",
    transport: { rawBody: `[42]` },
  },
  {
    name: "tr-batch-element-missing-query",
    transport: { rawBody: `[{"variables":{}}]` },
  },
  {
    name: "tr-batch-nested-array",
    transport: { rawBody: `[[{"query":"{ __typename }"}]]` },
  },

  // -------------------------------------------------------------------------
  // Plain GET.
  //
  // Hasura does NOT execute query-over-GET: the OSS build wires GET
  // /v1/graphql to the Automatic Persisted Queries handler, which is
  // `throw400 NotSupported "PersistedQueryNotSupported"` (Hasura/App.hs), and
  // the route's allMod200 turns that into HTTP 200. The query string is never
  // looked at, so every GET below — query, variables, operationName, none,
  // admin secret, subscription — answers identically. The parity target is
  // therefore that fixed 200 error body, not a GET execution path.
  {
    name: "tr-get-query",
    query: `{ User(order_by: {id: asc}, limit: 2) { id } }`,
    transport: { method: "GET" },
  },
  {
    name: "tr-get-query-with-variables",
    query: `query ($limit: Int!) { User(order_by: {id: asc}, limit: $limit) { id } }`,
    variables: { limit: 1 },
    transport: { method: "GET" },
  },
  {
    name: "tr-get-operation-name",
    query: `query A { User(order_by: {id: asc}, limit: 1) { id } }\nquery B { Token(order_by: {id: asc}, limit: 1) { id } }`,
    operationName: "B",
    transport: { method: "GET" },
  },
  // The bare-GET case from the gap report: a health check or a browser
  // hitting the endpoint by hand.
  {
    name: "tr-get-no-query",
    transport: { method: "GET", path: "/v1/graphql" },
  },
  {
    name: "tr-get-admin-secret",
    query: `{ User(order_by: {id: asc}, limit: 1) { id } }`,
    role: "admin",
    transport: { method: "GET" },
  },
  {
    name: "tr-get-subscription-rejected",
    query: `subscription { User(order_by: {id: asc}, limit: 1) { id } }`,
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
  // One per response, echoing a client-supplied value when there is one.
  //
  // It is set in logSuccessAndResp only (Hasura/Server/App.hs), so error
  // responses carry NO x-request-id — not even one the client supplied. serve
  // must reproduce that asymmetry, not just start emitting the header
  // everywhere.
  {
    name: "tr-request-id-generated",
    query: `{ __typename }`,
    transport: { compareHeaders: ["x-request-id"] },
  },
  {
    name: "tr-request-id-echoed",
    query: `{ __typename }`,
    transport: {
      requestHeaders: { "X-Request-Id": "differential-fixed-request-id" },
      compareHeaders: ["x-request-id"],
    },
  },
  // An error response carries no request id even though the client sent one.
  {
    name: "tr-request-id-on-error",
    query: `{ User { nonexistentField } }`,
    transport: {
      requestHeaders: { "X-Request-Id": "differential-fixed-request-id" },
      compareHeaders: ["x-request-id"],
    },
  },
  {
    name: "tr-request-id-on-access-denied",
    query: `{ __typename }`,
    role: "admin-wrong",
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
