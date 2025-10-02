open Belt

let getSyncConfig = (
  {
    ?initialBlockInterval,
    ?backoffMultiplicative,
    ?accelerationAdditive,
    ?intervalCeiling,
    ?backoffMillis,
    ?queryTimeoutMillis,
    ?fallbackStallTimeout,
  }: InternalConfig.sourceSyncOptions,
): InternalConfig.sourceSync => {
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
              ~userEntities=Entities.userEntities,
              ~responseLimit=Env.Hasura.responseLimit,
              ~schema=Db.schema,
              ~aggregateEntities=Env.Hasura.aggregateEntities,
            )->Promise.catch(err => {
              Logging.errorWithExn(
                err->Utils.prettifyExn,
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
                err->Utils.prettifyExn,
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
  historyConfig: InternalConfig.historyConfig,
  multichain: InternalConfig.multichain,
  chainMap: ChainMap.t<InternalConfig.chain>,
  defaultChain: option<InternalConfig.chain>,
  ecosystem: InternalConfig.ecosystem,
  enableRawEvents: bool,
  preloadHandlers: bool,
  persistence: Persistence.t,
  addContractNameToContractNameMapping: dict<string>,
  maxAddrInPartition: int,
  registrations: option<EventRegister.registrations>,
  batchSize: int,
  lowercaseAddresses: bool,
}

let make = (
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~isUnorderedMultichainMode=false,
  ~chains: array<InternalConfig.chain>=[],
  ~enableRawEvents=false,
  ~preloadHandlers=false,
  ~persistence=codegenPersistence,
  ~ecosystem=InternalConfig.Evm,
  ~registrations=?,
  ~batchSize=5000,
  ~lowercaseAddresses=false,
  ~shouldUseHypersyncClientDecoder=true,
) => {
  // Validate that lowercase addresses is not used with viem decoder
  if (
    lowercaseAddresses &&
    !shouldUseHypersyncClientDecoder
  ) {
    Js.Exn.raiseError(
      "lowercase addresses is not supported when event_decoder is 'viem'. Please set event_decoder to 'hypersync-client' or change address_format to 'checksum'.",
    )
  }

  let chainMap =
    chains
    ->Js.Array2.map(n => {
      (ChainMap.Chain.makeUnsafe(~chainId=n.id), n)
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
    multichain: if (
      Env.Configurable.isUnorderedMultichainMode->Option.getWithDefault(
        Env.Configurable.unstable__temp_unordered_head_mode->Option.getWithDefault(
          isUnorderedMultichainMode,
        ),
      )
    ) {
      Unordered
    } else {
      Ordered
    },
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents,
    persistence,
    ecosystem,
    addContractNameToContractNameMapping,
    maxAddrInPartition: Env.maxAddrInPartition,
    registrations,
    preloadHandlers,
    batchSize,
    lowercaseAddresses,
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
