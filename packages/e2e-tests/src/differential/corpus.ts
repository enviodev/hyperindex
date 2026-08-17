/**
 * Corpus case definitions for the differential GraphQL suite.
 *
 * Every case is executed against both real Hasura and `envio serve`; the
 * full JSON response bodies (data and errors alike) must be identical.
 */

// "admin-wrong" sends an incorrect admin secret — pins Hasura's
// access-denied error shape (HTTP 200, not 401; verified live).
export type Role = "admin" | "public" | "admin-wrong";

/**
 * default — Hasura tracked with no response limit and no aggregate entities
 *   (production defaults: ENVIO_HASURA_RESPONSE_LIMIT unset,
 *   ENVIO_HASURA_PUBLIC_AGGREGATE=[]).
 * limited — response limit 5; aggregates enabled for User, Token,
 *   SimpleEntity, raw_events and _meta.
 */
export type Phase = "default" | "limited";

export const phaseConfigs: Record<
  Phase,
  { responseLimit?: number; aggregateEntities: string[] }
> = {
  default: { aggregateEntities: [] },
  limited: {
    responseLimit: 5,
    aggregateEntities: ["User", "Token", "SimpleEntity", "raw_events", "_meta"],
  },
};

/**
 * Raw HTTP shape for a transport-level probe. Cases without this field are
 * ordinary POSTs of `{query, variables, operationName}` and compare bodies
 * only; cases with it control the method, path, request headers and body
 * text, and can compare selected response headers and the content encoding
 * as well.
 */
export interface TransportProbe {
  /** Defaults to POST. */
  method?: "GET" | "POST";
  /** Defaults to `/v1/graphql`. Any query string must already be encoded. */
  path?: string;
  /**
   * Request body text, replacing the `{query, variables}` envelope. Used
   * for shapes the envelope cannot express, above all a JSON array batch.
   */
  rawBody?: string;
  requestHeaders?: Record<string, string>;
  /**
   * Response headers compared between the engines, lowercased. Everything
   * else (`date`, `server`, `content-length`, ...) is ignored: only headers
   * named here are part of the parity contract.
   */
  compareHeaders?: string[];
  /**
   * Set false for an endpoint whose body changes on every request — a
   * Prometheus scrape above all. The snapshot then keeps the status and
   * headers only, so re-recording it stays byte-stable and CI's
   * snapshot-drift check does not fail on live counter values.
   */
  recordBody?: boolean;
}

export interface CorpusCase {
  /** Unique within the whole corpus; used for snapshot file names. */
  name: string;
  /**
   * Required unless `transport.rawBody` supplies the body directly. For a
   * GET probe this is the query that gets URL-encoded into the path.
   */
  query?: string;
  variables?: Record<string, unknown>;
  /** Raw JSON object text for variables that JavaScript cannot represent
   * losslessly (for example 1e400). Mutually exclusive with `variables`. */
  rawVariables?: string;
  operationName?: string;
  /** Defaults to "public" — the role of unauthenticated requests. */
  role?: Role;
  /** Phases the case runs in. Defaults to ["default"]. */
  phases?: Phase[];
  /**
   * exact — response bodies must be byte-for-byte equal as parsed JSON.
   * rootSet — arrays directly under data.* are compared as multisets
   *   (for queries without a deterministic order_by).
   */
  compare?: "exact" | "rootSet";
  /** Include in the performance benchmark suite. */
  bench?: boolean;
  transport?: TransportProbe;
  /**
   * A difference from Hasura that this case does not currently match,
   * described in one line: either a gap still to close, or one serve does
   * not intend to close (a Hasura bug, a Postgres planner artifact). The
   * case is still recorded from Hasura — the snapshot is the spec — but a
   * mismatch is reported instead of failing the run. A case that starts
   * matching DOES fail, so the annotation cannot outlive the difference.
   */
  knownGap?: string;
  /**
   * Record Hasura's behavior without asserting anything about serve. For
   * endpoints where matching Hasura is not the goal — serve should expose
   * Prometheus metrics whether or not the Hasura edition under test does —
   * but where the recorded answer still settles what Hasura actually did.
   */
  recordOnly?: boolean;
}

export interface SubscriptionStep {
  /** SQL to run (as admin, via Hasura run_sql) after the previous payload. */
  sql?: string;
  /** Roughly how many payloads to await after this step. */
  expectPayloads: number;
}

export interface SubscriptionCase {
  name: string;
  query: string;
  variables?: Record<string, unknown>;
  role?: Role;
  phases?: Phase[];
  /**
   * Which WebSocket subprotocol to use:
   * graphql-transport-ws — the modern graphql-ws protocol.
   * graphql-ws — the legacy subscriptions-transport-ws protocol.
   */
  protocol: "graphql-transport-ws" | "graphql-ws";
  steps: SubscriptionStep[];
}

const seen = new Set<string>();

export function defineCases(cases: CorpusCase[]): CorpusCase[] {
  for (const c of cases) {
    if (seen.has(c.name)) throw new Error(`Duplicate corpus case: ${c.name}`);
    if (c.variables !== undefined && c.rawVariables !== undefined) {
      throw new Error(`Corpus case ${c.name} defines variables twice`);
    }
    // A transport probe can be fully specified by its path alone (a bare
    // GET), so a query is only required when nothing else describes the
    // request.
    if (
      c.query === undefined &&
      c.transport?.rawBody === undefined &&
      c.transport?.path === undefined
    ) {
      throw new Error(
        `Corpus case ${c.name} has no query, transport.rawBody or transport.path`
      );
    }
    if (c.knownGap !== undefined && c.recordOnly) {
      throw new Error(
        `Corpus case ${c.name} is recordOnly, so it is never compared and cannot have a knownGap`
      );
    }
    seen.add(c.name);
  }
  return cases;
}
