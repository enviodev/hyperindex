open Belt

type sourceSyncOptions = {
  initialBlockInterval?: int,
  backoffMultiplicative?: float,
  accelerationAdditive?: int,
  intervalCeiling?: int,
  backoffMillis?: int,
  queryTimeoutMillis?: int,
  fallbackStallTimeout?: int,
  pollingInterval?: int,
}

type contract = {
  name: string,
  abi: EvmTypes.Abi.t,
  addresses: array<Address.t>,
  events: array<Internal.eventConfig>,
  startBlock: option<int>,
  // EVM-specific: event sighashes for HyperSync queries
  eventSignatures: array<string>,
}

type codegenContract = {
  name: string,
  addresses: array<string>,
  events: array<Internal.eventConfig>,
  startBlock: option<int>,
}

// Source config is now parsed from internal.config.json and sources are created lazily
type codegenChain = {
  id: int,
  contracts: array<codegenContract>,
}

// Source config parsed from internal.config.json - sources are created lazily in ChainFetcher
type evmRpcConfig = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig: option<sourceSyncOptions>,
  ws: option<string>,
}

type sourceConfig =
  | EvmSourceConfig({hypersync: option<string>, rpcs: array<evmRpcConfig>})
  | FuelSourceConfig({hypersync: string})
  | SvmSourceConfig({rpc: string})
  // For tests: pass custom sources directly
  | CustomSources(array<Source.t>)

type chain = {
  name: string,
  id: int,
  startBlock: int,
  endBlock?: int,
  maxReorgDepth: int,
  contracts: array<contract>,
  sourceConfig: sourceConfig,
}

type sourceSync = {
  initialBlockInterval: int,
  backoffMultiplicative: float,
  accelerationAdditive: int,
  intervalCeiling: int,
  backoffMillis: int,
  queryTimeoutMillis: int,
  fallbackStallTimeout: int,
  pollingInterval: int,
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
  userEntities: array<Internal.entityConfig>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Table.enumConfig<Table.enum>>,
}

module DynamicContractRegistry = {
  let name = "dynamic_contract_registry"
  let index = -1

  let makeId = (~chainId, ~contractAddress) => {
    chainId->Belt.Int.toString ++ "-" ++ contractAddress->Address.toString
  }

  @genType
  type t = {
    id: string,
    @as("chain_id") chainId: int,
    @as("registering_event_block_number") registeringEventBlockNumber: int,
    @as("registering_event_log_index") registeringEventLogIndex: int,
    @as("registering_event_block_timestamp") registeringEventBlockTimestamp: int,
    @as("registering_event_contract_name") registeringEventContractName: string,
    @as("registering_event_name") registeringEventName: string,
    @as("registering_event_src_address") registeringEventSrcAddress: Address.t,
    @as("contract_address") contractAddress: Address.t,
    @as("contract_name") contractName: string,
  }

  let schema = S.schema(s => {
    id: s.matches(S.string),
    chainId: s.matches(S.int),
    registeringEventBlockNumber: s.matches(S.int),
    registeringEventLogIndex: s.matches(S.int),
    registeringEventContractName: s.matches(S.string),
    registeringEventName: s.matches(S.string),
    registeringEventSrcAddress: s.matches(Address.schema),
    registeringEventBlockTimestamp: s.matches(S.int),
    contractAddress: s.matches(Address.schema),
    contractName: s.matches(S.string),
  })

  let rowsSchema = S.array(schema)

  let table = Table.mkTable(
    name,
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("chain_id", Int32, ~fieldSchema=S.int),
      Table.mkField("registering_event_block_number", Int32, ~fieldSchema=S.int),
      Table.mkField("registering_event_log_index", Int32, ~fieldSchema=S.int),
      Table.mkField("registering_event_block_timestamp", Int32, ~fieldSchema=S.int),
      Table.mkField("registering_event_contract_name", String, ~fieldSchema=S.string),
      Table.mkField("registering_event_name", String, ~fieldSchema=S.string),
      Table.mkField("registering_event_src_address", String, ~fieldSchema=Address.schema),
      Table.mkField("contract_address", String, ~fieldSchema=Address.schema),
      Table.mkField("contract_name", String, ~fieldSchema=S.string),
    ],
  )

  external castToInternal: t => Internal.entity = "%identity"

  let entityConfig = {
    name,
    index,
    schema,
    rowsSchema,
    table,
  }->Internal.fromGenericEntityConfig
}

