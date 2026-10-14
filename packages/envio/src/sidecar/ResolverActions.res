// Bindings to resolvers.ts, which the sidecar runtime shares: one builder for
// the Hasura actions the indexer applies and the file envio serve reads.

// Exactly one of the two: a value baked into the metadata, or an env var the
// GraphQL layer reads it from.
type secret = {value?: string, fromEnv?: string}

type buildOptions = {
  sidecarUrl: string,
  secret?: secret,
}

type metadata = JSON.t

@module("./resolvers.js")
external build: (dict<Config.resolver>, dict<dict<string>>, buildOptions) => metadata =
  "buildResolverMetadata"

type applyOptions = {
  endpoint: string,
  role: string,
  adminSecret: string,
  metadata: metadata,
}

@module("./resolvers.js")
external apply: applyOptions => promise<unit> = "applyResolverMetadata"
