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

type codegenChain = {
  id: int,
  startBlock: int,
  endBlock?: int,
  maxReorgDepth: int,
  contracts: array<contract>,
  sources: array<Source.t>,
}

type chain = {
  name: string,
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
  name: string,
  description: option<string>,
  handlers: string,
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

let publicConfigChainSchema = S.schema(s =>
  {
    "id": s.matches(S.int),
    "startBlock": s.matches(S.int),
    "endBlock": s.matches(S.option(S.int)),
  }
)

let publicConfigEcosystemSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(publicConfigChainSchema)),
  }
)

let multichainSchema = S.enum([Ordered, Unordered])

let publicConfigSchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "description": s.matches(S.option(S.string)),
    "handlers": s.matches(S.option(S.string)),
    "multichain": s.matches(S.option(multichainSchema)),
    "fullBatchSize": s.matches(S.option(S.int)),
    "evm": s.matches(S.option(publicConfigEcosystemSchema)),
    "fuel": s.matches(S.option(publicConfigEcosystemSchema)),
    "svm": s.matches(S.option(publicConfigEcosystemSchema)),
  }
)

let fromPublic = (
  publicConfigJson: Js.Json.t,
  ~shouldRollbackOnReorg=true,
  ~shouldSaveFullHistory=false,
  ~codegenChains: array<codegenChain>=[],
  ~enableRawEvents=false,
  ~lowercaseAddresses=false,
  ~shouldUseHypersyncClientDecoder=true,
  ~maxAddrInPartition=5000,
  ~userEntities: array<Internal.entityConfig>=[],
) => {
  // Parse public config
  let publicConfig = try publicConfigJson->S.parseOrThrow(publicConfigSchema) catch {
  | S.Raised(exn) =>
    Js.Exn.raiseError(`Invalid internal.config.ts: ${exn->Utils.prettifyExn->Utils.magic}`)
  }

  // Determine ecosystem from publicConfig
  let (publicEcosystemConfig, ecosystemName) = switch (
    publicConfig["evm"],
    publicConfig["fuel"],
    publicConfig["svm"],
  ) {
  | (Some(ecosystemConfig), None, None) => (ecosystemConfig, Ecosystem.Evm)
  | (None, Some(ecosystemConfig), None) => (ecosystemConfig, Ecosystem.Fuel)
  | (None, None, Some(ecosystemConfig)) => (ecosystemConfig, Ecosystem.Svm)
  | (None, None, None) =>
    Js.Exn.raiseError("Invalid indexer config: No ecosystem configured (evm, fuel, or svm)")
  | _ =>
    Js.Exn.raiseError(
      "Invalid indexer config: Multiple ecosystems are not supported for a single indexer",
    )
  }

  // Validate that lowercase addresses is not used with viem decoder
  if lowercaseAddresses && !shouldUseHypersyncClientDecoder {
    Js.Exn.raiseError(
      "lowercase addresses is not supported when event_decoder is 'viem'. Please set event_decoder to 'hypersync-client' or change address_format to 'checksum'.",
    )
  }

  // Index codegenChains by id for efficient lookup
  let codegenChainById = Js.Dict.empty()
  codegenChains->Array.forEach(codegenChain => {
    codegenChainById->Js.Dict.set(codegenChain.id->Int.toString, codegenChain)
  })

  // Merge codegenChains with names from publicConfig
  let chains =
    publicEcosystemConfig["chains"]
    ->Js.Dict.keys
    ->Js.Array2.map(chainName => {
      let publicChainConfig = publicEcosystemConfig["chains"]->Js.Dict.unsafeGet(chainName)
      let chainId = publicChainConfig["id"]
      let codegenChain = switch codegenChainById->Js.Dict.get(chainId->Int.toString) {
      | Some(c) => c
      | None =>
        Js.Exn.raiseError(`Chain with id ${chainId->Int.toString} not found in codegen chains`)
      }
      {
        name: chainName,
        id: codegenChain.id,
        startBlock: codegenChain.startBlock,
        endBlock: ?codegenChain.endBlock,
        maxReorgDepth: codegenChain.maxReorgDepth,
        contracts: codegenChain.contracts,
        sources: codegenChain.sources,
      }
    })

  let chainMap =
    chains
    ->Js.Array2.map(chain => {
      (ChainMap.Chain.makeUnsafe(~chainId=chain.id), chain)
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

  let ecosystem = switch ecosystemName {
  | Ecosystem.Evm => Evm.ecosystem
  | Ecosystem.Fuel => Fuel.ecosystem
  | Ecosystem.Svm => Svm.ecosystem
  }

  let userEntitiesByName =
    userEntities
    ->Js.Array2.map(entityConfig => {
      (entityConfig.name, entityConfig)
    })
    ->Js.Dict.fromArray

  {
    name: publicConfig["name"],
    description: publicConfig["description"],
    handlers: publicConfig["handlers"]->Option.getWithDefault("src/handlers"),
    shouldRollbackOnReorg,
    shouldSaveFullHistory,
    multichain: publicConfig["multichain"]->Option.getWithDefault(Unordered),
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents,
    ecosystem,
    maxAddrInPartition,
    batchSize: publicConfig["fullBatchSize"]->Option.getWithDefault(5000),
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
