type contract = {
  name: string,
  abi: Ethers.abi,
  addresses: array<Ethers.ethAddress>,
  events: array<Types.eventName>,
}

type syncConfig = {
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
}

type serverUrl = string

type rpcConfig = {
  provider: Ethers.JsonRpcProvider.t,
  syncConfig: syncConfig,
}

/**
A generic type where for different values of HyperSync and Rpc.
Where first param 'a represents the value for hypersync and the second
param 'b for rpc
*/
type source<'a, 'b> = HyperSync('a) | Rpc('b)

type syncSource = source<serverUrl, rpcConfig>

type chainConfig = {
  syncSource: syncSource,
  startBlock: int,
  endBlock: option<int>,
  confirmedBlockThreshold: int,
  chain: ChainMap.Chain.t,
  contracts: array<contract>,
}

type historyFlag = FullHistory | MinHistory
type rollbackFlag = RollbackOnReorg | NoRollback
type historyConfig = {rollbackFlag: rollbackFlag, historyFlag: historyFlag}

let db: Postgres.poolConfig = {
  host: Env.Db.host,
  port: Env.Db.port,
  username: Env.Db.user,
  password: Env.Db.password,
  database: Env.Db.database,
  ssl: Env.Db.ssl,
  // TODO: think how we want to pipe these logs to pino.
  onnotice: ?(Env.userLogLevel == #warn || Env.userLogLevel == #error ? None : Some(_str => ())),
  transform: {undefined: Null},
  max: 2,
}

let getSyncConfig = ({
  initialBlockInterval,
  backoffMultiplicative,
  accelerationAdditive,
  intervalCeiling,
  backoffMillis,
  queryTimeoutMillis,
}) => {
  initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Belt.Option.getWithDefault(
    initialBlockInterval,
  ),
  // After an RPC error, how much to scale back the number of blocks requested at once
  backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Belt.Option.getWithDefault(
    backoffMultiplicative,
  ),
  // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
  accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Belt.Option.getWithDefault(
    accelerationAdditive,
  ),
  // Do not further increase the block interval past this limit
  intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Belt.Option.getWithDefault(
    intervalCeiling,
  ),
  // After an error, how long to wait before retrying
  backoffMillis,
  // How long to wait before cancelling an RPC request
  queryTimeoutMillis,
}

type t = {
  historyConfig: historyConfig,
  /*
  Determines whether to use HypersyncClient Decoder or Viem for parsing events
  Default is hypersync client decoder, configurable in config with:
  ```yaml
  event_decoder: "viem" || "hypersync-client"
  ```
 */
  shouldUseHypersyncClientDecoder: bool,
  isUnorderedMultichainMode: bool,
  chainMap: ChainMap.t<chainConfig>,
}

let make = (
  ~shouldRollbackOnReorg=false,
  ~shouldSaveFullHistory=false,
  ~shouldUseHypersyncClientDecoder=true,
  ~isUnorderedMultichainMode=false,
  ~networks=[],
) => {
  historyConfig: {
    rollbackFlag: shouldRollbackOnReorg ? RollbackOnReorg : NoRollback,
    historyFlag: shouldSaveFullHistory ? FullHistory : MinHistory,
  },
  shouldUseHypersyncClientDecoder: Env.Configurable.shouldUseHypersyncClientDecoder->Belt.Option.getWithDefault(
    shouldUseHypersyncClientDecoder,
  ),
  isUnorderedMultichainMode: Env.Configurable.isUnorderedMultichainMode->Belt.Option.getWithDefault(
    Env.Configurable.unstable__temp_unordered_head_mode->Belt.Option.getWithDefault(
      isUnorderedMultichainMode,
    ),
  ),
  chainMap: networks->Js.Array2.map(n => {
    (n.chain, n)
  })->ChainMap.fromArray->Utils.unwrapResultExn,
}

%%private(let generatedConfigRef = ref(None))

let getConfig = () =>
  switch generatedConfigRef.contents {
  | Some(c) => c
  | None => Js.Exn.raiseError("Config not yet generated")
  }

let setGenerated = (config: t) => {
  if generatedConfigRef.contents !== None {
    Js.Exn.raiseError("Generated config already registered")
  }
  generatedConfigRef := Some(config)
}

let shouldRollbackOnReorg = config =>
  switch config.historyConfig {
  | {rollbackFlag: RollbackOnReorg} => true
  | _ => false
  }

let shouldPruneHistory = config =>
  switch config.historyConfig {
  | {historyFlag: MinHistory} => true
  | _ => false
  }
