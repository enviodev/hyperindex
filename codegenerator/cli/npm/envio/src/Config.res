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

type codegenContract = {
  name: string,
  addresses: array<string>,
  events: array<Internal.eventConfig>,
  startBlock: option<int>,
}

type codegenChain = {
  id: int,
  contracts: array<codegenContract>,
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

type contractHandler = {
  name: string,
  handler: option<string>,
}

type t = {
  name: string,
  description: option<string>,
  handlers: string,
  contractHandlers: array<contractHandler>,
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
    "maxReorgDepth": s.matches(S.option(S.int)),
  }
)

let contractConfigSchema = S.schema(s =>
  {
    "abi": s.matches(S.json(~validate=false)),
    "handler": s.matches(S.option(S.string)),
  }
)

let publicConfigEcosystemSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(publicConfigChainSchema)),
    "contracts": s.matches(S.option(S.dict(contractConfigSchema))),
  }
)

type addressFormat = | @as("lowercase") Lowercase | @as("checksum") Checksum
type decoder = | @as("hypersync") Hypersync | @as("viem") Viem

let publicConfigEvmSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(publicConfigChainSchema)),
    "contracts": s.matches(S.option(S.dict(contractConfigSchema))),
    "addressFormat": s.matches(S.option(S.enum([Lowercase, Checksum]))),
    "eventDecoder": s.matches(S.option(S.enum([Hypersync, Viem]))),
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
    "rollbackOnReorg": s.matches(S.option(S.bool)),
    "saveFullHistory": s.matches(S.option(S.bool)),
    "rawEvents": s.matches(S.option(S.bool)),
    "evm": s.matches(S.option(publicConfigEvmSchema)),
    "fuel": s.matches(S.option(publicConfigEcosystemSchema)),
    "svm": s.matches(S.option(publicConfigEcosystemSchema)),
  }
)

