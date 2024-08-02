type contract = {
  name: string,
  abi: Ethers.abi,
  addresses: array<Ethers.ethAddress>,
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

let hyperSyncConfigSchema: S.t<hyperSyncConfig> = S.object(s => {
  endpointUrl: s.field("endpointUrl", S.string),
})

type hyperFuelConfig = {endpointUrl: string}

let hyperFuelConfigSchema: S.t<hyperFuelConfig> = S.object(s => {
  endpointUrl: s.field("endpointUrl", S.string),
})

type rpcConfig = {
  provider: Ethers.JsonRpcProvider.t,
  syncConfig: syncConfig,
}

type syncSource = HyperSync(hyperSyncConfig) | HyperFuel(hyperFuelConfig) | Rpc(rpcConfig)

let syncSourceSchema = S.union([
  S.object(s => {
    s.tag("kind", "HyperSync")
    HyperSync(s.field("payload", hyperSyncConfigSchema))
  }),
  S.object(s => {
    s.tag("kind", "HyperFuel")
    HyperFuel(s.field("payload", hyperFuelConfigSchema))
  }),
  S.object(s => {
    s.tag("kind", "Rpc")
    //Do not share users private rpc details
    Rpc(Js.Nullable.Null->Utils.magic)
  }),
])

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
}

type historyFlag = | @as(true) FullHistory | @as(false) MinHistory
type rollbackFlag = | @as(true) RollbackOnReorg | @as(false) NoRollback
type historyConfig = {rollbackFlag: rollbackFlag, historyFlag: historyFlag}
let historyConfigSchema: S.t<historyConfig> = S.object(s => {
  rollbackFlag: s.field("rollbackFlag", S.bool->Utils.magic),
  historyFlag: s.field("historyFlag", S.bool->Utils.magic),
})

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
  defaultChain: option<chainConfig>,
  events: dict<module(Types.InternalEvent)>,
  allEventSignatures: array<string>,
  enableRawEvents: bool,
  entities: array<module(Entities.InternalEntity)>,
}

let make = (
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~shouldUseHypersyncClientDecoder=true,
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
    shouldUseHypersyncClientDecoder: Env.Configurable.shouldUseHypersyncClientDecoder->Belt.Option.getWithDefault(
      shouldUseHypersyncClientDecoder,
    ),
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
    allEventSignatures: Abis.EventSignatures.all,
    events,
    enableRawEvents,
    entities: entities->(Utils.magic: array<module(Entities.Entity)> => array<module(Entities.InternalEntity)>),
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
