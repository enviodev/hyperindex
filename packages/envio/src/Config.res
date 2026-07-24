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
}

// Sources are instantiated lazily in ChainState from this config.
type evmRpcConfig = {
  url: string,
  sourceFor: Source.sourceFor,
  syncConfig: option<sourceSyncOptions>,
  ws: option<string>,
  headers: option<dict<string>>,
}

type sourceConfig =
  | EvmSourceConfig({hypersync: option<string>, rpcs: array<evmRpcConfig>})
  | FuelSourceConfig({hypersync: string})
  | SvmSourceConfig({hypersync: option<string>, rpc: option<string>})
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

type storage = {
  postgres: bool,
  clickhouse: bool,
}

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
  storage: storage,
  chainMap: ChainMap.t<chain>,
  defaultChain: option<chain>,
  ecosystem: Ecosystem.t,
  enableRawEvents: bool,
  maxAddrInPartition: int,
  // Per-contract registered-address count past which a dynamic contract switches
  // to client-side filtering. Overridable in tests.
  clientFilterAddressThreshold: int,
  batchSize: int,
  // Slack (in blocks) below the lagged head within which a chain still counts as
  // ready to enter the reorg threshold, absorbing head advances between catch-up
  // and the entry check. Overridable in tests.
  reorgThresholdReadyTolerance: int,
  lowercaseAddresses: bool,
  isDev: bool,
  userEntitiesByName: dict<Internal.entityConfig>,
  userEntities: array<Internal.entityConfig>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Table.enumConfig<Table.enum>>,
}

module EnvioAddresses = {
  let name = "envio_addresses"
  let index = -1

  let makeId = (~chainId, ~address) => {
    chainId->Int.toString ++ "-" ++ address->Address.toString
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
    Internal.name,
    index,
    schema,
    table,
    // Internal address tracking is Postgres-only; the global config is
    // always required to have Postgres enabled (Storage::resolve forbids
    // a Postgres-disabled global), so this is safe regardless of mode.
    storage: {postgres: true, clickhouse: false},
  }->Internal.fromGenericEntityConfig
}

type rpcSourceFor = | @as("sync") Sync | @as("fallback") Fallback | @as("realtime") Realtime

let rpcSourceForSchema = S.enum([Sync, Fallback, Realtime])

let rpcConfigSchema = S.schema(s =>
  {
    "url": s.matches(S.string),
    "for": s.matches(rpcSourceForSchema),
    "ws": s.matches(S.option(S.string)),
    "headers": s.matches(S.option(S.dict(S.string))),
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

let svmEventDescriptorSchema = S.schema(s =>
  {
    "discriminator": s.matches(S.option(S.string)),
    "discriminatorByteLen": s.matches(S.int),
    "transactionFields": s.matches(S.array(Internal.svmTransactionFieldSchema)),
    "blockFields": s.matches(S.option(S.array(Internal.svmBlockFieldSchema))),
    "includeLogs": s.matches(S.bool),
    // An array of AND-groups OR-ed together: the CLI normalizes both the flat
    // and `any_of` YAML shapes to `Vec<Vec<SvmAccountFilterJson>>`.
    "accountFilters": s.matches(
      S.option(
        S.array(
          S.array(
            S.schema(s =>
              {
                "position": s.matches(S.int),
                "values": s.matches(S.array(S.string)),
              }
            ),
          ),
        ),
      ),
    ),
    "isInner": s.matches(S.option(S.bool)),
    "accounts": s.matches(S.option(S.array(S.string))),
    "args": s.matches(S.option(S.json(~validate=false))),
  }
)

let svmAbiSchema = S.schema(s =>
  {
    "programId": s.matches(S.string),
    "definedTypes": s.matches(S.json(~validate=false)),
    "source": s.matches(S.string),
  }
)

let contractEventItemSchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "sighash": s.matches(S.string),
    "params": s.matches(S.option(S.array(EventConfigBuilder.paramMetaSchema))),
    "kind": s.matches(S.option(S.string)),
    "blockFields": s.matches(S.option(S.array(Internal.evmBlockFieldSchema))),
    "transactionFields": s.matches(S.option(S.array(Internal.evmTransactionFieldSchema))),
    "svm": s.matches(S.option(svmEventDescriptorSchema)),
  }
)

