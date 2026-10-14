export const DEFAULT_PUBLIC_PORT = 9900;
export const DEFAULT_SIDECAR_INTERNAL_URL = "http://127.0.0.1:9901";
export const DEFAULT_INDEXER_INTERNAL_URL = "http://127.0.0.1:9899";
export const DEFAULT_RESPONSE_LIMIT = 1000;

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
  readonly responseLimit: number;
  readonly logLevel: string;
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

const readInt = (env: NodeJS.ProcessEnv, name: string, fallback: number): number => {
  const raw = env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value <= 0) {
    throw new Error(`${name} must be a positive integer, got '${raw}'`);
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
  responseLimit: readInt(
    env,
    "ENVIO_HASURA_RESPONSE_LIMIT",
    readInt(env, "HASURA_RESPONSE_LIMIT", DEFAULT_RESPONSE_LIMIT),
  ),
  logLevel: optional(env, "LOG_LEVEL") ?? "info",
});
