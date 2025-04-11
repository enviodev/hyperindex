type ecosystem = | @as("evm") Evm | @as("fuel") Fuel

type contract = {
  name: string,
  abi: Ethers.abi,
  addresses: array<Address.t>,
  events: array<Internal.eventConfig>,
}

type syncConfigOptions = {
  initialBlockInterval?: int,
  backoffMultiplicative?: float,
  accelerationAdditive?: int,
  intervalCeiling?: int,
  backoffMillis?: int,
  queryTimeoutMillis?: int,
  fallbackStallTimeout?: int,
}

type syncConfig = {
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
  fallbackStallTimeout: int,
}

type chainConfig = {
  startBlock: int,
  endBlock: option<int>,
  confirmedBlockThreshold: int,
  chain: ChainMap.Chain.t,
  contracts: array<contract>,
  sources: array<Source.t>,
}

let shouldPreRegisterDynamicContracts = (chainConfig: chainConfig) => {
  chainConfig.contracts->Array.some(contract => {
    contract.events->Array.some(eventConfig => {
      eventConfig.preRegisterDynamicContracts
    })
  })
}

type historyFlag = FullHistory | MinHistory
type rollbackFlag = RollbackOnReorg | NoRollback
type historyConfig = {rollbackFlag: rollbackFlag, historyFlag: historyFlag}

let getSyncConfig = (
  {
    ?initialBlockInterval,
    ?backoffMultiplicative,
    ?accelerationAdditive,
    ?intervalCeiling,
    ?backoffMillis,
    ?queryTimeoutMillis,
    ?fallbackStallTimeout,
  }: syncConfigOptions,
): syncConfig => {
  let queryTimeoutMillis = queryTimeoutMillis->Option.getOr(20_000)
  {
    initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Option.getOr(
      initialBlockInterval->Option.getOr(10_000),
    ),
    // After an RPC error, how much to scale back the number of blocks requested at once
    backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getOr(
      backoffMultiplicative->Option.getOr(0.8),
    ),
    // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
    accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getOr(
      accelerationAdditive->Option.getOr(500),
    ),
    // Do not further increase the block interval past this limit
    intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getOr(
      intervalCeiling->Option.getOr(10_000),
    ),
    // After an error, how long to wait before retrying
    backoffMillis: backoffMillis->Option.getOr(5000),
    // How long to wait before cancelling an RPC request
    queryTimeoutMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getOr(queryTimeoutMillis / 2),
  }
}

type t = {
  historyConfig: historyConfig,
  isUnorderedMultichainMode: bool,
  chainMap: ChainMap.t<chainConfig>,
  defaultChain: option<chainConfig>,
  ecosystem: ecosystem,
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
  ~ecosystem=Evm,
) => {
  {
    historyConfig: {
      rollbackFlag: shouldRollbackOnReorg ? RollbackOnReorg : NoRollback,
      historyFlag: shouldSaveFullHistory ? FullHistory : MinHistory,
    },
    isUnorderedMultichainMode: Env.Configurable.isUnorderedMultichainMode->Option.getOr(
      Env.Configurable.unstable__temp_unordered_head_mode->Option.getOr(isUnorderedMultichainMode),
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
    ecosystem,
  }
}

let shouldRollbackOnReorg = config =>
  switch config.historyConfig {
  | {rollbackFlag: RollbackOnReorg} => true
  | _ => false
  }

let shouldSaveHistory = (config, ~isInReorgThreshold) =>
  switch config.historyConfig {
  | {rollbackFlag: RollbackOnReorg} if isInReorgThreshold => true
  | {historyFlag: FullHistory} => true
  | _ => false
  }

let shouldPruneHistory = (config, ~isInReorgThreshold) =>
  switch config.historyConfig {
  | {rollbackFlag: RollbackOnReorg, historyFlag: MinHistory} if isInReorgThreshold => true
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