let contractConfigSchema = S.schema(s =>
  {
    "abi": s.matches(S.json(~validate=false)),
    "handler": s.matches(S.option(S.string)),
    // EVM-specific: event signatures for HyperSync queries
    "events": s.matches(S.option(S.array(contractEventItemSchema))),
    // SVM-only: program-level Borsh schema (defined-types registry, source).
    "svmAbi": s.matches(S.option(svmAbiSchema)),
  }
)

let publicConfigEcosystemSchema = S.schema(s =>
  {
    "chains": s.matches(S.dict(publicConfigChainSchema)),
    "contracts": s.matches(S.option(S.dict(contractConfigSchema))),
    // SVM-only alias: programs are the SVM analog of EVM/Fuel contracts.
    // Parsed via the same `contractConfigSchema` and read in `fromPublic`'s
    // `publicContractsConfig` switch.
    "programs": s.matches(S.option(S.dict(contractConfigSchema))),
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
    "description": s.matches(S.option(S.string)),
  }
)

let propertySchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "postgresDbName": s.matches(S.option(S.string)),
    "clickhouseDbName": s.matches(S.option(S.string)),
    "type": s.matches(S.string),
    "isNullable": s.matches(S.option(S.bool)),
    "isArray": s.matches(S.option(S.bool)),
    "isIndex": s.matches(S.option(S.bool)),
    "linkedEntity": s.matches(S.option(S.string)),
    "enum": s.matches(S.option(S.string)),
    "entity": s.matches(S.option(S.string)),
    "precision": s.matches(S.option(S.int)),
    "scale": s.matches(S.option(S.int)),
    "description": s.matches(S.option(S.string)),
  }
)

let clickhouseTableOptionsSchema: S.t<Internal.clickhouseTableOptions> = S.object(s => {
  Internal.partitionBy: ?s.field("partitionBy", S.option(S.string)),
  orderBy: ?s.field("orderBy", S.option(S.array(S.string))),
  ttl: ?s.field("ttl", S.option(S.string)),
})

// The entity's `clickhouse` storage arg mirrors the @storage directive:
// either a boolean or a table options object (which implies enabled).
type entityClickhouseStorageJson =
  | Enabled(bool)
  | TableOptions(Internal.clickhouseTableOptions)

let entityClickhouseStorageJsonSchema = S.union([
  S.bool->S.shape(enabled => Enabled(enabled)),
  clickhouseTableOptionsSchema->S.shape(options => TableOptions(options)),
])

let entityStorageSchema = S.schema(s =>
  {
    "postgres": s.matches(S.option(S.bool)),
    "clickhouse": s.matches(S.option(entityClickhouseStorageJsonSchema)),
  }
)

let entityJsonSchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "storage": s.matches(S.option(entityStorageSchema)),
    "properties": s.matches(S.array(propertySchema)),
    "derivedFields": s.matches(S.option(S.array(derivedFieldSchema))),
    "compositeIndices": s.matches(S.option(S.array(S.array(compositeIndexFieldSchema)))),
    "description": s.matches(S.option(S.string)),
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
        config: ?(prop["precision"]->Option.map(p => (p, prop["scale"]->Option.getOr(0)))),
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
  ~globalStorage: storage,
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
        ~description=?prop["description"],
        ~postgresDbName=?prop["postgresDbName"],
        ~clickhouseDbName=?prop["clickhouseDbName"],
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
          ~description=?df["description"],
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
      ~description=?entityJson["description"],
    )

    let getApiFieldName = prop =>
      switch prop["linkedEntity"] {
      | Some(_) => prop["name"] ++ "_id"
      | None => prop["name"]
      }

    // Build schema dynamically from properties
    // Use API field names (with _id suffix for linked entities) as schema
    // locations to match the generated entity types
    let schema = S.schema(s => {
      let dict = Dict.make()
      entityJson["properties"]->Array.forEach(
        prop => {
          let (_, fieldSchema, _, _, _) = getFieldTypeAndSchema(prop, ~enumConfigsByName)
          dict->Dict.set(prop->getApiFieldName, s.matches(fieldSchema))
        },
      )
      dict
    })

    // Resolve per-entity storage against the global config. The CLI
    // validates that an entity never opts into a backend the global
    // config didn't enable, and that at least one backend stays true
    // for an annotated entity — so `getOr(false)` is safe here.
    let storage: Internal.entityStorage = switch entityJson["storage"] {
    | Some(s) =>
      switch s["clickhouse"] {
      | Some(TableOptions(options)) => {
          postgres: s["postgres"]->Option.getOr(false),
          clickhouse: true,
          clickhouseOptions: options,
        }
      | Some(Enabled(clickhouse)) => {
          postgres: s["postgres"]->Option.getOr(false),
          clickhouse,
        }
      | None => {
          postgres: s["postgres"]->Option.getOr(false),
          clickhouse: false,
        }
      }
    | None => {
        postgres: globalStorage.postgres,
        clickhouse: globalStorage.clickhouse,
      }
    }

    {
      Internal.name: entityName,
      index,
      schema: schema->(Utils.magic: S.t<dict<unknown>> => S.t<Internal.entity>),
      table,
      storage,
    }->Internal.fromGenericEntityConfig
  })
}

let publicConfigStorageSchema = S.schema(s =>
  {
    "postgres": s.matches(S.bool),
    "clickhouse": s.matches(S.option(S.bool)),
  }
)

let publicConfigSchema = S.schema(s =>
  {
    "name": s.matches(S.string),
    "description": s.matches(S.option(S.string)),
    "handlers": s.matches(S.option(S.string)),
    "isDev": s.matches(S.option(S.bool)),
    "fullBatchSize": s.matches(S.option(S.int)),
    "rollbackOnReorg": s.matches(S.option(S.bool)),
    "saveFullHistory": s.matches(S.option(S.bool)),
    "rawEvents": s.matches(S.option(S.bool)),
    "storage": s.matches(publicConfigStorageSchema),
    "evm": s.matches(S.option(publicConfigEvmSchema)),
    "fuel": s.matches(S.option(publicConfigEcosystemSchema)),
    "svm": s.matches(S.option(publicConfigEcosystemSchema)),
    "enums": s.matches(S.option(S.dict(S.array(S.string)))),
    "entities": s.matches(S.option(S.array(entityJsonSchema))),
  }
)

