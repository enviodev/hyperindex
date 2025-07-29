open Belt

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
  let queryTimeoutMillis = queryTimeoutMillis->Option.getWithDefault(20_000)
  {
    initialBlockInterval: Env.Configurable.SyncConfig.initialBlockInterval->Option.getWithDefault(
      initialBlockInterval->Option.getWithDefault(10_000),
    ),
    // After an RPC error, how much to scale back the number of blocks requested at once
    backoffMultiplicative: Env.Configurable.SyncConfig.backoffMultiplicative->Option.getWithDefault(
      backoffMultiplicative->Option.getWithDefault(0.8),
    ),
    // Without RPC errors or timeouts, how much to increase the number of blocks requested by for the next batch
    accelerationAdditive: Env.Configurable.SyncConfig.accelerationAdditive->Option.getWithDefault(
      accelerationAdditive->Option.getWithDefault(500),
    ),
    // Do not further increase the block interval past this limit
    intervalCeiling: Env.Configurable.SyncConfig.intervalCeiling->Option.getWithDefault(
      intervalCeiling->Option.getWithDefault(10_000),
    ),
    // After an error, how long to wait before retrying
    backoffMillis: backoffMillis->Option.getWithDefault(5000),
    // How long to wait before cancelling an RPC request
    queryTimeoutMillis,
    fallbackStallTimeout: fallbackStallTimeout->Option.getWithDefault(queryTimeoutMillis / 2),
  }
}

let storagePgSchema = Env.Db.publicSchema
let codegenPersistence = Persistence.make(
  ~userEntities=Entities.userEntities,
  ~staticTables=Db.allStaticTables,
  ~dcRegistryEntityConfig=module(
    TablesStatic.DynamicContractRegistry
  )->Entities.entityModToInternal,
  ~allEnums=Enums.allEnums,
  ~storage=PgStorage.make(
    ~sql=Db.sql,
    ~pgSchema=storagePgSchema,
    ~pgHost=Env.Db.host,
    ~pgUser=Env.Db.user,
    ~pgPort=Env.Db.port,
    ~pgDatabase=Env.Db.database,
    ~pgPassword=Env.Db.password,
    ~onInitialize=?{
      if Env.Hasura.enabled {
        Some(
          () => {
            Hasura.trackDatabase(
              ~endpoint=Env.Hasura.graphqlEndpoint,
              ~auth={
                role: Env.Hasura.role,
                secret: Env.Hasura.secret,
              },
              ~pgSchema=storagePgSchema,
              ~allStaticTables=Db.allStaticTables,
              ~allEntityTables=Db.allEntityTables,
              ~responseLimit=Env.Hasura.responseLimit,
              ~schema=Db.schema,
              ~aggregateEntities=Env.Hasura.aggregateEntities,
            )->Promise.catch(err => {
              Logging.errorWithExn(
                err->Internal.prettifyExn,
                `EE803: Error tracking tables`,
              )->Promise.resolve
            })
          },
        )
      } else {
        None
      }
    },
    ~onNewTables=?{
      if Env.Hasura.enabled {
        Some(
          (~tableNames) => {
            Hasura.trackTables(
              ~endpoint=Env.Hasura.graphqlEndpoint,
              ~auth={
                role: Env.Hasura.role,
                secret: Env.Hasura.secret,
              },
              ~pgSchema=storagePgSchema,
              ~tableNames,
            )->Promise.catch(err => {
              Logging.errorWithExn(
                err->Internal.prettifyExn,
                `EE804: Error tracking new tables`,
              )->Promise.resolve
           })
          },
        )
      } else {
        None
      }
    },
  ),
)

type t = {
  historyConfig: historyConfig,
  isUnorderedMultichainMode: bool,
  chainMap: ChainMap.t<chainConfig>,
  defaultChain: option<chainConfig>,
  ecosystem: ecosystem,
  enableRawEvents: bool,
  persistence: Persistence.t,
  addContractNameToContractNameMapping: dict<string>,
}

let make = (
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~isUnorderedMultichainMode=false,
  ~chains=[],
  ~enableRawEvents=false,
  ~persistence=codegenPersistence,
  ~ecosystem=Evm,
) => {
  let chainMap =
    chains
    ->Js.Array2.map(n => {
      (n.chain, n)
    })
    ->ChainMap.fromArrayUnsafe

  // Build the contract name mapping for efficient lookup
  let addContractNameToContractNameMapping = Js.Dict.empty()
  chains->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      let addKey = "add" ++ contract.name->Utils.String.capitalize
      addContractNameToContractNameMapping->Js.Dict.set(addKey, contract.name)
    })
  })

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
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents,
    persistence,
    ecosystem,
    addContractNameToContractNameMapping,
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