// Types for parsing source config from internal.config.json
type rpcSourceFor = | @as("sync") Sync | @as("fallback") Fallback | @as("live") Live

let rpcSourceForSchema = S.enum([Sync, Fallback, Live])

let rpcConfigSchema = S.schema(s =>
  {
    "url": s.matches(S.string),
    "for": s.matches(rpcSourceForSchema),
    "ws": s.matches(S.option(S.string)),
    "initialBlockInterval": s.matches(S.option(S.int)),
    "backoffMultiplicative": s.matches(S.option(S.float)),
    "accelerationAdditive": s.matches(S.option(S.int)),
    "intervalCeiling": s.matches(S.option(S.int)),
    "backoffMillis": s.matches(S.option(S.int)),
    "fallbackStallTimeout": s.matches(S.option(S.int)),
    "queryTimeoutMillis": s.matches(S.option(S.int)),
    "pollingInterval": s.matches(S.option(S.int)),
  }
)

let publicConfigChainSchema = S.schema(s =>
  {
    "id": s.matches(S.int),
    "startBlock": s.matches(S.int),
    "endBlock": s.matches(S.option(S.int)),
    "maxReorgDepth": s.matches(S.option(S.int)),
    // EVM/Fuel source config (hypersync for EVM, hyperfuel for Fuel)
    "hypersync": s.matches(S.option(S.string)),
    "rpcs": s.matches(S.option(S.array(rpcConfigSchema))),
    // SVM source config
    "rpc": s.matches(S.option(S.string)),
  }
)

let contractEventItemSchema = S.schema(s =>
  {
    "event": s.matches(S.string),
  }
)

let contractConfigSchema = S.schema(s =>
  {
    "abi": s.matches(S.json(~validate=false)),
    "handler": s.matches(S.option(S.string)),
    // EVM-specific: event signatures for HyperSync queries
    "events": s.matches(S.option(S.array(contractEventItemSchema))),
  }
)

let publicConfigEcosystemSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(publicConfigChainSchema)),
    "contracts": s.matches(S.option(S.dict(contractConfigSchema))),
  }
)

type addressFormat = | @as("lowercase") Lowercase | @as("checksum") Checksum

let publicConfigEvmSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(publicConfigChainSchema)),
    "contracts": s.matches(S.option(S.dict(contractConfigSchema))),
    "addressFormat": s.matches(S.option(S.enum([Lowercase, Checksum]))),
  }
)

let multichainSchema = S.enum([Ordered, Unordered])

let compositeIndexFieldSchema = S.schema(s =>
  {
    "fieldName": s.matches(S.string),
    "direction": s.matches(S.string),
  }
)

let derivedFieldSchema = S.schema(s =>
  {
    "fieldName": s.matches(S.string),
    "derivedFromEntity": s.matches(S.string),
    "derivedFromField": s.matches(S.string),
  }
)

let propertySchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "type": s.matches(S.string),
    "isNullable": s.matches(S.option(S.bool)),
    "isArray": s.matches(S.option(S.bool)),
    "isIndex": s.matches(S.option(S.bool)),
    "linkedEntity": s.matches(S.option(S.string)),
    "enum": s.matches(S.option(S.string)),
    "entity": s.matches(S.option(S.string)),
    "precision": s.matches(S.option(S.int)),
    "scale": s.matches(S.option(S.int)),
  }
)

let entityJsonSchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "properties": s.matches(S.array(propertySchema)),
    "derivedFields": s.matches(S.option(S.array(derivedFieldSchema))),
    "compositeIndices": s.matches(S.option(S.array(S.array(compositeIndexFieldSchema)))),
  }
)