let fromPublic = (publicConfigJson: JSON.t) => {
  let maxAddrInPartition = Env.maxAddrInPartition
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

  let logger = Logging.getLogger()
  let ecosystem = switch ecosystemName {
  | Ecosystem.Evm => Evm.make(~logger)
  | Ecosystem.Fuel => Fuel.make(~logger)
  | Ecosystem.Svm => Svm.make(~logger)
  }

  // SVM has no raw-events representation (`Svm.toRawEvent` throws), so reject
  // it at config time instead of failing mid-indexing.
  if ecosystemName === Ecosystem.Svm && publicConfig["rawEvents"]->Option.getOr(false) {
    JsError.throwWithMessage(
      "Invalid indexer config: rawEvents is not supported for the SVM ecosystem",
    )
  }

  // Extract EVM-specific options with defaults
  let lowercaseAddresses = switch publicConfig["evm"] {
  | Some(evm) => evm["addressFormat"]->Option.getOr(Checksum) == Lowercase
  | None => false
  }

  // Parse contract configs (ABIs, events, handlers).
  // SVM stores them under `svm.programs` in the public JSON — the per-program
  // events drive `indexer.onInstruction` registration the same way EVM/Fuel
  // contracts drive `onEvent`.
  let publicContractsConfig = switch (
    ecosystemName,
    publicConfig["evm"],
    publicConfig["fuel"],
    publicConfig["svm"],
  ) {
  | (Ecosystem.Evm, Some(evm), _, _) => evm["contracts"]
  | (Ecosystem.Fuel, _, Some(fuel), _) => fuel["contracts"]
  | (Ecosystem.Svm, _, _, Some(svm)) => svm["programs"]
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

  let contractDataByName: dict<{
    "abi": EvmTypes.Abi.t,
    "eventSignatures": array<string>,
    "events": option<array<_>>,
    "svmAbi": option<{
      "programId": string,
      "definedTypes": JSON.t,
      "source": string,
    }>,
  }> = Dict.make()
  switch publicContractsConfig {
  | Some(contractsDict) =>
    contractsDict
    ->Dict.toArray
    ->Array.forEach(((contractName, contractConfig)) => {
      let capitalizedName = contractName->Utils.String.capitalize
      let abi = contractConfig["abi"]->(Utils.magic: JSON.t => EvmTypes.Abi.t)
      let eventSignatures = switch contractConfig["events"] {
      | Some(events) => events->Array.map(eventItem => eventItem["sighash"])
      | None => []
      }
      let widened =
        contractConfig->(
          Utils.magic: _ => {
            "svmAbi": option<{
              "programId": string,
              "definedTypes": JSON.t,
              "source": string,
            }>,
          }
        )
      contractDataByName->Dict.set(
        capitalizedName,
        {
          "abi": abi,
          "eventSignatures": eventSignatures,
          "events": contractConfig["events"],
          "svmAbi": widened["svmAbi"],
        },
      )
    })
  | None => ()
  }

  // Build event configs for a contract from JSON event items.
  //
  // `~addresses` is the chain-side address list. For SVM programs it's the
  // single base58 program_id — wired onto each instruction's event config so
  // the source can build `(programId, discriminator)`-keyed InstructionSelections.
  // EVM and Fuel ignore it (the address lives in `ChainContract.addresses` and
  // is looked up at dispatch time, not stamped on the event).
  let buildContractEvents = (
    ~contractName,
    ~events: option<array<_>>,
    ~abi,
    ~chainId: int,
    ~addresses: array<string>,
    ~svmDefinedTypes: JSON.t=JSON.Null,
  ) => {
    switch events {
    | None => []
    | Some(eventItems) =>
      eventItems->Array.map(eventItem => {
        let eventName = eventItem["name"]
        let sighash = eventItem["sighash"]
        let params = eventItem["params"]->Option.getOr([])
        let kind = eventItem["kind"]

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
            ) :> Internal.eventConfig)
          | None =>
            JsError.throwWithMessage(
              `Fuel event ${contractName}.${eventName} is missing "kind" in internal config`,
            )
          }
        | Ecosystem.Svm =>
          let programId = switch addresses {
          | [pid] => pid->SvmTypes.Pubkey.fromStringUnsafe
          | [] =>
            JsError.throwWithMessage(
              `SVM program ${contractName} on chain ${chainId->Int.toString} is missing a program_id`,
            )
          | _ =>
            JsError.throwWithMessage(
              `SVM program ${contractName} on chain ${chainId->Int.toString} has multiple addresses; a program is uniquely identified by a single program_id`,
            )
          }
          let widenedEventItem =
            eventItem->(
              Utils.magic: _ => {
                "svm": option<{
                  "discriminator": option<string>,
                  "discriminatorByteLen": int,
                  "transactionFields": array<Internal.svmTransactionField>,
                  "blockFields": option<array<Internal.svmBlockField>>,
                  "includeLogs": bool,
                  "accountFilters": option<
                    array<array<{"position": int, "values": array<string>}>>,
                  >,
                  "isInner": option<bool>,
                  "accounts": option<array<string>>,
                  "args": option<JSON.t>,
                }>,
              }
            )
          let svm = switch widenedEventItem["svm"] {
          | Some(s) => s
          | None =>
            JsError.throwWithMessage(
              `SVM instruction ${contractName}.${eventName} is missing the "svm" descriptor in internal config`,
            )
          }
          let accountFilters =
            svm["accountFilters"]
            ->Option.getOr([])
            ->Array.map(group =>
              group->Array.map(
                af => {
                  Internal.position: af["position"],
                  values: af["values"]->SvmTypes.Pubkey.fromStringsUnsafe,
                },
              )
            )
          (EventConfigBuilder.buildSvmInstructionEventConfig(
            ~contractName,
            ~instructionName=eventName,
            ~programId,
            ~discriminator=svm["discriminator"],
            ~discriminatorByteLen=svm["discriminatorByteLen"],
            ~transactionFields=svm["transactionFields"],
            ~blockFields=?svm["blockFields"],
            ~includeLogs=svm["includeLogs"],
            ~accountFilters,
            ~isInner=svm["isInner"],
            ~accounts=svm["accounts"]->Option.getOr([]),
            ~args=svm["args"]->Option.getOr(JSON.Null),
            ~definedTypes=svmDefinedTypes,
          ) :> Internal.eventConfig)
        | _ =>
          (EventConfigBuilder.buildEvmEventConfig(
            ~contractName,
            ~eventName,
            ~sighash,
            ~params,
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
    | Realtime => Source.Realtime
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
          let rawAddresses =
            chainContract
            ->Option.flatMap(cc => cc["addresses"])
            ->Option.getOr([])
          let addresses = rawAddresses->Array.map(parseAddress)
          let startBlock = chainContract->Option.flatMap(cc => cc["startBlock"])

          // Build event definitions from JSON (field selections resolved
          // inline). Handlers and per-chain `where` filters are layered on
          // later as `onEventRegistration`s in `ChainState.makeInternal`.
          let events = buildContractEvents(
            ~contractName=capitalizedName,
            ~events=contractData["events"],
            ~abi=contractData["abi"],
            ~chainId,
            ~addresses=rawAddresses,
            ~svmDefinedTypes=contractData["svmAbi"]
            ->Option.map(a => a["definedTypes"])
            ->Option.getOr(JSON.Null),
          )

          {
            name: capitalizedName,
            abi: contractData["abi"],
            addresses,
            events,
            startBlock,
          }
        })

      // The same address under two contract definitions (or twice under one)
      // would later violate the (chainId, address) primary key of
      // envio_addresses with an opaque Postgres error — fail fast with the
      // offending pair instead. parseAddress already canonicalizes casing
      // (checksum or lowercase), so an exact match catches case variants too.
      let contractNameByAddress = Dict.make()
      contracts->Array.forEach(contract => {
        contract.addresses->Array.forEach(
          address => {
            let addressString = address->Address.toString
            switch contractNameByAddress->Dict.get(addressString) {
            | Some(existingContractName) =>
              JsError.throwWithMessage(
                existingContractName === contract.name
                  ? `Address ${addressString} is listed multiple times for the contract ${contract.name} on chain ${chainId->Int.toString}. Please remove the duplicate from your config.`
                  : `Address ${addressString} on chain ${chainId->Int.toString} is configured for multiple contracts: ${existingContractName} and ${contract.name}. Indexing the same address with multiple contract definitions is not supported. Please define the events on a single contract definition instead.`,
              )
            | None => contractNameByAddress->Dict.set(addressString, contract.name)
            }
          },
        )
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
              headers: rpcConfig["headers"],
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
        let hypersync = publicChainConfig["hypersync"]
        let rpc = publicChainConfig["rpc"]
        if hypersync->Option.isNone && rpc->Option.isNone {
          JsError.throwWithMessage(
            `Chain ${chainName} is missing a data source: provide either an rpc endpoint or an experimental hypersync config`,
          )
        }
        SvmSourceConfig({hypersync, rpc})
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

  // Parse enums and entities from JSON config
  let allEnums =
    publicConfig["enums"]
    ->Option.getOr(Dict.make())
    ->parseEnumsFromJson

  let enumConfigsByName =
    allEnums->Array.map(enumConfig => (enumConfig.name, enumConfig))->Dict.fromArray

  let globalStorage: storage = {
    postgres: publicConfig["storage"]["postgres"],
    clickhouse: publicConfig["storage"]["clickhouse"]->Option.getOr(false),
  }

  let userEntities =
    publicConfig["entities"]
    ->Option.getOr([])
    ->parseEntitiesFromJson(~enumConfigsByName, ~globalStorage)

  let allEntities = userEntities->Array.concat([EnvioAddresses.entityConfig])

  // Keyed by the capitalized entity name to match the handler-context
  // accessor (`context.Pool_snapshots`) the generated types expose, while
  // entityConfig.name stays the original schema name used for the physical
  // Postgres/ClickHouse tables.
  let userEntitiesByName =
    userEntities
    ->Array.map(entityConfig => {
      (entityConfig.name->Utils.String.capitalize, entityConfig)
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
    storage: globalStorage,
    chainMap,
    defaultChain: chains->Array.get(0),
    enableRawEvents: publicConfig["rawEvents"]->Option.getOr(false),
    ecosystem,
    maxAddrInPartition,
    clientFilterAddressThreshold: Env.clientFilterAddressThreshold,
    batchSize: publicConfig["fullBatchSize"]->Option.getOr(5000),
    reorgThresholdReadyTolerance: 100,
    lowercaseAddresses,
    isDev: publicConfig["isDev"]->Option.getOr(false),
    userEntitiesByName,
    userEntities,
    allEntities,
    allEnums,
  }
}

// Canonicalize a user-provided address to the configured casing so it matches
// addresses parsed from config.yaml during routing. HyperSync/RPC data arrives
// already canonical; only user-land input (simulate srcAddress, contractRegister
// add) can carry arbitrary casing and needs this before comparison.
let normalizeUserAddress = (config: t, address: Address.t): Address.t =>
  switch config.ecosystem.name {
  | Ecosystem.Evm =>
    if config.lowercaseAddresses {
      address->Address.Evm.fromAddressLowercaseOrThrow
    } else {
      address->Address.Evm.fromAddressOrThrow
    }
  // TODO: Ideally we should do the same for other ecosystems
  | Ecosystem.Fuel | Ecosystem.Svm => address
  }

// Relaxed counterpart to normalizeUserAddress, used only for simulate srcAddress.
// Tests commonly use short placeholder strings like "0xfoo" as a stand-in
// identity (e.g. for a wildcard event whose srcAddress doesn't need to resolve
// to any real contract), so only the "0x" prefix is enforced here. Under
// address_format: checksum, a real address is checksummed even if the input
// casing doesn't match (getAddress doesn't require the input to already be
// checksummed) — a placeholder that isn't valid hex falls back unchanged.
let normalizeSimulateAddress = (config: t, address: Address.t): Address.t =>
  switch config.ecosystem.name {
  | Ecosystem.Evm =>
    let str = address->Address.toString
    if !(str->String.startsWith("0x")) {
      JsError.throwWithMessage(
        `simulate: srcAddress "${str}" is invalid. Expected a string starting with "0x".`,
      )
    }
    if config.lowercaseAddresses {
      address->Address.Evm.fromAddressLowercaseOrThrow
    } else {
      try {
        address->Address.Evm.fromAddressOrThrow
      } catch {
      | _ => address
      }
    }
  | Ecosystem.Fuel | Ecosystem.Svm => address
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
      ->Option.flatMap(contract => contract.events->Array.find(e => e.name == eventName))
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

// A CLI command payload already contains the resolved JSON; priming lets
// downstream callers skip the NAPI `getConfigJson` round-trip. Calling
// `prime` again invalidates the memo.
%%private(let primedJson: ref<option<JSON.t>> = ref(None))
%%private(let cached: ref<option<t>> = ref(None))
let prime = (json: JSON.t): unit => {
  primedJson := Some(json)
  cached := None
}

let getPublicConfigJson = () =>
  switch primedJson.contents {
  | Some(json) => json
  | None => Core.getConfigJson()->JSON.parseOrThrow
  }

// Drops source URLs from each chain so RPC/hypersync edits don't trigger
// the resume-time compat check (and don't end up in `envio_info`). Also
// drops `isDev`, which toggles between `envio dev` and `envio start` and
// has no bearing on schema/indexing compatibility.
let stripSensitiveData = (json: JSON.t): JSON.t => {
  let cloned = json->JSON.stringify->JSON.parseOrThrow
  let stripChains = (ecosystem: option<JSON.t>) =>
    switch ecosystem {
    | Some(Object(ecosystemDict)) =>
      switch ecosystemDict->Dict.get("chains") {
      | Some(Object(chains)) =>
        chains
        ->Dict.valuesToArray
        ->Array.forEach(chainJson =>
          switch chainJson {
          | Object(chain) => {
              chain->Utils.Dict.deleteInPlace("rpcs")
              chain->Utils.Dict.deleteInPlace("rpc")
              chain->Utils.Dict.deleteInPlace("hypersync")
            }
          | _ => ()
          }
        )
      | _ => ()
      }
    | _ => ()
    }
  switch cloned {
  | Object(obj) => {
      obj->Utils.Dict.deleteInPlace("isDev")
      stripChains(obj->Dict.get("evm"))
      stripChains(obj->Dict.get("fuel"))
      stripChains(obj->Dict.get("svm"))
    }
  | _ => ()
  }
  cloned
}

// Postgres jsonb doesn't preserve key order, so canonicalize with sorted
// keys before string-comparing.
let rec canonicalJson = (json: JSON.t): JSON.t =>
  switch json {
  | Object(d) => {
      let sorted = Dict.make()
      d
      ->Dict.keysToArray
      ->Array.toSorted(String.compare)
      ->Array.forEach(k => sorted->Dict.set(k, d->Dict.getUnsafe(k)->canonicalJson))
      Object(sorted)
    }
  | Array(arr) => Array(arr->Array.map(canonicalJson))
  | _ => json
  }

// Returns dotted leaf paths (`a.b[i].c`) where `stored` differs from
// `current`, restricted to the highest-priority top-level tier with any
// diff. Tiers in order: version → name → storage → ecosystem
// (evm/fuel/svm) → entities → other top-level keys. The first tier
// containing a diff is the only one rendered; lower tiers are silenced
// so a single noisy section doesn't bury the actionable change.
let diffPaths = (~stored: JSON.t, ~current: JSON.t): array<string> => {
  let canonEq = (a: JSON.t, b: JSON.t) =>
    JSON.stringify(canonicalJson(a)) === JSON.stringify(canonicalJson(b))

  let acc = []
  let rec go = (s: JSON.t, c: JSON.t, prefix: string) => {
    if canonEq(s, c) {
      ()
    } else {
      switch (s, c) {
      | (Object(sObj), Object(cObj)) =>
        let keys = Utils.Set.fromArray(Array.concat(sObj->Dict.keysToArray, cObj->Dict.keysToArray))
        keys
        ->Utils.Set.toArray
        ->Array.toSorted(String.compare)
        ->Array.forEach(k => {
          let p = prefix === "" ? k : `${prefix}.${k}`
          switch (sObj->Dict.get(k), cObj->Dict.get(k)) {
          | (None, None) => ()
          | (None, _) | (_, None) => acc->Array.push(p)->ignore
          | (Some(sv), Some(cv)) => go(sv, cv, p)
          }
        })
      | (Array(sArr), Array(cArr)) =>
        let maxLen = Math.Int.max(sArr->Array.length, cArr->Array.length)
        for i in 0 to maxLen - 1 {
          let p = `${prefix}[${Int.toString(i)}]`
          switch (sArr->Array.get(i), cArr->Array.get(i)) {
          | (None, _) | (_, None) => acc->Array.push(p)->ignore
          | (Some(sv), Some(cv)) => go(sv, cv, p)
          }
        }
      | _ => acc->Array.push(prefix === "" ? "<root>" : prefix)->ignore
      }
    }
  }

  let getTopKey = (j: JSON.t, k: string) =>
    switch j {
    | Object(d) => d->Dict.get(k)
    | _ => None
    }
  let topKeyDiffers = (k: string) =>
    switch (getTopKey(stored, k), getTopKey(current, k)) {
    | (None, None) => false
    | (None, _) | (_, None) => true
    | (Some(s), Some(c)) => !canonEq(s, c)
    }
  let runTier = (keys: array<string>) =>
    keys->Array.forEach(k =>
      switch (getTopKey(stored, k), getTopKey(current, k)) {
      | (None, None) => ()
      | (None, _) | (_, None) => acc->Array.push(k)->ignore
      | (Some(s), Some(c)) => go(s, c, k)
      }
    )

  switch (stored, current) {
  | (Object(sObj), Object(cObj)) =>
    let tiers = [["version"], ["name"], ["storage"], ["evm", "fuel", "svm"], ["entities"]]
    let firstHit = tiers->Array.reduce(None, (acc, tier) =>
      switch acc {
      | Some(_) => acc
      | None =>
        switch tier->Array.filter(topKeyDiffers) {
        | [] => None
        | hits => Some(hits)
        }
      }
    )
    switch firstHit {
    | Some(hits) => runTier(hits)
    | None =>
      let knownSet = Utils.Set.fromArray(tiers->Array.flat)
      let extras =
        Utils.Set.fromArray(Array.concat(sObj->Dict.keysToArray, cObj->Dict.keysToArray))
        ->Utils.Set.toArray
        ->Array.filter(k => !(knownSet->Utils.Set.has(k)))
        ->Array.toSorted(String.compare)
        ->Array.filter(topKeyDiffers)
      runTier(extras)
    }
  | _ => go(stored, current, "")
  }
  acc
}

// Throws an `incompatible config` error listing each path in `changedPaths`,
// plus the remediation options. `~resetCommand` is rendered as-is for
// option 2 (the wipe-and-redo). `~runCommand` controls option 3 (parallel
// indexer recipe): when `None`, option 3 is omitted — the migrate flow
// uses this because running a second indexer doesn't apply.
// `~hasClickhouse` adds the extra env line so users running both
// Postgres and Clickhouse get a complete override.
let throwIfIncompatible = (
  changedPaths: array<string>,
  ~resetCommand: string,
  ~runCommand: option<string>,
  ~hasClickhouse: bool,
) => {
  if changedPaths->Array.length > 0 {
    let bullets = changedPaths->Array.map(p => `    - ${p}`)->Array.joinUnsafe("\n")
    let option1 = "Revert the changes above"
    let padTo = (s, col) => s ++ " "->String.repeat(Math.Int.max(col - String.length(s), 1))
    let col = Math.Int.max(String.length(option1), String.length(resetCommand)) + 2
    let option3 = switch runCommand {
    | None => ""
    | Some(cmd) =>
      let clickhouseLine = hasClickhouse ? "       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\\n" : ""
      `\n  3. Run a second indexer alongside this one — keep both datasets:\n       ENVIO_PG_SCHEMA=<new_schema> \\\n${clickhouseLine}       ENVIO_INDEXER_PORT=<new_port> \\\n       ${cmd}`
    }
    JsError.throwWithMessage(
      `The following config changes are incompatible with the existing indexer data:\n\n${bullets}\n\nPick one:\n  1. ${option1->padTo(
          col,
        )}# resume indexing where it left off\n  2. ${resetCommand->padTo(
          col,
        )}# delete all indexed data and start over${option3}`,
    )
  }
}

// The returned value is a pure function of the JSON: it holds only event
// definitions, never handler/contractRegister/where state (that's layered on
// separately as `HandlerRegister.registrationsByChainId`). That purity is
// what lets this memoize without invalidation.
let load = () =>
  switch cached.contents {
  | Some(c) => c
  | None => {
      let c = getPublicConfigJson()->fromPublic
      cached := Some(c)
      c
    }
  }

let getPgUserEntities = (config: t) => config.userEntities->Array.filter(e => e.storage.postgres)
