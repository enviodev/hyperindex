/**
 * Corpus case definitions for the differential GraphQL suite.
 *
 * Every case is executed against both real Hasura and `envio serve`; the
 * full JSON response bodies (data and errors alike) must be identical.
 */

export type Role = "admin" | "public";

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

export interface CorpusCase {
  /** Unique within the whole corpus; used for snapshot file names. */
  name: string;
  query: string;
  variables?: Record<string, unknown>;
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
    seen.add(c.name);
  }
  return cases;
}
