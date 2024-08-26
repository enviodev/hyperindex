type contract = {
  name: string,
  abi: Ethers.abi,
  addresses: array<Address.t>,
  events: array<module(Types.Event)>,
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
  isUnorderedMultichainMode: bool,
  chainMap: ChainMap.t<chainConfig>,
  defaultChain: option<chainConfig>,
  events: dict<module(Types.InternalEvent)>,
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
  let events = Js.Dict.empty()
  chains->Js.Array2.forEach(chainConfig => {
    chainConfig.contracts->Js.Array2.forEach(contract => {
      contract.events->Js.Array2.forEach(
        eventMod => {
          let eventMod = eventMod->Types.eventModWithoutArgTypeToInternal
          let module(Event) = eventMod
          events->Js.Dict.set(Event.key, eventMod)
        },
      )
    })
  })
  {
    historyConfig: {
      rollbackFlag: shouldRollbackOnReorg ? RollbackOnReorg : NoRollback,
      historyFlag: shouldSaveFullHistory ? FullHistory : MinHistory,
    },
    isUnorderedMultichainMode: Env.Configurable.isUnorderedMultichainMode->Belt.Option.getWithDefault(
      Env.Configurable.unstable__temp_unordered_head_mode->Belt.Option.getWithDefault(
        isUnorderedMultichainMode,
      ),
    ),
    chainMap: chains
    ->Js.Array2.map(n => {
      (n.chain, n)
    })
    ->ChainMap.fromArrayUnsafe,
    defaultChain: chains->Belt.Array.get(0),
    events,
    enableRawEvents,
    entities: entities->(
      Utils.magic: array<module(Entities.Entity)> => array<module(Entities.InternalEntity)>
    ),
  }
}

%%private(let generatedConfigRef = ref(None))

let getGenerated = () =>
  switch generatedConfigRef.contents {
  | Some(c) => c
  | None => Js.Exn.raiseError("Config not yet generated")
  }

let setGenerated = (config: t) => {
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

let getChain = (config, ~chainId) => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
  config.chainMap->ChainMap.has(chain)
    ? chain
    : Js.Exn.raiseError(
        "No chain with id " ++ chain->ChainMap.Chain.toString ++ " found in config.yaml",
      )
}

let getEventModOrThrow = (config, ~contractName, ~topic0) => {
  let key = `${contractName}_${topic0}`
  switch config.events->Js.Dict.get(key) {
  | Some(event) => event
  | None => Js.Exn.raiseError("No registered event found with key " ++ key)
  }
}
