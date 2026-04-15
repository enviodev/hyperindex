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

// Source config parsed from `envio config view` - sources are created lazily in ChainFetcher
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
  blockLag: int,
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

type multichain = Internal.multichain =
  | @as("ordered") Ordered
  | @as("unordered") Unordered

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
  userEntitiesByName: dict<Internal.entityConfig>,
  userEntities: array<Internal.entityConfig>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Table.enumConfig<Table.enum>>,
}

module EnvioAddresses = {
  let name = "envio_addresses"
  let index = -1

  let makeId = (~chainId, ~address) => {
    chainId->Belt.Int.toString ++ "-" ++ address->Address.toString
  }

  type t = {
    id: string,
    @as("chain_id") chainId: int,
    @as("registration_block") registrationBlock: int,
    // -1 when the address was registered from a block handler (no log index)
    @as("registration_log_index") registrationLogIndex: int,
    @as("contract_name") contractName: string,
  }

  // Extract the raw contract address from the composite id ({chainId}-{address}).
  // Inverse of makeId. Keep in sync with makeId above and the SUBSTRING SQL in
  // InternalTable.Chains.makeGetInitialStateQuery.
  let getAddress = (entity: t): Address.t => {
    let sepIdx = entity.id->String.indexOf("-")
    entity.id
    ->String.slice(~start=sepIdx + 1, ~end=entity.id->String.length)
    ->Address.unsafeFromString
  }

  let schema = S.schema(s => {
    id: s.matches(S.string),
    chainId: s.matches(S.int),
    registrationBlock: s.matches(S.int),
    registrationLogIndex: s.matches(S.int),
    contractName: s.matches(S.string),
  })

  let rowsSchema = S.array(schema)

