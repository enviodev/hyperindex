open Ava

let configPathString = "./config.yaml"

type sync_config = {
  initial_block_interval: int,
  backoff_multiplicative: float,
  acceleration_additive: int,
  interval_ceiling: int,
  backoff_millis: int,
  query_timeout_millis: int,
}

type rpc_config = {
  url: string,
  unstable__sync_config: sync_config,
}
type network_conf = {id: int, rpc_config: rpc_config}
type config = {networks: array<network_conf>}

let configYaml: config = ConfigUtils.loadConfigYaml(~codegenConfigPath=configPathString)
let firstNetworkConfig = configYaml.networks[0]

let generatedChainConfig = Config.config->ChainMap.get(Chain_1337)
let generatedSyncConfig = switch generatedChainConfig.syncSource {
| Rpc({syncConfig}) => syncConfig
| _ => Js.Exn.raiseError("Expected an rpc config")
}

test("Sync Config Test: initial_block_interval", (. t) => {
  t->Assert.deepEqual(.
    firstNetworkConfig.rpc_config.unstable__sync_config.initial_block_interval,
    generatedSyncConfig.initialBlockInterval,
  )
})
test("Sync Config Test: backoff_multiplicative", (. t) => {
  let firstNetworkConfig = configYaml.networks[0]
  t->Assert.deepEqual(.
    firstNetworkConfig.rpc_config.unstable__sync_config.backoff_multiplicative,
    generatedSyncConfig.backoffMultiplicative,
  )
})
test("Sync Config Test: acceleration_additive", (. t) => {
  let firstNetworkConfig = configYaml.networks[0]
  t->Assert.deepEqual(.
    firstNetworkConfig.rpc_config.unstable__sync_config.acceleration_additive,
    generatedSyncConfig.accelerationAdditive,
  )
})
test("Sync Config Test: interval_ceiling", (. t) => {
  let firstNetworkConfig = configYaml.networks[0]
  t->Assert.deepEqual(.
    firstNetworkConfig.rpc_config.unstable__sync_config.interval_ceiling,
    generatedSyncConfig.intervalCeiling,
  )
})
test("Sync Config Test: backoff_millis", (. t) => {
  let firstNetworkConfig = configYaml.networks[0]
  t->Assert.deepEqual(.
    firstNetworkConfig.rpc_config.unstable__sync_config.backoff_millis,
    generatedSyncConfig.backoffMillis,
  )
})
test("Sync Config Test: query_timeout_millis", (. t) => {
  let firstNetworkConfig = configYaml.networks[0]
  t->Assert.deepEqual(.
    firstNetworkConfig.rpc_config.unstable__sync_config.query_timeout_millis,
    generatedSyncConfig.queryTimeoutMillis,
  )
})