let fromPublic = (
  publicConfigJson: Js.Json.t,
  ~codegenChains: array<codegenChain>=[],
  ~maxAddrInPartition=5000,
  ~userEntities: array<Internal.entityConfig>=[],
) => {
  // Parse public config
  let publicConfig = try publicConfigJson->S.parseOrThrow(publicConfigSchema) catch {
  | S.Raised(exn) =>
    Js.Exn.raiseError(`Invalid internal.config.ts: ${exn->Utils.prettifyExn->Utils.magic}`)
  }

  // Determine ecosystem from publicConfig (extract just chains for unified handling)
  let (publicChainsConfig, ecosystemName) = switch (
    publicConfig["evm"],
    publicConfig["fuel"],
    publicConfig["svm"],
  ) {
  | (Some(ecosystemConfig), None, None) => (ecosystemConfig["chains"], Ecosystem.Evm)
  | (None, Some(ecosystemConfig), None) => (ecosystemConfig["chains"], Ecosystem.Fuel)
  | (None, None, Some(ecosystemConfig)) => (ecosystemConfig["chains"], Ecosystem.Svm)
  | (None, None, None) =>
    Js.Exn.raiseError("Invalid indexer config: No ecosystem configured (evm, fuel, or svm)")
  | _ =>
    Js.Exn.raiseError(
      "Invalid indexer config: Multiple ecosystems are not supported for a single indexer",
    )
  }

  // Extract EVM-specific options with defaults
  let (lowercaseAddresses, shouldUseHypersyncClientDecoder) = switch publicConfig["evm"] {
  | Some(evm) => (
      evm["addressFormat"]->Option.getWithDefault(Checksum) == Lowercase,
      evm["eventDecoder"]->Option.getWithDefault(Hypersync) == Hypersync,
    )
  | None => (false, true)
  }

  // Validate that lowercase addresses is not used with viem decoder
  if lowercaseAddresses && !shouldUseHypersyncClientDecoder {
    Js.Exn.raiseError(
      "lowercase addresses is not supported when event_decoder is 'viem'. Please set event_decoder to 'hypersync-client' or change address_format to 'checksum'.",
    )
  }

  // Parse ABIs from public config
  let publicContractsConfig = switch (ecosystemName, publicConfig["evm"], publicConfig["fuel"]) {
  | (Ecosystem.Evm, Some(evm), _) => evm["contracts"]
  | (Ecosystem.Fuel, _, Some(fuel)) => fuel["contracts"]
  | _ => None
  }

  let contractsWithAbis = switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Js.Dict.entries
    ->Js.Array2.map(((contractName, contractConfig)) => {
      let abi = contractConfig["abi"]->(Utils.magic: Js.Json.t => EvmTypes.Abi.t)
      (contractName, abi)
    })
    ->Js.Dict.fromArray
  | None => Js.Dict.empty()
  }

  // Index codegenChains by id for efficient lookup
  let codegenChainById = Js.Dict.empty()
  codegenChains->Array.forEach(codegenChain => {
    codegenChainById->Js.Dict.set(codegenChain.id->Int.toString, codegenChain)
  })

  // Create a dictionary to store merged contracts with ABIs by chain id
  let contractsByChainId: Js.Dict.t<array<contract>> = Js.Dict.empty()
  codegenChains->Array.forEach(codegenChain => {
    let mergedContracts = codegenChain.contracts->Array.map(codegenContract => {
      switch contractsWithAbis->Js.Dict.get(codegenContract.name) {
      | Some(abi) =>
        // Parse addresses based on ecosystem and address format
        let parsedAddresses = codegenContract.addresses->Array.map(
          addressString => {
            switch ecosystemName {
            | Ecosystem.Evm =>
              if lowercaseAddresses {
                addressString->Address.Evm.fromStringLowercaseOrThrow
              } else {
                addressString->Address.Evm.fromStringOrThrow
              }
            | Ecosystem.Fuel | Ecosystem.Svm => addressString->Address.unsafeFromString
            }
          },
        )
        // Convert codegenContract to contract by adding abi
        {
          name: codegenContract.name,
          abi,
          addresses: parsedAddresses,
          events: codegenContract.events,
          startBlock: codegenContract.startBlock,
        }
      | None =>
        Js.Exn.raiseError(
          `Contract "${codegenContract.name}" is missing ABI in public config (internal.config.ts)`,
        )
      }
    })
    contractsByChainId->Js.Dict.set(codegenChain.id->Int.toString, mergedContracts)
  })

  // Merge codegenChains with names from publicConfig
  let chains =
    publicChainsConfig
    ->Js.Dict.keys
    ->Js.Array2.map(chainName => {
      let publicChainConfig = publicChainsConfig->Js.Dict.unsafeGet(chainName)
      let chainId = publicChainConfig["id"]
      let codegenChain = switch codegenChainById->Js.Dict.get(chainId->Int.toString) {
      | Some(c) => c
      | None =>
        Js.Exn.raiseError(`Chain with id ${chainId->Int.toString} not found in codegen chains`)
      }
      let mergedContracts = switch contractsByChainId->Js.Dict.get(chainId->Int.toString) {
      | Some(contracts) => contracts
      | None =>
        Js.Exn.raiseError(
          `Contracts for chain with id ${chainId->Int.toString} not found in merged contracts`,
        )
      }
      {
        name: chainName,
        id: codegenChain.id,
        startBlock: publicChainConfig["startBlock"],
        endBlock: ?publicChainConfig["endBlock"],
        maxReorgDepth: switch ecosystemName {
        | Ecosystem.Evm => publicChainConfig["maxReorgDepth"]->Option.getWithDefault(200)
        // Fuel doesn't have reorgs, SVM reorg handling is not supported
        | Ecosystem.Fuel | Ecosystem.Svm => 0
        },
        contracts: mergedContracts,
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

  // Extract contract handlers from the public config
  let contractHandlers = switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Js.Dict.entries
    ->Js.Array2.map(((contractName, contractConfig)) => {
      {
        name: contractName,
        handler: contractConfig["handler"],
      }
    })
  | None => []
  }

  {
    name: publicConfig["name"],
    description: publicConfig["description"],
    handlers: publicConfig["handlers"]->Option.getWithDefault("src/handlers"),
    contractHandlers,
    shouldRollbackOnReorg: publicConfig["rollbackOnReorg"]->Option.getWithDefault(true),
    shouldSaveFullHistory: publicConfig["saveFullHistory"]->Option.getWithDefault(false),
    multichain: publicConfig["multichain"]->Option.getWithDefault(Unordered),
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents: publicConfig["rawEvents"]->Option.getWithDefault(false),
    ecosystem,
    maxAddrInPartition,
    batchSize: publicConfig["fullBatchSize"]->Option.getWithDefault(5000),
    lowercaseAddresses,
    addContractNameToContractNameMapping,
    userEntitiesByName,
  }
}

// Handler loading params - extracted from publicConfig without building full config
// Used to load handlers BEFORE creating the full config (so event registrations are captured)
type handlerLoadingParams = {
  ecosystem: Ecosystem.t,
  multichain: multichain,
  handlers: string,
  contractHandlers: array<contractHandler>,
}

let getHandlerLoadingParams = (publicConfigJson: Js.Json.t) => {
  let publicConfig = try publicConfigJson->S.parseOrThrow(publicConfigSchema) catch {
  | S.Raised(exn) =>
    Js.Exn.raiseError(`Invalid internal.config.ts: ${exn->Utils.prettifyExn->Utils.magic}`)
  }

  // Determine ecosystem
  let (ecosystemName, publicContractsConfig) = switch (
    publicConfig["evm"],
    publicConfig["fuel"],
    publicConfig["svm"],
  ) {
  | (Some(ecosystemConfig), None, None) => (Ecosystem.Evm, ecosystemConfig["contracts"])
  | (None, Some(ecosystemConfig), None) => (Ecosystem.Fuel, ecosystemConfig["contracts"])
  | (None, None, Some(ecosystemConfig)) => (Ecosystem.Svm, ecosystemConfig["contracts"])
  | (None, None, None) =>
    Js.Exn.raiseError("Invalid indexer config: No ecosystem configured (evm, fuel, or svm)")
  | _ =>
    Js.Exn.raiseError(
      "Invalid indexer config: Multiple ecosystems are not supported for a single indexer",
    )
  }

  let ecosystem = switch ecosystemName {
  | Ecosystem.Evm => Evm.ecosystem
  | Ecosystem.Fuel => Fuel.ecosystem
  | Ecosystem.Svm => Svm.ecosystem
  }

  let contractHandlers = switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Js.Dict.entries
    ->Js.Array2.map(((contractName, contractConfig)) => {
      {
        name: contractName,
        handler: contractConfig["handler"],
      }
    })
  | None => []
  }

  {
    ecosystem,
    multichain: publicConfig["multichain"]->Option.getWithDefault(Unordered),
    handlers: publicConfig["handlers"]->Option.getWithDefault("src/handlers"),
    contractHandlers,
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
