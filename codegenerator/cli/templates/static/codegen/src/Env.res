Dotenv.initialize()
%%private(
  let envSafe = EnvSafe.make()

  let getLogLevelConfig = (name, ~default): Pino.logLevel =>
    envSafe->EnvSafe.get(
      name,
      S.enum([#trace, #debug, #info, #warn, #error, #fatal, #udebug, #uinfo, #uwarn, #uerror]),
      ~fallback=default,
    )
)
// resets the timestampCaughtUpToHeadOrEndblock after a restart when true
let updateSyncTimeOnRestart =
  envSafe->EnvSafe.get("UPDATE_SYNC_TIME_ON_RESTART", S.bool, ~fallback=true)
let maxEventFetchedQueueSize = envSafe->EnvSafe.get("MAX_QUEUE_SIZE", S.int, ~fallback=100_000)
let maxProcessBatchSize = envSafe->EnvSafe.get("MAX_BATCH_SIZE", S.int, ~fallback=5_000)
let maxAddrInPartition = envSafe->EnvSafe.get("MAX_PARTITION_SIZE", S.int, ~fallback=5_000)
let maxPartitionConcurrency =
  envSafe->EnvSafe.get("ENVIO_MAX_PARTITION_CONCURRENCY", S.int, ~fallback=10)

let metricsPort = envSafe->EnvSafe.get("METRICS_PORT", S.int->S.port, ~devFallback=9898)

let tuiOffEnvVar = envSafe->EnvSafe.get("TUI_OFF", S.bool, ~fallback=false)

let logFilePath = envSafe->EnvSafe.get("LOG_FILE", S.string, ~fallback="logs/envio.log")
let userLogLevel = getLogLevelConfig("LOG_LEVEL", ~default=#info)
let defaultFileLogLevel = getLogLevelConfig("FILE_LOG_LEVEL", ~default=#trace)

let prodEnvioAppUrl = "https://envio.dev"
let envioAppUrl = envSafe->EnvSafe.get("ENVIO_APP", S.string, ~fallback=prodEnvioAppUrl)
let envioApiToken = envSafe->EnvSafe.get("ENVIO_API_TOKEN", S.option(S.string))
let hyperSyncClientTimeoutMillis =
  envSafe->EnvSafe.get("ENVIO_HYPERSYNC_CLIENT_TIMEOUT_MILLIS", S.int, ~fallback=120_000)

/** 
This is the number of retries that the binary client makes before rejecting the promise with an error 
Default is 0 so that the indexer can handle retries internally
*/
let hyperSyncClientMaxRetries =
  envSafe->EnvSafe.get("ENVIO_HYPERSYNC_CLIENT_MAX_RETRIES", S.int, ~fallback=0)

module Benchmark = {
  module SaveDataStrategy: {
    type t
    let schema: S.t<t>
    let default: t
    let shouldSaveJsonFile: t => bool
    let shouldSavePrometheus: t => bool
    let shouldSaveData: t => bool
  } = {
    @unboxed
    type t = Bool(bool) | @as("json-file") JsonFile | @as("prometheus") Prometheus

    let schema = S.enum([Bool(true), Bool(false), JsonFile, Prometheus])
    let default = Bool(false)

    let shouldSaveJsonFile = self =>
      switch self {
      | JsonFile | Bool(true) => true
      | _ => false
      }

    let shouldSavePrometheus = self =>
      switch self {
      | Prometheus => true
      // Always save benchmarks in Prometheus in TUI mode
      // This is needed for Dev Console profiler
      // FIXME: This doesn't take into account the arg from the CLI
      | _ => !tuiOffEnvVar
      }

    let shouldSaveData = self =>
      self->shouldSavePrometheus || self->shouldSaveJsonFile
  }

  let saveDataStrategy =
    envSafe->EnvSafe.get(
      "ENVIO_SAVE_BENCHMARK_DATA",
      SaveDataStrategy.schema,
      ~fallback=SaveDataStrategy.default,
    )

  let shouldSaveData = saveDataStrategy->SaveDataStrategy.shouldSaveData

  /**
  StdDev involves saving sum of squares of data points, which could get very large.

  Currently only do this for local runs on json-file and not prometheus.
  */
  let shouldSaveStdDev =
    saveDataStrategy->SaveDataStrategy.shouldSaveJsonFile
}

let logStrategy =
  envSafe->EnvSafe.get(
    "LOG_STRATEGY",
    S.enum([Logging.EcsFile, EcsConsole, EcsConsoleMultistream, FileOnly, ConsoleRaw, ConsolePretty, Both]),
    ~fallback=ConsolePretty,
  )

Logging.setLogger(
  ~logStrategy,
  ~logFilePath,
  ~defaultFileLogLevel,
  ~userLogLevel,
)

module Db = {
  let host = envSafe->EnvSafe.get("ENVIO_PG_HOST", S.string, ~devFallback="localhost")
  let port = envSafe->EnvSafe.get("ENVIO_PG_PORT", S.int->S.port, ~devFallback=5433)
  let user = envSafe->EnvSafe.get("ENVIO_PG_USER", S.string, ~devFallback="postgres")
  let password = envSafe->EnvSafe.get("ENVIO_POSTGRES_PASSWORD", S.string, ~devFallback="testing")
  let database = envSafe->EnvSafe.get("ENVIO_PG_DATABASE", S.string, ~devFallback="envio-dev")
  let publicSchema = envSafe->EnvSafe.get("ENVIO_PG_PUBLIC_SCHEMA", S.string, ~fallback="public")
  let ssl = envSafe->EnvSafe.get(
    "ENVIO_PG_SSL_MODE",
    Postgres.sslOptionsSchema,
    //this is a dev fallback option for local deployments, shouldn't run in the prod env
    //the SSL modes should be provided as string otherwise as 'require' | 'allow' | 'prefer' | 'verify-full'
    ~devFallback=Bool(false),
  )
}

module Hasura = {
  let responseLimit = envSafe->EnvSafe.get("HASURA_RESPONSE_LIMIT", S.option(S.int))

  let graphqlEndpoint =
    envSafe->EnvSafe.get(
      "HASURA_GRAPHQL_ENDPOINT",
      S.string,
      ~devFallback="http://localhost:8080/v1/metadata",
    )

  let role = envSafe->EnvSafe.get("HASURA_GRAPHQL_ROLE", S.string, ~devFallback="admin")

  let secret = envSafe->EnvSafe.get("HASURA_GRAPHQL_ADMIN_SECRET", S.string, ~devFallback="testing")
}

module Configurable = {
  let shouldUseHypersyncClientDecoder =
    envSafe->EnvSafe.get("USE_HYPERSYNC_CLIENT_DECODER", S.option(S.bool))

  /**
    Used for backwards compatability
  */
  let unstable__temp_unordered_head_mode = envSafe->EnvSafe.get(
    "UNSTABLE__TEMP_UNORDERED_HEAD_MODE",
    S.option(S.bool),
  )

  let isUnorderedMultichainMode =
    envSafe->EnvSafe.get("UNORDERED_MULTICHAIN_MODE", S.option(S.bool))

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
      ~devFallback=10_000,
    )

  let deepCleanEntityHistoryCycleCount =
    envSafe->EnvSafe.get(
      "ENVIO_THROTTLE_DEEP_CLEAN_ENTITY_HISTORY_CYCLE_COUNT",
      S.int,
      ~devFallback=20,
    )

  let liveMetricsBenchmarkIntervalMillis =
    envSafe->EnvSafe.get(
      "ENVIO_THROTTLE_LIVE_METRICS_BENCHMARK_INTERVAL_MILLIS",
      S.int,
      ~devFallback=1_000,
    )

  let jsonFileBenchmarkIntervalMillis =
    envSafe->EnvSafe.get(
      "ENVIO_THROTTLE_JSON_FILE_BENCHMARK_INTERVAL_MILLIS",
      S.int,
      ~devFallback=500,
    )
}

// You need to close the envSafe after you're done with it so that it immediately tells you about your  misconfigured environment on startup.
envSafe->EnvSafe.close
