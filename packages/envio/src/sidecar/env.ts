export const DEFAULT_PUBLIC_PORT = 9900;
export const DEFAULT_SIDECAR_INTERNAL_URL = "http://127.0.0.1:9901";
export const DEFAULT_INDEXER_INTERNAL_URL = "http://127.0.0.1:9899";
export const DEFAULT_RESPONSE_LIMIT = 1000;
/** Under the pod's terminationGracePeriodSeconds (30 s). */
export const DEFAULT_GRACE_MS = 20_000;
/** wiki 09 section 4: a function that runs longer is abandoned and counted. */
export const DEFAULT_FUNCTION_TIMEOUT_MS = 60_000;
/** wiki 09 section 3: accepted call ids kept for redelivery dedupe. */
export const DEFAULT_DEDUPE_MAX = 100_000;
/** wiki 09 section 4: how long `emit` retries before it rejects. */
export const DEFAULT_EMIT_RETRY_MAX_MS = 600_000;
/** Connection failures in a row before new emits fail fast; 0 turns the breaker off. */
export const DEFAULT_EMIT_BREAKER_FAILURES = 5;
/** How long the breaker stays open before the next emit probes the indexer. */
export const DEFAULT_EMIT_BREAKER_COOLDOWN_MS = 5_000;

export type SidecarEnv = {
  /** Routable user API port (`ENVIO_SIDECAR_PORT`). */
  readonly publicPort: number;
  /** Loopback port the indexer posts calls to, taken from `ENVIO_SIDECAR_INTERNAL_URL`. */
  readonly internalPort: number;
  /** Where webhooks go (`ENVIO_INDEXER_INTERNAL_URL`). */
  readonly indexerInternalUrl: string;
  /** Hasura endpoint for the read client (`ENVIO_GRAPHQL_URL`), absent in unit tests. */
  readonly graphqlUrl: string | undefined;
  readonly graphqlRole: string | undefined;
  readonly graphqlSecret: string | undefined;
  readonly webhookSecret: string | undefined;
  /** Checked against the GraphQL layer's resolver calls (`ENVIO_RESOLVER_SECRET`); unset accepts any. */
  readonly resolverSecret: string | undefined;
  readonly responseLimit: number;
  /** `ENVIO_SIDECAR_LOG_LEVEL`. Not `LOG_LEVEL`: Envio Cloud sets that to trace for the
   * whole pod, which would bury user logs. */
  readonly logLevel: string;
  /** ECS JSON lines, like the indexer's, when `LOG_STRATEGY` is `ecs-*`. */
  readonly ecsLogs: boolean;
  /** Longest `close()` waits for running work (`ENVIO_SIDECAR_GRACE_MS`). */
  readonly graceMs: number;
  /** Default per-function timeout (`ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS`), 0 turns it off. */
  readonly functionTimeoutMs: number;
  /** Accepted call ids remembered to dedupe redelivery (`ENVIO_SIDECAR_DEDUPE_MAX`). */
  readonly dedupeMax: number;
  /** How long `emit` keeps retrying a webhook (`ENVIO_EMIT_RETRY_MAX_MS`). */
  readonly emitRetryMaxMs: number;
  /** Connection failures in a row that open the emit breaker (`ENVIO_EMIT_BREAKER_FAILURES`), 0 = off. */
  readonly emitBreakerFailures: number;
  /** Open time before a probe (`ENVIO_EMIT_BREAKER_COOLDOWN_MS`). */
  readonly emitBreakerCooldownMs: number;
};

const readPort = (env: NodeJS.ProcessEnv, name: string, fallback: number): number => {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(`${name} must be a port number, got '${raw}'`);
  }
  return port;
};

const readInt = (env: NodeJS.ProcessEnv, name: string, fallback: number, min = 1): number => {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min) {
    throw new Error(`${name} must be ${min === 0 ? "a non-negative" : "a positive"} integer, got '${raw}'`);
  }
  return value;
};

const portOfUrl = (name: string, raw: string): number => {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`${name} must be a URL, got '${raw}'`);
  }
  if (url.port !== "") return Number(url.port);
  return url.protocol === "https:" ? 443 : 80;
};

const optional = (env: NodeJS.ProcessEnv, name: string): string | undefined => {
  const raw = env[name];
  return raw === undefined || raw === "" ? undefined : raw;
};

export const readEnv = (env: NodeJS.ProcessEnv = process.env): SidecarEnv => ({
  publicPort: readPort(env, "ENVIO_SIDECAR_PORT", DEFAULT_PUBLIC_PORT),
  internalPort: portOfUrl(
    "ENVIO_SIDECAR_INTERNAL_URL",
    optional(env, "ENVIO_SIDECAR_INTERNAL_URL") ?? DEFAULT_SIDECAR_INTERNAL_URL,
  ),
  indexerInternalUrl: (optional(env, "ENVIO_INDEXER_INTERNAL_URL") ?? DEFAULT_INDEXER_INTERNAL_URL).replace(
    /\/+$/,
    "",
  ),
  graphqlUrl: optional(env, "ENVIO_GRAPHQL_URL"),
  graphqlRole: optional(env, "ENVIO_GRAPHQL_ROLE"),
  graphqlSecret: optional(env, "ENVIO_GRAPHQL_SECRET"),
  webhookSecret: optional(env, "ENVIO_WEBHOOK_SECRET"),
  resolverSecret: optional(env, "ENVIO_RESOLVER_SECRET"),
  responseLimit: readInt(
    env,
    "ENVIO_HASURA_RESPONSE_LIMIT",
    readInt(env, "HASURA_RESPONSE_LIMIT", DEFAULT_RESPONSE_LIMIT),
  ),
  logLevel: optional(env, "ENVIO_SIDECAR_LOG_LEVEL") ?? "info",
  ecsLogs: optional(env, "LOG_STRATEGY")?.startsWith("ecs-") ?? false,
  graceMs: readInt(env, "ENVIO_SIDECAR_GRACE_MS", DEFAULT_GRACE_MS, 0),
  functionTimeoutMs: readInt(env, "ENVIO_SIDECAR_FUNCTION_TIMEOUT_MS", DEFAULT_FUNCTION_TIMEOUT_MS, 0),
  dedupeMax: readInt(env, "ENVIO_SIDECAR_DEDUPE_MAX", DEFAULT_DEDUPE_MAX),
  emitRetryMaxMs: readInt(env, "ENVIO_EMIT_RETRY_MAX_MS", DEFAULT_EMIT_RETRY_MAX_MS, 0),
  emitBreakerFailures: readInt(env, "ENVIO_EMIT_BREAKER_FAILURES", DEFAULT_EMIT_BREAKER_FAILURES, 0),
  emitBreakerCooldownMs: readInt(env, "ENVIO_EMIT_BREAKER_COOLDOWN_MS", DEFAULT_EMIT_BREAKER_COOLDOWN_MS, 0),
});
