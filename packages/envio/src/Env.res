// Loads the .env from the root working directory
%%raw(`import 'dotenv/config'`)

%%private(let envSafe = EnvSafe.make())

let targetBufferSize = envSafe->EnvSafe.get("ENVIO_INDEXING_MAX_BUFFER_SIZE", S.option(S.int))
let maxAddrInPartition = envSafe->EnvSafe.get("MAX_PARTITION_SIZE", S.int, ~fallback=5_000)

// Most parallel in-flight queries a single chain may have at once, across all
// its partitions (consumed as FetchState.maxChainConcurrency).
let maxChainConcurrency = 100

// Switch a single contract to client-side address filtering
// once its registered address count crosses this threshold. Keeping addresses
// server-side spreads the contract across ceil(count / maxAddrInPartition)
// partitions, each holding an in-flight query slot; capping a contract at half
// the chain's concurrency budget stops one busy contract from monopolising them.
let clientFilterAddressThreshold =
  envSafe->EnvSafe.get(
    "ENVIO_CLIENT_FILTER_ADDRESS_THRESHOLD",
    S.int,
    ~fallback=maxAddrInPartition * maxChainConcurrency / 2,
  )

// Target number of in-memory objects (uncommitted entity/effect changes plus
// unwritten batch items) the store holds before processing waits for the write
// cycle to catch up.
let inMemoryObjectsTarget =
  envSafe->EnvSafe.get("ENVIO_IN_MEMORY_OBJECTS_TARGET", S.int, ~fallback=100_000)->Int.toFloat

// FIXME: This broke HS grafana dashboard. Should investigate it later. Maybe we should use :: as a default value?
// We want to be able to set it to 0.0.0.0
// to allow to passthrough the port from a Docker container
// let serverHost = envSafe->EnvSafe.get("ENVIO_INDEXER_HOST", S.string, ~fallback="localhost")
let serverPort =
  envSafe->EnvSafe.get(
    "ENVIO_INDEXER_PORT",
    S.int->S.port,
    ~fallback=envSafe->EnvSafe.get("METRICS_PORT", S.int->S.port, ~fallback=9898),
  )

let tuiEnvVar = envSafe->EnvSafe.get("ENVIO_TUI", S.option(S.bool))

