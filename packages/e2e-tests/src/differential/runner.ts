import { adminSecret } from "./env.js";
import type { CorpusCase } from "./corpus.js";

export interface GraphQLResponse {
  status: number;
  body: unknown;
}

export async function runCase(
  endpoint: string,
  corpusCase: CorpusCase
): Promise<GraphQLResponse> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if ((corpusCase.role ?? "public") === "admin") {
    headers["X-Hasura-Admin-Secret"] = adminSecret;
  }
  const payload: Record<string, unknown> = { query: corpusCase.query };
  if (corpusCase.variables !== undefined)
    payload.variables = corpusCase.variables;
  if (corpusCase.operationName !== undefined)
    payload.operationName = corpusCase.operationName;

  const res = await fetch(`${endpoint}/v1/graphql`, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    body = { nonJsonBody: text };
  }
  return { status: res.status, body };
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
      ? [...value].sort((a, b) =>
          JSON.stringify(a) < JSON.stringify(b) ? -1 : 1
        )
      : value;
  }
  return { status: response.status, body: { ...body, data } };
}
