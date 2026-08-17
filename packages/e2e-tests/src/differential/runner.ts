import { adminSecret } from "./env.js";
import type { CorpusCase } from "./corpus.js";
import { rawRequest, decodeBody } from "./rawRequest.js";

export interface GraphQLResponse {
  status: number;
  body: unknown;
  /**
   * Present only for transport probes: the `compareHeaders` the case named,
   * plus `contentEncoding` (`null` when the body arrived uncompressed).
   * Ordinary body-only cases leave this undefined so their snapshots keep
   * their existing shape.
   */
  headers?: Record<string, string | null>;
}

/** Auth headers for a case's role. */
function roleHeaders(corpusCase: CorpusCase): Record<string, string> {
  const role = corpusCase.role ?? "public";
  if (role === "admin") return { "X-Hasura-Admin-Secret": adminSecret };
  if (role === "admin-wrong")
    return { "X-Hasura-Admin-Secret": `${adminSecret}-wrong` };
  return {};
}

/** The POST body a non-transport case sends. */
function requestBody(corpusCase: CorpusCase): string {
  const payload: Record<string, unknown> = { query: corpusCase.query };
  if (corpusCase.variables !== undefined)
    payload.variables = corpusCase.variables;
  if (corpusCase.operationName !== undefined)
    payload.operationName = corpusCase.operationName;

  return corpusCase.rawVariables === undefined
    ? JSON.stringify(payload)
    : `{"query":${JSON.stringify(corpusCase.query)},"variables":${corpusCase.rawVariables}${
        corpusCase.operationName === undefined
          ? ""
          : `,"operationName":${JSON.stringify(corpusCase.operationName)}`
      }}`;
}

function parseBody(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return { nonJsonBody: text };
  }
}

/**
 * Values that differ per request are compared by shape, not by value: a
 * request id is a fresh UUID every time, so an engine that emits one is
 * only distinguishable from one that emits none.
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function normalizeHeaderValue(value: string): string {
  return UUID.test(value) ? "<uuid>" : value;
}

const BODY_NOT_RECORDED = "<body not recorded>";

/**
 * A GET probe carries the operation in the query string, the way Hasura's
 * GraphiQL and query-over-GET clients send it.
 */
function defaultPath(method: string, corpusCase: CorpusCase): string {
  if (method !== "GET" || corpusCase.query === undefined) return "/v1/graphql";
  const params = new URLSearchParams({ query: corpusCase.query });
  if (corpusCase.variables !== undefined)
    params.set("variables", JSON.stringify(corpusCase.variables));
  if (corpusCase.operationName !== undefined)
    params.set("operationName", corpusCase.operationName);
  return `/v1/graphql?${params}`;
}

async function runTransportCase(
  endpoint: string,
  corpusCase: CorpusCase
): Promise<GraphQLResponse> {
  const probe = corpusCase.transport!;
  const method = probe.method ?? "POST";
  const body =
    probe.rawBody ?? (method === "POST" ? requestBody(corpusCase) : undefined);
  const path = probe.path ?? defaultPath(method, corpusCase);

  const headers: Record<string, string> = {
    ...roleHeaders(corpusCase),
    ...probe.requestHeaders,
  };
  const has = (name: string) =>
    Object.keys(headers).some((k) => k.toLowerCase() === name);
  if (body !== undefined) {
    if (!has("content-type")) headers["Content-Type"] = "application/json";
    if (!has("content-length"))
      headers["Content-Length"] = String(Buffer.byteLength(body));
  }
  // Unlike fetch, node:http adds no accept-encoding of its own, so a case
  // that sets none really does send none.
  const response = await rawRequest(endpoint, { method, path, headers, body });

  const compared: Record<string, string | null> = {
    contentEncoding: response.headers["content-encoding"] ?? null,
  };
  for (const name of probe.compareHeaders ?? []) {
    const value = response.headers[name];
    compared[name] = value === undefined ? null : normalizeHeaderValue(value);
  }

  if (probe.recordBody === false) {
    return { status: response.status, body: BODY_NOT_RECORDED, headers: compared };
  }

  let text: string;
  try {
    text = decodeBody(response);
  } catch (err) {
    return {
      status: response.status,
      body: {
        undecodableBody: err instanceof Error ? err.message : String(err),
      },
      headers: compared,
    };
  }

  return { status: response.status, body: parseBody(text), headers: compared };
}

export async function runCase(
  endpoint: string,
  corpusCase: CorpusCase
): Promise<GraphQLResponse> {
  if (corpusCase.transport) return runTransportCase(endpoint, corpusCase);

  const res = await fetch(`${endpoint}/v1/graphql`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...roleHeaders(corpusCase) },
    body: requestBody(corpusCase),
  });
  return { status: res.status, body: parseBody(await res.text()) };
}

/**
 * Normalize a response for comparison. For compare mode "rootSet", arrays
 * directly under data.* are sorted by their JSON representation so queries
 * without a deterministic order_by can still be diffed.
 */
export function normalize(
  response: GraphQLResponse,
  compare: CorpusCase["compare"]
): GraphQLResponse {
  if (compare !== "rootSet") return response;
  const body = response.body as { data?: Record<string, unknown> };
  if (!body || typeof body !== "object" || !body.data) return response;
  const data: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(body.data)) {
    data[key] = Array.isArray(value)
      ? [...value]
          .map((item) => [JSON.stringify(item), item] as const)
          .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
          .map(([, item]) => item)
      : value;
  }
  return { ...response, body: { ...body, data } };
}