let getFieldTypeAndSchema = (
  prop,
  ~enumConfigsByName: dict<Table.enumConfig<Table.enum>>,
) => {
  let typ = prop["type"]
  let isNullable = prop["isNullable"]->Option.getWithDefault(false)
  let isArray = prop["isArray"]->Option.getWithDefault(false)
  let isIndex = prop["isIndex"]->Option.getWithDefault(false)

  let (fieldType, baseSchema) = switch typ {
  | "string" => (Table.String, S.string->S.toUnknown)
  | "boolean" => (Table.Boolean, S.bool->S.toUnknown)
  | "int" => (Table.Int32, S.int->S.toUnknown)
  | "bigint" => (Table.BigInt({precision: ?prop["precision"]}), BigInt.schema->S.toUnknown)
  | "bigdecimal" => (
      Table.BigDecimal({
        config: ?prop["precision"]->Option.map(p => (p, prop["scale"]->Option.getWithDefault(0))),
      }),
      BigDecimal.schema->S.toUnknown,
    )
  | "float" => (Table.Number, S.float->S.toUnknown)
  | "serial" => (Table.Serial, S.int->S.toUnknown)
  | "json" => (Table.Json, S.json(~validate=false)->S.toUnknown)
  | "date" => (Table.Date, Utils.Schema.dbDate->S.toUnknown)
  | "enum" => {
      let enumName = prop["enum"]->Option.getExn
      let enumConfig =
        enumConfigsByName
        ->Js.Dict.get(enumName)
        ->Option.getExn
      (Table.Enum({config: enumConfig}), enumConfig.schema->S.toUnknown)
    }
  | "entity" => {
      let entityName = prop["entity"]->Option.getExn
      (Table.Entity({name: entityName}), S.string->S.toUnknown)
    }
  | other =>
    Js.Exn.raiseError(
      `Unknown field type "${other}" in entity config. ` ++
      "Valid types: string, boolean, int, bigint, bigdecimal, float, serial, json, date, enum, entity",
    )
  }

  let fieldSchema = if isArray {S.array(baseSchema)->S.toUnknown} else {baseSchema}
  let fieldSchema = if isNullable {S.null(fieldSchema)->S.toUnknown} else {fieldSchema}

  (fieldType, fieldSchema, isNullable, isArray, isIndex)
}

let parseEnumsFromJson = (enumsJson: dict<array<string>>): array<Table.enumConfig<Table.enum>> => {
  enumsJson
  ->Js.Dict.entries
  ->Array.map(((name, variants)) =>
    Table.makeEnumConfig(~name, ~variants)->Table.fromGenericEnumConfig
  )
}

let parseEntitiesFromJson = (
  entitiesJson: array<'entityJson>,
  ~enumConfigsByName: dict<Table.enumConfig<Table.enum>>,
): array<Internal.entityConfig> => {
  entitiesJson->Array.mapWithIndex((index, entityJson) => {
    let entityName = entityJson["name"]

    let fields: array<Table.fieldOrDerived> =
      entityJson["properties"]->Array.map(prop => {
        let (fieldType, fieldSchema, isNullable, isArray, isIndex) =
          getFieldTypeAndSchema(prop, ~enumConfigsByName)
        Table.mkField(
          prop["name"],
          fieldType,
          ~fieldSchema,
          ~isPrimaryKey=prop["name"] === "id",
          ~isNullable,
          ~isArray,
          ~isIndex,
          ~linkedEntity=?prop["linkedEntity"],
        )
      })

    let derivedFields: array<Table.fieldOrDerived> =
      entityJson["derivedFields"]
      ->Option.getWithDefault([])
      ->Array.map(df =>
        Table.mkDerivedFromField(
          df["fieldName"],
          ~derivedFromEntity=df["derivedFromEntity"],
          ~derivedFromField=df["derivedFromField"],
        )
      )

    let compositeIndices =
      entityJson["compositeIndices"]
      ->Option.getWithDefault([])
      ->Array.map(ci =>
        ci->Array.map(f => {
          Table.fieldName: f["fieldName"],
          direction: f["direction"] == "Asc" ? Table.Asc : Table.Desc,
        })
      )

    let table = Table.mkTable(
      entityName,
      ~fields=Array.concat(fields, derivedFields),
      ~compositeIndices,
    )

    // Build schema dynamically from properties
    // Use db field names (with _id suffix for linked entities) as schema locations
    // to match the database column names used in Table.toSqlParams
    let schema = S.schema(s => {
      let dict = Js.Dict.empty()
      entityJson["properties"]->Array.forEach(prop => {
        let (_, fieldSchema, _, _, _) = getFieldTypeAndSchema(prop, ~enumConfigsByName)
        let dbFieldName = switch prop["linkedEntity"] {
        | Some(_) => prop["name"] ++ "_id"
        | None => prop["name"]
        }
        dict->Js.Dict.set(dbFieldName, s.matches(fieldSchema))
      })
      dict
    })

    {
      Internal.name: entityName,
      index,
      schema: schema->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.entity>),
      rowsSchema: S.array(schema)->(Utils.magic: S.t<array<dict<unknown>>> => S.t<array<Internal.entity>>),
      table,
    }->Internal.fromGenericEntityConfig
  })
}

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
    "enums": s.matches(S.option(S.dict(S.array(S.string)))),
    "entities": s.matches(S.option(S.array(entityJsonSchema))),
  }
)