let logLevelSchema = S.enum([
  #trace,
  #debug,
  #info,
  #warn,
  #error,
  #fatal,
  #udebug,
  #uinfo,
  #uwarn,
  #uerror,
  #silent,
])
let logFilePath = envSafe->EnvSafe.get("LOG_FILE", S.string, ~fallback="logs/envio.log")
let userLogLevel = envSafe->EnvSafe.get("LOG_LEVEL", S.option(logLevelSchema))
let defaultFileLogLevel = envSafe->EnvSafe.get("FILE_LOG_LEVEL", logLevelSchema, ~fallback=#trace)

let prodEnvioAppUrl = "https://envio.dev"
let envioAppUrl = envSafe->EnvSafe.get("ENVIO_APP", S.string, ~fallback=prodEnvioAppUrl)
let envioApiToken = envSafe->EnvSafe.get("ENVIO_API_TOKEN", S.option(S.string))
let hyperSyncClientTimeoutMillis =
  envSafe->EnvSafe.get("ENVIO_HYPERSYNC_CLIENT_TIMEOUT_MILLIS", S.int, ~fallback=120_000)

let hypersyncClientSerializationFormat =
  envSafe->EnvSafe.get(
    "ENVIO_HYPERSYNC_CLIENT_SERIALIZATION_FORMAT",
    HyperSyncClient.serializationFormatSchema,
    ~fallback=CapnProto,
  )

let hypersyncClientEnableQueryCaching =
  envSafe->EnvSafe.get("ENVIO_HYPERSYNC_CLIENT_ENABLE_QUERY_CACHING", S.bool, ~fallback=true)

let hypersyncLogLevel =
  envSafe->EnvSafe.get("ENVIO_HYPERSYNC_LOG_LEVEL", HyperSyncClient.logLevelSchema, ~fallback=#info)

let logStrategy =
  envSafe->EnvSafe.get(
    "LOG_STRATEGY",
    S.enum([
      Logging.EcsFile,
      EcsConsole,
      EcsConsoleMultistream,
      FileOnly,
      ConsoleRaw,
      ConsolePretty,
      Both,
    ]),
    ~fallback=ConsolePretty,
  )

Logging.setLogger(
  Logging.makeLogger(
    ~logStrategy,
    ~logFilePath,
    ~defaultFileLogLevel,
    ~userLogLevel=userLogLevel->Option.getOr(#info),
  ),
)

module Db = {
  let host = envSafe->EnvSafe.get("ENVIO_PG_HOST", S.string, ~devFallback="localhost")
  let port = envSafe->EnvSafe.get("ENVIO_PG_PORT", S.int->S.port, ~devFallback=5433)
  let user = envSafe->EnvSafe.get("ENVIO_PG_USER", S.string, ~devFallback="postgres")
  let password = envSafe->EnvSafe.get(
    "ENVIO_PG_PASSWORD",
    S.string,
    ~fallback={
      envSafe->EnvSafe.get("ENVIO_POSTGRES_PASSWORD", S.string, ~fallback="testing")
    },
  )
  let database = envSafe->EnvSafe.get("ENVIO_PG_DATABASE", S.string, ~devFallback="envio-dev")
  let publicSchema = envSafe->EnvSafe.get(
    "ENVIO_PG_SCHEMA",
    S.string,
    ~fallback={
      envSafe->EnvSafe.get("ENVIO_PG_PUBLIC_SCHEMA", S.string, ~fallback="public")
    },
  )
  let ssl = envSafe->EnvSafe.get(
    "ENVIO_PG_SSL_MODE",
    Postgres.sslOptionsSchema,
    //this is a dev fallback option for local deployments, shouldn't run in the prod env
    //the SSL modes should be provided as string otherwise as 'require' | 'allow' | 'prefer' | 'verify-full'
    ~devFallback=Bool(false),
  )
  let maxConnections = envSafe->EnvSafe.get("ENVIO_PG_MAX_CONNECTIONS", S.int, ~fallback=2)
}

// Required env vars are validated lazily in PgStorage when the user
// opts into ClickHouse via `storage.clickhouse: true` in config.yaml.
//
// Reads run at call time instead of module load. `envio dev` injects these
// vars into `process.env` after booting its ClickHouse container, and that
// happens strictly after this module has already been evaluated — caching
// at module load would lock in `None` and defeat the injection.
module ClickHouse = {
  %%private(
    let read: string => option<string> = %raw(`(k) => {
      const v = process.env[k];
      return v === undefined || v === "" ? undefined : v;
    }`)
    // Empty password is a valid, passwordless ClickHouse user — distinguish
    // "unset" (None) from "set but empty" (Some("")).
    let readAllowEmpty: string => option<string> = %raw(`(k) => process.env[k]`)
  )
  let host = () => read("ENVIO_CLICKHOUSE_HOST")
  let database = () => read("ENVIO_CLICKHOUSE_DATABASE")
  let username = () => read("ENVIO_CLICKHOUSE_USERNAME")
  let password = () => readAllowEmpty("ENVIO_CLICKHOUSE_PASSWORD")
  let replicated = () =>
    switch read("ENVIO_CLICKHOUSE_REPLICATED") {
    | None => false
    | Some("true") => true
    | Some(other) =>
      JsError.throwWithMessage(
        `Invalid ENVIO_CLICKHOUSE_REPLICATED value: "${other}". Only "true" is accepted.`,
      )
    }
  let databaseEngine = () => read("ENVIO_CLICKHOUSE_DATABASE_ENGINE")
}

// The resolver process runs on its own, so its database connection comes from
// the same ENVIO_PG_* vars the indexer's does -- point them wherever reads
// should go. Only what genuinely differs from the indexer's shape gets a var
// of its own.
//
// Read at call time rather than module load, for the same reason ClickHouse's
// are: `envio dev` injects them after this module has been evaluated.
module Resolvers = {
  %%private(
    let read: string => option<string> = %raw(`(k) => {
      const v = process.env[k];
      return v === undefined || v === "" ? undefined : v;
    }`)

    let readInt = (key, ~fallback) =>
      switch read(key) {
      | None => fallback
      | Some(raw) =>
        switch raw->Int.fromString {
        | Some(value) if value > 0 => value
        | _ =>
          JsError.throwWithMessage(
            `Invalid ${key} value: "${raw}". Expected a positive whole number.`,
          )
        }
      }
  )

  let port = () =>
    switch readInt("ENVIO_RESOLVERS_PORT", ~fallback=9900) {
    | value if value <= 65535 => value
    | value =>
      // `readInt` only rejects zero and below, so an out-of-range port reached
      // `listen` and failed there instead, naming neither the variable nor why.
      JsError.throwWithMessage(
        `Invalid ENVIO_RESOLVERS_PORT value: "${value->Int.toString}". A TCP port is 1 to 65535.`,
      )
    }

  // Sized as concurrent heavy requests x per-request fan-out, not as the
  // indexer's two long-lived connections: one resolver request can hold four
  // at once.
  let poolSize = () => readInt("ENVIO_RESOLVERS_POOL_SIZE", ~fallback=25)

  let poolWaitTimeoutMs = () => readInt("ENVIO_RESOLVERS_POOL_WAIT_TIMEOUT_MS", ~fallback=10_000)

  // `envio dev` sets this on the resolver process it spawns: locally the
  // caller is the person who wrote the resolver, so an unexpected error's own
  // message is what they need. Deployed, the caller may be the public internet
  // and the message can carry a connection string.
  let exposeErrors = () =>
    switch read("ENVIO_RESOLVERS_EXPOSE_ERRORS") {
    | None
    | Some("false") => false
    | Some("true") => true
    | Some(other) =>
      // Refused rather than read as false: a typo here silently keeps a
      // resolver's own error messages off the wire, which is the opposite of
      // what the person who set it wanted, and nothing would say so.
      JsError.throwWithMessage(
        `Invalid ENVIO_RESOLVERS_EXPOSE_ERRORS value: "${other}". Expected "true" or "false".`,
      )
    }

  // The URL *Hasura* posts to, which is not the address this process binds:
  // it is baked into every action, so Hasura has no other way to reach the
  // resolvers.
  let publicUrl = () => read("ENVIO_RESOLVERS_PUBLIC_URL")

  // How often the metadata is re-asserted. 0 disables it, for a deployment
  // where something else owns Hasura's metadata.
  let metadataIntervalMs = () =>
    switch read("ENVIO_RESOLVERS_METADATA_INTERVAL_MS") {
    | None => 60_000
    | Some(raw) =>
      switch raw->Int.fromString {
      | Some(value) if value >= 0 => value
      | _ =>
        JsError.throwWithMessage(
          `Invalid ENVIO_RESOLVERS_METADATA_INTERVAL_MS value: "${raw}". Expected a whole number of milliseconds, or 0 to disable.`,
        )
      }
    }

  // Shared with Hasura, which presents it on every action call. Unset means the
  // handler cannot tell Hasura from anything else that reaches the socket, so
  // it has to believe the role in the request body.
  let actionSecret = () => read("ENVIO_RESOLVERS_ACTION_SECRET")

  // Read raw rather than through `Env.Hasura`, whose dev fallbacks would have
  // this process apply metadata to a localhost Hasura nobody asked for. Only
  // an endpoint someone set means "there is a Hasura to register with".
  let hasuraEndpoint = () => read("HASURA_GRAPHQL_ENDPOINT")
  let hasuraAdminSecret = () => read("HASURA_GRAPHQL_ADMIN_SECRET")

  // Set where a transaction-mode pooler is the only way in. Those reject
  // named prepared statements, so this gives up plan reuse.
  let poolerBacked = () =>
    switch read("ENVIO_RESOLVERS_POOLER_BACKED") {
    | None
    | Some("false") => false
    | Some("true") => true
    | Some(other) =>
      JsError.throwWithMessage(
        `Invalid ENVIO_RESOLVERS_POOLER_BACKED value: "${other}". Expected "true" or "false".`,
      )
    }
}

module Hasura = {
  // Disable it on HS indexer run, since we don't have Hasura credentials anyways
  // Also, it might be useful for some users who don't care about Hasura
  let enabled = envSafe->EnvSafe.get("ENVIO_HASURA", S.bool, ~fallback=true)

  let responseLimit = switch envSafe->EnvSafe.get("ENVIO_HASURA_RESPONSE_LIMIT", S.option(S.int)) {
  | Some(_) as s => s
  | None => envSafe->EnvSafe.get("HASURA_RESPONSE_LIMIT", S.option(S.int))
  }

  let graphqlEndpoint =
    envSafe->EnvSafe.get(
      "HASURA_GRAPHQL_ENDPOINT",
      S.string,
      ~devFallback="http://localhost:8080/v1/metadata",
    )

  // Lazy on purpose. `graphqlEndpoint` is required in production, and a missing
  // one arrives here as undefined -- slicing it threw a bare TypeError at import
  // and killed the process before `EnvSafe.close` could say which variable was
  // missing. Only the dev TUI reads this, so there is nothing to compute up
  // front.
  let url = () => graphqlEndpoint->String.slice(~start=0, ~end=-("/v1/metadata"->String.length))

  let role = envSafe->EnvSafe.get("HASURA_GRAPHQL_ROLE", S.string, ~devFallback="admin")

  let secret = envSafe->EnvSafe.get("HASURA_GRAPHQL_ADMIN_SECRET", S.string, ~devFallback="testing")

  let aggregateEntities = envSafe->EnvSafe.get(
    "ENVIO_HASURA_PUBLIC_AGGREGATE",
    S.union([
      S.array(S.string),
      // Temporary workaround: Hosted Service can't use commas in env vars for multiple entities.
      // Will be removed once comma support is added — don't rely on this.
      S.string->S.transform(s => {
        parser: string =>
          switch string->String.split("&") {
          | []
          | [_] =>
            s.fail(`Provide an array of entities in the JSON format.`)
          | entities => entities
          },
      }),
    ]),
    ~fallback=[],
  )
}

module Configurable = {
  module SyncConfig = {
    let initialBlockInterval =
      envSafe->EnvSafe.get("ENVIO_RPC_INITIAL_BLOCK_INTERVAL", S.option(S.int))
    let backoffMultiplicative =
      envSafe->EnvSafe.get("ENVIO_RPC_BACKOFF_MULTIPLICATIVE", S.option(S.float))
    let accelerationAdditive =
      envSafe->EnvSafe.get("ENVIO_RPC_ACCELERATION_ADDITIVE", S.option(S.int))
    let intervalCeiling = envSafe->EnvSafe.get("ENVIO_RPC_INTERVAL_CEILING", S.option(S.int))
  }
}

module ThrottleWrites = {
  let chainMetadataIntervalMillis =
    envSafe->EnvSafe.get("ENVIO_THROTTLE_CHAIN_METADATA_INTERVAL_MILLIS", S.int, ~devFallback=500)
  let pruneStaleDataIntervalMillis =
    envSafe->EnvSafe.get(
      "ENVIO_THROTTLE_PRUNE_STALE_DATA_INTERVAL_MILLIS",
      S.int,
      ~devFallback=30_000,
    )
}

// You need to close the envSafe after you're done with it so that it immediately tells you about your  misconfigured environment on startup.
envSafe->EnvSafe.close
