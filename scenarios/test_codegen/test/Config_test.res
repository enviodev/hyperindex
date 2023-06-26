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
type network_conf = {id: string, rpc_config: rpc_config}
type config = {networks: array<network_conf>}

let configYaml: config = ConfigUtils.loadConfigYaml(~codegenConfigPath=configPathString)
let firstNetworkConfig = configYaml.networks[0]

let generatedChainConfig = Js.Dict.unsafeGet(Config.config, firstNetworkConfig.id)

describe("Sync Config Test", () => {
  it("initial_block_interval", () => {
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.initial_block_interval,
      generatedChainConfig.syncConfig.initialBlockInterval,
    )
  })
  it("backoff_multiplicative", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.backoff_multiplicative,
      generatedChainConfig.syncConfig.backoffMultiplicative,
    )
  })
  it("acceleration_additive", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.acceleration_additive,
      generatedChainConfig.syncConfig.accelerationAdditive,
    )
  })
  it("interval_ceiling", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.interval_ceiling,
      generatedChainConfig.syncConfig.intervalCeiling,
    )
  })
  it("backoff_millis", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.backoff_millis,
      generatedChainConfig.syncConfig.backoffMillis,
    )
  })
  it("query_timeout_millis", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.unstable__sync_config.query_timeout_millis,
      generatedChainConfig.syncConfig.queryTimeoutMillis,
    )
  })
})