let fromPublic = (
  publicConfigJson: Js.Json.t,
  ~codegenChains: array<codegenChain>=[],
  ~maxAddrInPartition=5000,
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
  let lowercaseAddresses = switch publicConfig["evm"] {
  | Some(evm) => evm["addressFormat"]->Option.getWithDefault(Checksum) == Lowercase
  | None => false
  }

  // Parse ABIs from public config
  let publicContractsConfig = switch (ecosystemName, publicConfig["evm"], publicConfig["fuel"]) {
  | (Ecosystem.Evm, Some(evm), _) => evm["contracts"]
  | (Ecosystem.Fuel, _, Some(fuel)) => fuel["contracts"]
  | _ => None
  }

  // Store both ABI and event signatures for each contract (using inline tuple)
  let contractsWithAbis: Js.Dict.t<(EvmTypes.Abi.t, array<string>)> = switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Js.Dict.entries
    ->Js.Array2.map(((contractName, contractConfig)) => {
      let abi = contractConfig["abi"]->(Utils.magic: Js.Json.t => EvmTypes.Abi.t)
      let eventSignatures = switch contractConfig["events"] {
      | Some(events) => events->Array.map(eventItem => eventItem["event"])
      | None => []
      }
      (contractName->Utils.String.capitalize, (abi, eventSignatures))
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
      | Some((abi, eventSignatures)) =>
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
        // Convert codegenContract to contract by adding abi and eventSignatures
        {
          name: codegenContract.name,
          abi,
          addresses: parsedAddresses,
          events: codegenContract.events,
          startBlock: codegenContract.startBlock,
          eventSignatures,
        }
      | None =>
        let availableContracts = contractsWithAbis->Js.Dict.keys->Js.Array2.joinWith(", ")
        Js.Exn.raiseError(
          `Contract "${codegenContract.name}" not found in config. ` ++
          `Available contracts: [${availableContracts}]. ` ++
          "Make sure contract names match between config.yaml and the generated config.",
        )
      }
    })
    contractsByChainId->Js.Dict.set(codegenChain.id->Int.toString, mergedContracts)
  })

  // Helper to convert parsed RPC config to evmRpcConfig
  let parseRpcSourceFor = (sourceFor: rpcSourceFor): Source.sourceFor => {
    switch sourceFor {
    | Sync => Source.Sync
    | Fallback => Source.Fallback
    | Live => Source.Live
    }
  }

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
        let availableIds = codegenChainById->Js.Dict.keys->Js.Array2.joinWith(", ")
        Js.Exn.raiseError(
          `Chain with id ${chainId->Int.toString} not found in codegen config. ` ++
          `Available chain ids: [${availableIds}]. ` ++
          "Run codegen to regenerate the config.",
        )
      }
      let mergedContracts = switch contractsByChainId->Js.Dict.get(chainId->Int.toString) {
      | Some(contracts) => contracts
      | None =>
        let availableIds = contractsByChainId->Js.Dict.keys->Js.Array2.joinWith(", ")
        Js.Exn.raiseError(
          `Contracts for chain with id ${chainId->Int.toString} not found. ` ++
          `Chains with contracts: [${availableIds}]. ` ++
          "Run codegen to regenerate the config.",
        )
      }

      // Build sourceConfig from the parsed chain config
      let sourceConfig = switch ecosystemName {
      | Ecosystem.Evm =>
        let rpcs =
          publicChainConfig["rpcs"]
          ->Option.getWithDefault([])
          ->Array.map((rpcConfig): evmRpcConfig => {
            // Build syncConfig from flattened fields
            let initialBlockInterval = rpcConfig["initialBlockInterval"]
            let backoffMultiplicative = rpcConfig["backoffMultiplicative"]
            let accelerationAdditive = rpcConfig["accelerationAdditive"]
            let intervalCeiling = rpcConfig["intervalCeiling"]
            let backoffMillis = rpcConfig["backoffMillis"]
            let queryTimeoutMillis = rpcConfig["queryTimeoutMillis"]
            let fallbackStallTimeout = rpcConfig["fallbackStallTimeout"]
            let pollingInterval = rpcConfig["pollingInterval"]
            let hasSyncConfig =
              initialBlockInterval->Option.isSome ||
              backoffMultiplicative->Option.isSome ||
              accelerationAdditive->Option.isSome ||
              intervalCeiling->Option.isSome ||
              backoffMillis->Option.isSome ||
              queryTimeoutMillis->Option.isSome ||
              fallbackStallTimeout->Option.isSome ||
              pollingInterval->Option.isSome
            let syncConfig: option<sourceSyncOptions> = if hasSyncConfig {
              Some({
                ?initialBlockInterval,
                ?backoffMultiplicative,
                ?accelerationAdditive,
                ?intervalCeiling,
                ?backoffMillis,
                ?queryTimeoutMillis,
                ?fallbackStallTimeout,
                ?pollingInterval,
              })
            } else {
              None
            }
            {
              url: rpcConfig["url"],
              sourceFor: parseRpcSourceFor(rpcConfig["for"]),
              syncConfig,
              ws: rpcConfig["ws"],
            }
          })
        EvmSourceConfig({hypersync: publicChainConfig["hypersync"], rpcs})
      | Ecosystem.Fuel =>
        switch publicChainConfig["hypersync"] {
        | Some(hypersync) => FuelSourceConfig({hypersync: hypersync})
        | None =>
          Js.Exn.raiseError(
            `Chain ${chainName} is missing hypersync endpoint in config`,
          )
        }
      | Ecosystem.Svm =>
        switch publicChainConfig["rpc"] {
        | Some(rpc) => SvmSourceConfig({rpc: rpc})
        | None =>
          Js.Exn.raiseError(
            `Chain ${chainName} is missing rpc endpoint in config`,
          )
        }
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
        sourceConfig,
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

  // Parse enums and entities from JSON config
  let allEnums =
    publicConfig["enums"]
    ->Option.getWithDefault(Js.Dict.empty())
    ->parseEnumsFromJson

  let enumConfigsByName =
    allEnums
    ->Js.Array2.map(enumConfig => (enumConfig.name, enumConfig))
    ->Js.Dict.fromArray

  let userEntities =
    publicConfig["entities"]
    ->Option.getWithDefault([])
    ->parseEntitiesFromJson(~enumConfigsByName)

  let allEntities =
    userEntities->Js.Array2.concat([DynamicContractRegistry.entityConfig])

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
        name: contractName->Utils.String.capitalize,
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
    userEntities,
    allEntities,
    allEnums,
  }
}

let shouldSaveHistory = (config, ~isInReorgThreshold) =>
  config.shouldSaveFullHistory || (config.shouldRollbackOnReorg && isInReorgThreshold)

let shouldPruneHistory = (config, ~isInReorgThreshold) =>
  !config.shouldSaveFullHistory && (config.shouldRollbackOnReorg && isInReorgThreshold)

let getChain = (config, ~chainId) => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
  if config.chainMap->ChainMap.has(chain) {
    chain
  } else {
    let availableChains =
      config.chainMap
      ->ChainMap.keys
      ->Array.map(ChainMap.Chain.toString)
      ->Js.Array2.joinWith(", ")
    Js.Exn.raiseError(
      `No chain with id ${chain->ChainMap.Chain.toString} found in config. ` ++
      `Available chain ids: [${availableChains}]`,
    )
  }
}

