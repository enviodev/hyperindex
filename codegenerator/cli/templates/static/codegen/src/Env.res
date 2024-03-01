%%private(let envSafe = EnvSafe.make())

let maxEventFetchedQueueSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=100_000, "MAX_QUEUE_SIZE")
let maxProcessBatchSize = EnvUtils.getIntEnvVar(~envSafe, ~fallback=5_000, "MAX_BATCH_SIZE")
let hasuraResponseLimit = EnvUtils.getOptIntEnvVar(~envSafe, "HASURA_RESPONSE_LIMIT")

let numChains = Config.config->ChainMap.size
let maxPerChainQueueSize = maxEventFetchedQueueSize / numChains
