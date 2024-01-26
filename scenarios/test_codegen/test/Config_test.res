open RescriptMocha
open Mocha

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

describe("Sync Config Test", () => {
  it("initial_block_interval", () => {
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.initial_block_interval,
      generatedSyncConfig.initialBlockInterval,
    )
  })
  it("backoff_multiplicative", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.backoff_multiplicative,
      generatedSyncConfig.backoffMultiplicative,
    )
  })
  it("acceleration_additive", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.acceleration_additive,
      generatedSyncConfig.accelerationAdditive,
    )
  })
  it("interval_ceiling", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.interval_ceiling,
      generatedSyncConfig.intervalCeiling,
    )
  })
  it("backoff_millis", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.backoff_millis,
      generatedSyncConfig.backoffMillis,
    )
  })
  it("query_timeout_millis", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.query_timeout_millis,
      generatedSyncConfig.queryTimeoutMillis,
    )
  })
})