  let table = Table.mkTable(
    name,
    ~fields=[
      Table.mkField("id", String, ~isPrimaryKey=true, ~fieldSchema=S.string),
      Table.mkField("chain_id", Int32, ~fieldSchema=S.int),
      Table.mkField("registration_block", Int32, ~fieldSchema=S.int),
      // -1 sentinel when registered from a block handler (no log index)
      Table.mkField("registration_log_index", Int32, ~fieldSchema=S.int),
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

// Types for parsing source config from the JSON emitted by `envio config view`
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

let chainContractSchema = S.schema(s =>
  {
    "addresses": s.matches(S.option(S.array(S.string))),
    "startBlock": s.matches(S.option(S.int)),
  }
)

let publicConfigChainSchema = S.schema(s =>
  {
    "id": s.matches(S.int),
    "startBlock": s.matches(S.int),
    "endBlock": s.matches(S.option(S.int)),
    "maxReorgDepth": s.matches(S.option(S.int)),
    "blockLag": s.matches(S.option(S.int)),
    // EVM/Fuel source config (hypersync for EVM, hyperfuel for Fuel)
    "hypersync": s.matches(S.option(S.string)),
    "rpcs": s.matches(S.option(S.array(rpcConfigSchema))),
    // SVM source config
    "rpc": s.matches(S.option(S.string)),
    // Per-chain contract data (addresses and optional start block)
    "contracts": s.matches(S.option(S.dict(chainContractSchema))),
  }
)

let contractEventItemSchema = S.schema(s =>
  {
    "event": s.matches(S.string),
    "name": s.matches(S.string),
    "sighash": s.matches(S.string),
    "params": s.matches(S.option(S.array(EventConfigBuilder.eventParamSchema))),
    "kind": s.matches(S.option(S.string)),
    "blockFields": s.matches(S.option(S.array(Internal.evmBlockFieldSchema))),
    "transactionFields": s.matches(S.option(S.array(Internal.evmTransactionFieldSchema))),
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
    "globalBlockFields": s.matches(S.option(S.array(Internal.evmBlockFieldSchema))),
    "globalTransactionFields": s.matches(S.option(S.array(Internal.evmTransactionFieldSchema))),
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

let getFieldTypeAndSchema = (prop, ~enumConfigsByName: dict<Table.enumConfig<Table.enum>>) => {
  let typ = prop["type"]
  let isNullable = prop["isNullable"]->Option.getOr(false)
  let isArray = prop["isArray"]->Option.getOr(false)
  let isIndex = prop["isIndex"]->Option.getOr(false)

  let (fieldType, baseSchema) = switch typ {
  | "string" => (Table.String, S.string->S.toUnknown)
  | "boolean" => (Table.Boolean, S.bool->S.toUnknown)
  | "int" => (Table.Int32, S.int->S.toUnknown)
  | "bigint" => (Table.BigInt({precision: ?prop["precision"]}), Utils.BigInt.schema->S.toUnknown)
  | "bigdecimal" => (
      Table.BigDecimal({
        config: ?prop["precision"]->Option.map(p => (p, prop["scale"]->Option.getOr(0))),
      }),
      BigDecimal.schema->S.toUnknown,
    )
  | "float" => (Table.Number, S.float->S.toUnknown)
  | "serial" => (Table.Serial, S.int->S.toUnknown)
  | "json" => (Table.Json, S.json(~validate=false)->S.toUnknown)
  | "date" => (Table.Date, Utils.Schema.dbDate->S.toUnknown)
  | "enum" => {
      let enumName = prop["enum"]->Option.getOrThrow

      // Build contracts for this chain from per-chain contract data + contract configs

      // Get per-chain contract data (addresses, startBlock)

      // Build event configs from JSON (field selections resolved inline)

      // Build sourceConfig from the parsed chain config

      // Build syncConfig from flattened fields

      // Fuel doesn't have reorgs, SVM reorg handling is not supported
      let enumConfig = enumConfigsByName->Dict.get(enumName)->Option.getOrThrow
      (Table.Enum({config: enumConfig}), enumConfig.schema->S.toUnknown)
    }
  | "entity" => {
      let entityName = prop["entity"]->Option.getOrThrow
      (Table.Entity({name: entityName}), S.string->S.toUnknown)
    }
  | other => JsError.throwWithMessage("Unknown field type in entity config: " ++ other)
  }

  let fieldSchema = if isArray {
    S.array(baseSchema)->S.toUnknown
  } else {
    baseSchema
  }
  let fieldSchema = if isNullable {
    S.null(fieldSchema)->S.toUnknown
  } else {
    fieldSchema
  }

  (fieldType, fieldSchema, isNullable, isArray, isIndex)
}

let parseEnumsFromJson = (enumsJson: dict<array<string>>): array<Table.enumConfig<Table.enum>> => {
  enumsJson
  ->Dict.toArray
  ->Array.map(((name, variants)) =>
    Table.makeEnumConfig(~name, ~variants)->Table.fromGenericEnumConfig
  )
}

let parseEntitiesFromJson = (
  entitiesJson: array<'entityJson>,
  ~enumConfigsByName: dict<Table.enumConfig<Table.enum>>,
): array<Internal.entityConfig> => {
  entitiesJson->Array.mapWithIndex((entityJson, index) => {
    let entityName = entityJson["name"]

    let fields: array<Table.fieldOrDerived> = entityJson["properties"]->Array.map(prop => {
      let (fieldType, fieldSchema, isNullable, isArray, isIndex) = getFieldTypeAndSchema(
        prop,
        ~enumConfigsByName,
      )
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
      ->Option.getOr([])
      ->Array.map(df =>
        Table.mkDerivedFromField(
          df["fieldName"],
          ~derivedFromEntity=df["derivedFromEntity"],
          ~derivedFromField=df["derivedFromField"],
        )
      )

    let compositeIndices =
      entityJson["compositeIndices"]
      ->Option.getOr([])
      ->Array.map(ci =>
        ci->Array.map(
          f => {
            Table.fieldName: f["fieldName"],
            direction: f["direction"] == "Asc" ? Table.Asc : Table.Desc,
          },
        )
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
      let dict = Dict.make()
      entityJson["properties"]->Array.forEach(
        prop => {
          let (_, fieldSchema, _, _, _) = getFieldTypeAndSchema(prop, ~enumConfigsByName)
          let dbFieldName = switch prop["linkedEntity"] {
          | Some(_) => prop["name"] ++ "_id"
          | None => prop["name"]
          }
          dict->Dict.set(dbFieldName, s.matches(fieldSchema))
        },
      )
      dict
    })

    {
      Internal.name: entityName,
      index,
      schema: schema->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.entity>),
      rowsSchema: S.array(schema)->(
        Utils.magic: S.t<array<dict<unknown>>> => S.t<array<Internal.entity>>
      ),
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

let fromPublic = (publicConfigJson: JSON.t, ~maxAddrInPartition=5000) => {
  // Parse public config
  let publicConfig = try publicConfigJson->S.parseOrThrow(publicConfigSchema) catch {
  | S.Raised(exn) =>
    JsError.throwWithMessage(
      `Invalid indexer config: ${exn->Utils.prettifyExn->(Utils.magic: exn => string)}`,
    )
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
    JsError.throwWithMessage("Invalid indexer config: No ecosystem configured (evm, fuel, or svm)")
  | _ =>
    JsError.throwWithMessage(
      "Invalid indexer config: Multiple ecosystems are not supported for a single indexer",
    )
  }

  // Extract EVM-specific options with defaults
  let lowercaseAddresses = switch publicConfig["evm"] {
  | Some(evm) => evm["addressFormat"]->Option.getOr(Checksum) == Lowercase
  | None => false
  }

  // Parse contract configs (ABIs, events, handlers)
  let publicContractsConfig = switch (ecosystemName, publicConfig["evm"], publicConfig["fuel"]) {
  | (Ecosystem.Evm, Some(evm), _) => evm["contracts"]
  | (Ecosystem.Fuel, _, Some(fuel)) => fuel["contracts"]
  | _ => None
  }

  // Create global field selection Sets once (shared across events without per-event overrides)
  let (globalBlockFieldsSet, globalTransactionFieldsSet) = switch publicConfig["evm"] {
  | Some(evm) => (
      Utils.Set.fromArray(
        Array.concat(
          EventConfigBuilder.alwaysIncludedBlockFields,
          evm["globalBlockFields"]->Option.getOr([]),
        ),
      ),
      Utils.Set.fromArray(evm["globalTransactionFields"]->Option.getOr([])),
    )
  | None => (Utils.Set.fromArray(EventConfigBuilder.alwaysIncludedBlockFields), Utils.Set.make())
  }

  // Build contract data lookup: ABI, event signatures, event configs (keyed by capitalized name)
  let contractDataByName: dict<{
    "abi": EvmTypes.Abi.t,
    "eventSignatures": array<string>,
    "events": option<array<_>>,
  }> = Dict.make()
  switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Dict.toArray
    ->Array.forEach(((contractName, contractConfig)) => {
      let capitalizedName = contractName->Utils.String.capitalize
      let abi = contractConfig["abi"]->(Utils.magic: JSON.t => EvmTypes.Abi.t)
      let eventSignatures = switch contractConfig["events"] {
      | Some(events) => events->Array.map(eventItem => eventItem["event"])
      | None => []
      }
      contractDataByName->Dict.set(
        capitalizedName,
        {"abi": abi, "eventSignatures": eventSignatures, "events": contractConfig["events"]},
      )
    })
  | None => ()
  }

  // Build event configs for a contract from JSON event items
  let buildContractEvents = (~contractName, ~events: option<array<_>>, ~abi, ~chainId: int) => {
    switch events {
    | None => []
    | Some(eventItems) =>
      eventItems->Array.map(eventItem => {
        let eventName = eventItem["name"]
        let sighash = eventItem["sighash"]
        let params = eventItem["params"]->Option.getOr([])
        let kind = eventItem["kind"]
        // Get handler registration data
        let isWildcard = HandlerRegister.isWildcard(~contractName, ~eventName)
        let handler = HandlerRegister.getHandler(~contractName, ~eventName)
        let contractRegister = HandlerRegister.getContractRegister(~contractName, ~eventName)

        switch ecosystemName {
        | Ecosystem.Fuel =>
          switch kind {
          | Some(fuelKind) =>
            (EventConfigBuilder.buildFuelEventConfig(
              ~contractName,
              ~eventName,
              ~kind=fuelKind,
              ~sighash,
              ~rawAbi=abi->(Utils.magic: EvmTypes.Abi.t => JSON.t),
              ~isWildcard,
              ~handler,
              ~contractRegister,
            ) :> Internal.eventConfig)
          | None =>
            JsError.throwWithMessage(
              `Fuel event ${contractName}.${eventName} is missing "kind" in internal config`,
            )
          }
        | _ =>
          (EventConfigBuilder.buildEvmEventConfig(
            ~contractName,
            ~eventName,
            ~sighash,
            ~params,
            ~isWildcard,
            ~handler,
            ~contractRegister,
            ~eventFilters=HandlerRegister.getOnEventWhere(~contractName, ~eventName),
            ~probeChainId=chainId,
            ~blockFields=?eventItem["blockFields"],
            ~transactionFields=?eventItem["transactionFields"],
            ~globalBlockFieldsSet,
            ~globalTransactionFieldsSet,
          ) :> Internal.eventConfig)
        }
      })
    }
  }

  // Parse address based on ecosystem and address format
  let parseAddress = addressString => {
    switch ecosystemName {
    | Ecosystem.Evm =>
      if lowercaseAddresses {
        addressString->Address.Evm.fromStringLowercaseOrThrow
      } else {
        addressString->Address.Evm.fromStringOrThrow
      }
    | Ecosystem.Fuel | Ecosystem.Svm => addressString->Address.unsafeFromString
    }
  }

  // Helper to convert parsed RPC config to evmRpcConfig
  let parseRpcSourceFor = (sourceFor: rpcSourceFor): Source.sourceFor => {
    switch sourceFor {
    | Sync => Source.Sync
    | Fallback => Source.Fallback
    | Live => Source.Live
    }
  }

  // Build chains from JSON config (no more codegenChains)
  let chains =
    publicChainsConfig
    ->Dict.keysToArray
    ->Array.map(chainName => {
      let publicChainConfig = publicChainsConfig->Dict.getUnsafe(chainName)
      let chainId = publicChainConfig["id"]

      let chainContracts = publicChainConfig["contracts"]->Option.getOr(Dict.make())
      let contracts =
        contractDataByName
        ->Dict.toArray
        ->Array.map(((capitalizedName, contractData)) => {
          let chainContract = chainContracts->Dict.get(capitalizedName)
          let addresses =
            chainContract
            ->Option.flatMap(cc => cc["addresses"])
            ->Option.getOr([])
            ->Array.map(parseAddress)
          let startBlock = chainContract->Option.flatMap(cc => cc["startBlock"])

          // Build event configs from JSON (field selections resolved inline)
          // chainId is threaded in so the where-callback detection probe
          // exercises the callback with this chain's real id — handlers
          // that branch on `chain.id` are taken through the same path
          // they will follow at runtime.
          let events = buildContractEvents(
            ~contractName=capitalizedName,
            ~events=contractData["events"],
            ~abi=contractData["abi"],
            ~chainId,
          )

          {
            name: capitalizedName,
            abi: contractData["abi"],
            addresses,
            events,
            startBlock,
            eventSignatures: contractData["eventSignatures"],
          }
        })

      let sourceConfig = switch ecosystemName {
      | Ecosystem.Evm =>
        let rpcs =
          publicChainConfig["rpcs"]
          ->Option.getOr([])
          ->Array.map((rpcConfig): evmRpcConfig => {
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
          JsError.throwWithMessage(`Chain ${chainName} is missing hypersync endpoint in config`)
        }
      | Ecosystem.Svm =>
        switch publicChainConfig["rpc"] {
        | Some(rpc) => SvmSourceConfig({rpc: rpc})
        | None => JsError.throwWithMessage(`Chain ${chainName} is missing rpc endpoint in config`)
        }
      }

      {
        name: chainName,
        id: chainId,
        startBlock: publicChainConfig["startBlock"],
        endBlock: ?publicChainConfig["endBlock"],
        maxReorgDepth: switch ecosystemName {
        | Ecosystem.Evm => publicChainConfig["maxReorgDepth"]->Option.getOr(200)

        | Ecosystem.Fuel | Ecosystem.Svm => 0
        },
        blockLag: publicChainConfig["blockLag"]->Option.getOr(0),
        contracts,
        sourceConfig,
      }
    })

  let chainMap =
    chains
    ->Array.map(chain => {
      (ChainMap.Chain.makeUnsafe(~chainId=chain.id), chain)
    })
    ->ChainMap.fromArrayUnsafe

  let ecosystem = switch ecosystemName {
  | Ecosystem.Evm => Evm.ecosystem
  | Ecosystem.Fuel => Fuel.ecosystem
  | Ecosystem.Svm => Svm.ecosystem
  }

  // Parse enums and entities from JSON config
  let allEnums =
    publicConfig["enums"]
    ->Option.getOr(Dict.make())
    ->parseEnumsFromJson

  let enumConfigsByName =
    allEnums->Array.map(enumConfig => (enumConfig.name, enumConfig))->Dict.fromArray

  let userEntities =
    publicConfig["entities"]
    ->Option.getOr([])
    ->parseEntitiesFromJson(~enumConfigsByName)

  let allEntities = userEntities->Array.concat([EnvioAddresses.entityConfig])

  let userEntitiesByName =
    userEntities
    ->Array.map(entityConfig => {
      (entityConfig.name, entityConfig)
    })
    ->Dict.fromArray

  // Extract contract handlers from the public config
  let contractHandlers = switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Dict.toArray
    ->Array.map(((contractName, contractConfig)) => {
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
    handlers: publicConfig["handlers"]->Option.getOr("src/handlers"),
    contractHandlers,
    shouldRollbackOnReorg: publicConfig["rollbackOnReorg"]->Option.getOr(true),
    shouldSaveFullHistory: publicConfig["saveFullHistory"]->Option.getOr(false),
    multichain: publicConfig["multichain"]->Option.getOr(Unordered),
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents: publicConfig["rawEvents"]->Option.getOr(false),
    ecosystem,
    maxAddrInPartition,
    batchSize: publicConfig["fullBatchSize"]->Option.getOr(5000),
    lowercaseAddresses,
    userEntitiesByName,
    userEntities,
    allEntities,
    allEnums,
  }
}

// Look up an event config by (contract, event) name. When `chainId` is given,
// returns that chain's per-chain event config (matters for where-callback
// probe detection, which runs with the chain's real id). Without `chainId`,
// falls back to the first chain that declares this event.
let getEventConfig = (config: t, ~contractName, ~eventName, ~chainId: option<int>=?) => {
  let chains = switch chainId {
  | Some(chainId) =>
    let chain = ChainMap.Chain.makeUnsafe(~chainId)
    switch config.chainMap->ChainMap.get(chain) {
    | chainConfig => [chainConfig]
    | exception _ =>
      JsError.throwWithMessage(
        `Chain ${chainId->Int.toString} is not configured. Add it to config.yaml or pass a configured chain.`,
      )
    }
  | None => config.chainMap->ChainMap.values
  }
  chains->Array.reduce(None, (acc, chain) => {
    switch acc {
    | Some(_) => acc
    | None =>
      chain.contracts
      ->Array.find(c => c.name == contractName)
      ->Belt.Option.flatMap(contract => contract.events->Array.find(e => e.name == eventName))
    }
  })
}

let shouldSaveHistory = (config, ~isInReorgThreshold) =>
  config.shouldSaveFullHistory || (config.shouldRollbackOnReorg && isInReorgThreshold)

let shouldPruneHistory = (config, ~isInReorgThreshold) =>
  !config.shouldSaveFullHistory && (config.shouldRollbackOnReorg && isInReorgThreshold)

let getChain = (config, ~chainId) => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId)
  config.chainMap->ChainMap.has(chain)
    ? chain
    : JsError.throwWithMessage(
        "No chain with id " ++ chain->ChainMap.Chain.toString ++ " found in config.yaml",
      )
}

// Resolve the envio CLI entry relative to this file's own URL. We don't go
// through `import.meta.resolve("envio/...")` because `Config.res.mjs` lives
// inside the envio package, so the package isn't in its own resolver
// scope. Walking up via a relative URL always works as long as the
// package layout (src/Config.res.mjs next to bin.mjs) is stable, which it
// is for both the dev workspace member and the published artifact.
//
// We prefer this over bare `spawnSync("envio")` because vitest workers,
// hooks, and ad-hoc Node scripts frequently don't inherit
// `node_modules/.bin` on PATH.
@val external importMetaUrl: string = "import.meta.url"
@val external nodeExecPath: string = "process.execPath"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:fs") external existsSync: string => bool = "existsSync"
@new external makeUrl: (string, string) => {..} = "URL"
@get external urlHref: {..} => string = "href"

// Only return the path if `bin.mjs` actually exists next to this file; if
// the layout ever drifts (e.g., a downstream bundler flattens the package)
// we fall through to the `"envio"` PATH fallback in `fromConfigView`
// instead of trying to spawn a missing file.
let resolveEnvioBinPath = () =>
  try {
    let binPath = fileURLToPath(makeUrl("../bin.mjs", importMetaUrl)->urlHref)
    existsSync(binPath) ? Some(binPath) : None
  } catch {
  | _ => None
  }

// Load the resolved indexer config by shelling out to the envio CLI.
// `envio config view` prints the same JSON we used to bundle as
// `generated/internal.config.json`. We resolve it via spawnSync (blocking)
// so the returned value is ready before callers use it. Keeps stdin
// untouched so the TUI can consume it in the future.
//
// We invoke the CLI by resolving `envio/bin.mjs` through Node's module
// resolution and running it with `process.execPath`. That works in every
// realistic call site — indexer runtime, vitest workers, migrations —
// without depending on PATH being set up correctly. As a last-ditch
// fallback we try `envio` via PATH (covers callers that shadow the module
// resolution, e.g. globally installed CLIs).
//
// Only genuine CLI-discovery / spawn failures collapse to the generic
// "install / codegen" hint. Non-zero exits surface the CLI's stderr (so
// misconfigured `config.yaml` errors stay diagnosable) and JSON parsing
// or schema validation errors propagate untouched.
let fromConfigView = () => {
  let cliMissingErr = "Couldn't load the indexer config. Run `envio codegen` and make sure the envio CLI is installed."

  let (cmd, prefixArgs) = switch resolveEnvioBinPath() {
  | Some(binPath) => (nodeExecPath, [binPath])
  | None => ("envio", [])
  }

  let result = try {
    NodeJs.ChildProcess.spawnSync(
      cmd,
      prefixArgs->Array.concat(["config", "view"]),
      {
        encoding: "utf8",
        // Configs can be large (hundreds of events with ABIs). Default 1MB
        // is too small; 64MB is a conservative ceiling that still catches
        // runaway output.
        maxBuffer: 64 * 1024 * 1024,
      },
    )
  } catch {
  | _ => JsError.throwWithMessage(cliMissingErr)
  }

  // spawnSync sets `error` for several distinct failure classes: the
  // discovery errors ENOENT/EACCES (collapse to the "install/codegen"
  // hint), and the execution errors ETIMEDOUT, ENOBUFS, and friends
  // (surface the actual message — those are real bugs, not missing-CLI
  // problems, and hiding them makes them undiagnosable).
  switch result.error->Nullable.toOption {
  | Some(spawnErr) =>
    let code =
      spawnErr
      ->(Utils.magic: exn => {"code": Nullable.t<string>})
      ->(x => x["code"])
      ->Nullable.toOption
      ->Option.getOr("")
    if code === "ENOENT" || code === "EACCES" {
      JsError.throwWithMessage(cliMissingErr)
    } else {
      let msg = spawnErr->Utils.prettifyExn->(Utils.magic: exn => string)
      JsError.throwWithMessage(msg)
    }
  | None => ()
  }

  switch result.status->Nullable.toOption {
  | Some(0) => ()
  | _ =>
    // Non-zero exit: the CLI ran but refused to produce a config. Surface
    // its stderr so config.yaml parse errors and similar propagate with a
    // real pointer, and only fall back to the generic hint when stderr is
    // empty.
    let stderr = result.stderr->String.trim
    if stderr === "" {
      JsError.throwWithMessage(cliMissingErr)
    } else {
      JsError.throwWithMessage(stderr)
    }
  }

  // Let JSON.parseOrThrow / fromPublic validation errors propagate — those
  // indicate real bugs in the CLI output or schema drift and need their
  // actual messages to be actionable.
  result.stdout->JSON.parseOrThrow->fromPublic
}
