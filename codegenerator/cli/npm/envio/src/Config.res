open Belt

type sourceSyncOptions = {
  initialBlockInterval?: int,
  backoffMultiplicative?: float,
  accelerationAdditive?: int,
  intervalCeiling?: int,
  backoffMillis?: int,
  queryTimeoutMillis?: int,
  fallbackStallTimeout?: int,
}

type contract = {
  name: string,
  abi: EvmTypes.Abi.t,
  addresses: array<Address.t>,
  events: array<Internal.eventConfig>,
  startBlock: option<int>,
}

type chain = {
  id: int,
  startBlock: int,
  endBlock?: int,
  maxReorgDepth: int,
  contracts: array<contract>,
  sources: array<Source.t>,
}

type sourceSync = {
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
  fallbackStallTimeout: int,
}

type multichain = | @as("ordered") Ordered | @as("unordered") Unordered

type t = {
  shouldRollbackOnReorg: bool,
  shouldSaveFullHistory: bool,
  multichain: multichain,
  chainMap: ChainMap.t<chain>,
  defaultChain: option<chain>,
  ecosystem: Ecosystem.t,
  enableRawEvents: bool,
  maxAddrInPartition: int,
  batchSize: int,
  lowercaseAddresses: bool,
  addContractNameToContractNameMapping: dict<string>,
  userEntitiesByName: dict<Internal.entityConfig>,
}

let make = (
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~chains: array<chain>=[],
  ~enableRawEvents=false,
  ~ecosystem: Ecosystem.name=Ecosystem.Evm,
  ~batchSize=5000,
  ~lowercaseAddresses=false,
  ~multichain=Unordered,
  ~shouldUseHypersyncClientDecoder=true,
  ~maxAddrInPartition=5000,
  ~userEntities: array<Internal.entityConfig>=[],
) => {
  // Validate that lowercase addresses is not used with viem decoder
  if lowercaseAddresses && !shouldUseHypersyncClientDecoder {
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

  let ecosystem = Ecosystem.fromName(ecosystem)

  let userEntitiesByName =
    userEntities
    ->Js.Array2.map(entityConfig => {
      (entityConfig.name, entityConfig)
    })
    ->Js.Dict.fromArray

  {
    shouldRollbackOnReorg,
    shouldSaveFullHistory,
    multichain,
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents,
    ecosystem,
    maxAddrInPartition,
    batchSize,
    lowercaseAddresses,
    addContractNameToContractNameMapping,
    userEntitiesByName,
  }
}

let shouldSaveHistory = (config, ~isInReorgThreshold) =>
  config.shouldSaveFullHistory || (config.shouldRollbackOnReorg && isInReorgThreshold)

let shouldPruneHistory = (config, ~isInReorgThreshold) =>
  !config.shouldSaveFullHistory && (config.shouldRollbackOnReorg && isInReorgThreshold)

let getChain = (config, ~chainId) => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
  config.chainMap->ChainMap.has(chain)
    ? chain
    : Js.Exn.raiseError(
        "No chain with id " ++ chain->ChainMap.Chain.toString ++ " found in config.yaml",
      )
}
