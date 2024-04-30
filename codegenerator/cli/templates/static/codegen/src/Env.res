%%private(
  let envSafe = EnvSafe.make(.)

  let getLogLevelConfig = (~name, ~default): Pino.logLevel =>
    envSafe->EnvSafe.get(.
      ~name,
      ~struct=S.union([
        S.literal(#trace),
        S.literal(#debug),
        S.literal(#info),
        S.literal(#warn),
        S.literal(#error),
        S.literal(#fatal),
        S.literal(#udebug),
        S.literal(#uinfo),
        S.literal(#uwarn),
        S.literal(#uerror),
        S.literal("")->S.variant((. _) => default),
        S.literal(None)->S.variant((. _) => default),
      ]),
    )
)

module EnvUtils = {
  let getEnvVar = (~typ, ~fallback=?, ~envSafe as env, name) => {
    let struct = switch fallback {
    | Some(fallbackContent) => typ->S.option->S.Option.getOr(fallbackContent)
    | None => typ
    }
    env->EnvSafe.get(. ~name, ~struct)
  }

  let getStringEnvVar = getEnvVar(~typ=S.string)
  let getOptStringEnvVar = getEnvVar(~typ=S.string->S.option)
  let getIntEnvVar = getEnvVar(~typ=S.int)
  let getOptIntEnvVar = getEnvVar(~typ=S.int->S.option)
  let getFloatEnvVar = getEnvVar(~typ=S.float)
  let getOptFloatEnvVar = getEnvVar(~typ=S.float->S.option)
  let getBoolEnvVar = getEnvVar(~typ=S.bool)
}

let maxEventFetchedQueueSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=100_000, "MAX_QUEUE_SIZE")
let maxProcessBatchSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=5_000, "MAX_BATCH_SIZE")

let metricsPort =
  envSafe->EnvSafe.get(. ~name="METRICS_PORT", ~struct=S.Int.port(. S.int), ~devFallback=9898)

let tuiOffEnvVar = envSafe->EnvSafe.get(. ~name="TUI_OFF", ~struct=S.bool, ~devFallback=false)

let logFilePath =
  envSafe->EnvSafe.get(. ~name="LOG_FILE", ~struct=S.string, ~devFallback="logs/envio.log")
let userLogLevel = getLogLevelConfig(~name="LOG_LEVEL", ~default=#info)
let defaultFileLogLevel = getLogLevelConfig(~name="FILE_LOG_LEVEL", ~default=#trace)

type logStrategyType =
  | @as("ecs-file") EcsFile
  | @as("ecs-console") EcsConsole
  | @as("ecs-console-multistream") EcsConsoleMultistream
  | @as("file-only") FileOnly
  | @as("console-raw") ConsoleRaw
  | @as("console-pretty") ConsolePretty
  | @as("both-prettyconsole") Both
let logStrategy = envSafe->EnvSafe.get(.
  ~name="LOG_STRATEGY",
  ~struct=S.union([
    S.literal(EcsFile),
    S.literal(EcsConsole),
    S.literal(EcsConsoleMultistream),
    S.literal(FileOnly),
    S.literal(ConsoleRaw),
    S.literal(ConsolePretty),
    S.literal(Both),
    // Two default values are pretty print to the console only.
    S.literal("")->S.variant((. _) => ConsolePretty),
    S.literal(None)->S.variant((. _) => ConsolePretty),
  ]),
)

module Db = {
  let host =
    envSafe->EnvSafe.get(. ~name="ENVIO_PG_HOST", ~struct=S.string, ~devFallback="localhost")
  let port =
    envSafe->EnvSafe.get(. ~name="ENVIO_PG_PORT", ~struct=S.Int.port(. S.int), ~devFallback=5433)
  let user =
    envSafe->EnvSafe.get(. ~name="ENVIO_PG_USER", ~struct=S.string, ~devFallback="postgres")
  let password =
    envSafe->EnvSafe.get(.
      ~name="ENVIO_POSTGRES_PASSWORD",
      ~struct=S.string,
      ~devFallback="testing",
    )
  let database =
    envSafe->EnvSafe.get(. ~name="ENVIO_PG_DATABASE", ~struct=S.string, ~devFallback="envio-dev")
  let ssl = envSafe->EnvSafe.get(.
    ~name="ENVIO_PG_SSL_MODE",
    ~struct=S.string,
    //this is a dev fallback option for local deployments, shouldn't run in the prod env
    //the SSL modes should be provided as string otherwise as 'require' | 'allow' | 'prefer' | 'verify-full'
    ~devFallback=false->Obj.magic,
  )
}

module Hasura = {
  let responseLimit = EnvUtils.getOptIntEnvVar(~envSafe, "HASURA_RESPONSE_LIMIT")

  let graphqlEndpoint = EnvUtils.getStringEnvVar(
    ~envSafe,
    ~fallback="http://localhost:8080/v1/metadata",
    "HASURA_GRAPHQL_ENDPOINT",
  )

  let role = EnvUtils.getStringEnvVar(~envSafe, ~fallback="admin", "HASURA_GRAPHQL_ROLE")

  let secret = EnvUtils.getStringEnvVar(
    ~envSafe,
    ~fallback="testing",
    "HASURA_GRAPHQL_ADMIN_SECRET",
  )
}

module Configurable = {
  let shouldUseHypersyncClientDecoder =
    envSafe->EnvSafe.get(. ~name="USE_HYPERSYNC_CLIENT_DECODER", ~struct=S.option(S.bool))

  /**
    Used for backwards compatability
  */
  let unstable__temp_unordered_head_mode = envSafe->EnvSafe.get(.
    ~name="UNSTABLE__TEMP_UNORDERED_HEAD_MODE",
    ~struct=S.option(S.bool),
  )

  let isUnorderedMultichainMode =
    envSafe->EnvSafe.get(. ~name="UNORDERED_MULTICHAIN_MODE", ~struct=S.option(S.bool))

  module SyncConfig = {
    let initialBlockInterval = EnvUtils.getOptIntEnvVar(
      ~envSafe,
      "UNSTABLE__SYNC_CONFIG_INITIAL_BLOCK_INTERVAL",
    )
    let backoffMultiplicative = EnvUtils.getOptFloatEnvVar(
      ~envSafe,
      "UNSTABLE__SYNC_CONFIG_BACKOFF_MULTIPLICATIVE",
    )
    let accelerationAdditive = EnvUtils.getOptIntEnvVar(
      ~envSafe,
      "UNSTABLE__SYNC_CONFIG_ACCELERATION_ADDITIVE",
    )
    let intervalCeiling = EnvUtils.getOptIntEnvVar(
      ~envSafe,
      "UNSTABLE__SYNC_CONFIG_INTERVAL_CEILING",
    )
  }
}

// You need to close the envSafe after you're done with it so that it immediately tells you about your  misconfigured environment on startup.
envSafe->EnvSafe.close
