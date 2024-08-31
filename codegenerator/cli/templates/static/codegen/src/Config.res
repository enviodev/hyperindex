open Belt
type contract = {
  name: string,
  abi: Ethers.abi,
  addresses: array<Address.t>,
  events: array<module(Types.Event)>,
  sighashes: array<string>,
}

type syncConfig = {
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
}

type hyperSyncConfig = {endpointUrl: string}
type hyperFuelConfig = {endpointUrl: string}
type rpcConfig = {
  provider: Ethers.JsonRpcProvider.t,
  syncConfig: syncConfig,
}

type syncSource = HyperSync(hyperSyncConfig) | HyperFuel(hyperFuelConfig) | Rpc(rpcConfig)

let usesHyperSync = syncSource =>
  switch syncSource {
  | HyperSync(_) | HyperFuel(_) => true
  | Rpc(_) => false
  }

type chainConfig = {
  syncSource: syncSource,
  startBlock: int,
  endBlock: option<int>,
  confirmedBlockThreshold: int,
  chain: ChainMap.Chain.t,
  contracts: array<contract>,
  chainWorker: module(ChainWorker.S),
}

type historyFlag = FullHistory | MinHistory
type rollbackFlag = RollbackOnReorg | NoRollback
type historyConfig = {rollbackFlag: rollbackFlag, historyFlag: historyFlag}

let getSyncConfig = ({
  initialBlockInterval,
  backoffMultiplicative,
  accelerationAdditive,
  intervalCeiling,
  backoffMillis,
  queryTimeoutMillis,
}) => {
  initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Option.getWithDefault(
    initialBlockInterval,
  ),
  // After an RPC error, how much to scale back the number of blocks requested at once
  backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getWithDefault(
    backoffMultiplicative,
  ),
  // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
  accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getWithDefault(
    accelerationAdditive,
  ),
  // Do not further increase the block interval past this limit
  intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getWithDefault(
    intervalCeiling,
  ),
  // After an error, how long to wait before retrying
  backoffMillis,
  // How long to wait before cancelling an RPC request
  queryTimeoutMillis,
}

type t = {
  historyConfig: historyConfig,
  isUnorderedMultichainMode: bool,
  chainMap: ChainMap.t<chainConfig>,
  defaultChain: option<chainConfig>,
  enableRawEvents: bool,
  entities: array<module(Entities.InternalEntity)>,
}

let make = (
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~isUnorderedMultichainMode=false,
  ~chains=[],
  ~enableRawEvents=false,
  ~entities=[],
) => {
  {
    historyConfig: {
      rollbackFlag: shouldRollbackOnReorg ? RollbackOnReorg : NoRollback,
      historyFlag: shouldSaveFullHistory ? FullHistory : MinHistory,
    },
    isUnorderedMultichainMode: Env.Configurable.isUnorderedMultichainMode->Option.getWithDefault(
      Env.Configurable.unstable__temp_unordered_head_mode->Option.getWithDefault(
        isUnorderedMultichainMode,
      ),
    ),
    chainMap: chains
    ->Js.Array2.map(n => {
      (n.chain, n)
    })
    ->ChainMap.fromArrayUnsafe,
    defaultChain: chains->Array.get(0),
    enableRawEvents,
    entities: entities->(
      Utils.magic: array<module(Entities.Entity)> => array<module(Entities.InternalEntity)>
    ),
  }
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

let getChain = (config, ~chainId) => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
  config.chainMap->ChainMap.has(chain)
    ? chain
    : Js.Exn.raiseError(
        "No chain with id " ++ chain->ChainMap.Chain.toString ++ " found in config.yaml",
      )
}
