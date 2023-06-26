open RescriptMocha
open Mocha

let configPathString = "./config.yaml"

type rpc_config = {
  url: string,
  initial_block_interval: int,
  backoff_multiplicative: float,
  acceleration_additive: int,
  interval_ceiling: int,
  backoff_millis: int,
  query_timeout_millis: int,
}
type network_conf = {id: string, rpc_config: rpc_config}
type config = {networks: array<network_conf>}

let configYaml: config = ConfigUtils.loadConfigYaml(~codegenConfigPath=configPathString)
let firstNetworkConfig = configYaml.networks[0]

let actualChainConfig = Js.Dict.unsafeGet(Config.config, firstNetworkConfig.id)

describe("Sync Config Test", () => {
  it("initial_block_interval", () => {
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.initial_block_interval,
      actualChainConfig.syncConfig.initialBlockInterval,
    )
  })
  it("backoff_multiplicative", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.backoff_multiplicative,
      actualChainConfig.syncConfig.backoffMultiplicative,
    )
  })
  it("acceleration_additive", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.acceleration_additive,
      actualChainConfig.syncConfig.accelerationAdditive,
    )
  })
  it("interval_ceiling", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.interval_ceiling,
      actualChainConfig.syncConfig.intervalCeiling,
    )
  })
  it("backoff_millis", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.backoff_millis,
      actualChainConfig.syncConfig.backoffMillis,
    )
  })
  it("query_timeout_millis", () => {
    let firstNetworkConfig = configYaml.networks[0]
    Assert.deep_equal(
      firstNetworkConfig.rpc_config.query_timeout_millis,
      actualChainConfig.syncConfig.queryTimeoutMillis,
    )
  })
})
