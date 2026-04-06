open Belt

// EVM simulate block schema — all fields present with defaults for non-nullable ones.
// Nullable fields (from Internal.evmNullableBlockFields) use S.null → option<T>.
let evmSimulateBlockSchema = S.schema(s =>
  {
    // Non-nullable fields with defaults
    "number": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "timestamp": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "hash": s.matches(S.null(S.string)->S.Option.getOr("")),
    "parentHash": s.matches(S.null(S.string)->S.Option.getOr("")),
    "sha3Uncles": s.matches(S.null(S.string)->S.Option.getOr("")),
    "logsBloom": s.matches(S.null(S.string)->S.Option.getOr("")),
    "transactionsRoot": s.matches(S.null(S.string)->S.Option.getOr("")),
    "stateRoot": s.matches(S.null(S.string)->S.Option.getOr("")),
    "receiptsRoot": s.matches(S.null(S.string)->S.Option.getOr("")),
    "miner": s.matches(
      S.null(Address.schema)->S.Option.getOr(
        Address.unsafeFromString("0x0000000000000000000000000000000000000000"),
      ),
    ),
    "extraData": s.matches(S.null(S.string)->S.Option.getOr("")),
    "size": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "gasLimit": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "gasUsed": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    // Nullable fields
    "nonce": s.matches(S.null(S.bigint)),
    "difficulty": s.matches(S.null(S.bigint)),
    "totalDifficulty": s.matches(S.null(S.bigint)),
    "uncles": s.matches(S.null(S.array(S.string))),
    "baseFeePerGas": s.matches(S.null(S.bigint)),
    "blobGasUsed": s.matches(S.null(S.bigint)),
    "excessBlobGas": s.matches(S.null(S.bigint)),
    "parentBeaconBlockRoot": s.matches(S.null(S.string)),
    "withdrawalsRoot": s.matches(S.null(S.string)),
    "l1BlockNumber": s.matches(S.null(S.int)),
    "sendCount": s.matches(S.null(S.string)),
    "sendRoot": s.matches(S.null(S.string)),
    "mixHash": s.matches(S.null(S.string)),
  }
)

type evmSimulateBlock = {number: int, timestamp: int}

let parseEvmSimulateBlock = (
  ~defaultBlockNumber: int,
  ~blockJson: option<Js.Json.t>,
): Internal.eventBlock => {
  let block = switch blockJson {
  | Some(json) => json->S.convertOrThrow(evmSimulateBlockSchema)
  | None =>
    Js.Dict.empty()
    ->(Utils.magic: dict<unit> => Js.Json.t)
    ->S.convertOrThrow(evmSimulateBlockSchema)
  }
  let block = block->(Utils.magic: _ => Internal.eventBlock)
  let blockFields = block->(Utils.magic: Internal.eventBlock => evmSimulateBlock)

  // Only set block number when user didn't provide one (schema defaults to 0)
  if blockJson->Option.isNone || blockFields.number === 0 {
    let blockDict = block->(Utils.magic: Internal.eventBlock => Js.Dict.t<unknown>)
    blockDict->Js.Dict.set("number", defaultBlockNumber->(Utils.magic: int => unknown))
  }
  block
}

// EVM simulate transaction schema — all fields present with defaults for non-nullable ones.
let evmSimulateTransactionSchema = S.schema(s =>
  {
    // Non-nullable fields with defaults
    "transactionIndex": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "hash": s.matches(S.null(S.string)->S.Option.getOr("")),
    "gas": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "input": s.matches(S.null(S.string)->S.Option.getOr("")),
    "nonce": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "value": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "cumulativeGasUsed": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "effectiveGasPrice": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "gasUsed": s.matches(S.null(S.bigint)->S.Option.getOr(0n)),
    "logsBloom": s.matches(S.null(S.string)->S.Option.getOr("")),
    "accessList": s.matches(S.null(S.json(~validate=false))->S.Option.getOr(Js.Json.null)),
    // Signature fields
    "v": s.matches(S.null(S.string)),
    "r": s.matches(S.null(S.string)),
    "s": s.matches(S.null(S.string)),
    "yParity": s.matches(S.null(S.string)),
    // Nullable address fields
    "from": s.matches(S.null(Address.schema)),
    "to": s.matches(S.null(Address.schema)),
    "contractAddress": s.matches(S.null(S.string)),
    // Nullable fields
    "gasPrice": s.matches(S.null(S.bigint)),
    "maxPriorityFeePerGas": s.matches(S.null(S.bigint)),
    "maxFeePerGas": s.matches(S.null(S.bigint)),
    "maxFeePerBlobGas": s.matches(S.null(S.bigint)),
    "blobVersionedHashes": s.matches(S.null(S.array(S.string))),
    "root": s.matches(S.null(S.string)),
    "status": s.matches(S.null(S.int)),
    "type": s.matches(S.null(S.int)),
    // L2 fields
    "l1Fee": s.matches(S.null(S.bigint)),
    "l1GasPrice": s.matches(S.null(S.bigint)),
    "l1GasUsed": s.matches(S.null(S.bigint)),
    "l1FeeScalar": s.matches(S.null(S.float)),
    "gasUsedForL1": s.matches(S.null(S.bigint)),
    "authorizationList": s.matches(S.null(S.json(~validate=false))),
  }
)

let parseEvmSimulateTransaction = (
  ~transactionJson: option<Js.Json.t>,
): Internal.eventTransaction => {
  let transaction = switch transactionJson {
  | Some(json) => json->S.convertOrThrow(evmSimulateTransactionSchema)
  | None =>
    Js.Dict.empty()
    ->(Utils.magic: dict<unit> => Js.Json.t)
    ->S.convertOrThrow(evmSimulateTransactionSchema)
  }
  transaction->(Utils.magic: _ => Internal.eventTransaction)
}

// Fuel simulate block schema — fields: id, height, time
let fuelSimulateBlockSchema = S.schema(s =>
  {
    "id": s.matches(S.null(S.string)->S.Option.getOr("")),
    "height": s.matches(S.null(S.int)->S.Option.getOr(0)),
    "time": s.matches(S.null(S.int)->S.Option.getOr(0)),
  }
)

type fuelSimulateBlock = {height: int, time: int}

let parseFuelSimulateBlock = (
  ~defaultBlockNumber: int,
  ~blockJson: option<Js.Json.t>,
): Internal.eventBlock => {
  let block = switch blockJson {
  | Some(json) => json->S.convertOrThrow(fuelSimulateBlockSchema)
  | None =>
    Js.Dict.empty()
    ->(Utils.magic: dict<unit> => Js.Json.t)
    ->S.convertOrThrow(fuelSimulateBlockSchema)
  }
  let block = block->(Utils.magic: _ => Internal.eventBlock)
  let blockFields = block->(Utils.magic: Internal.eventBlock => fuelSimulateBlock)

  // Only set block height when user didn't provide one (schema defaults to 0)
  if blockJson->Option.isNone || blockFields.height === 0 {
    let blockDict = block->(Utils.magic: Internal.eventBlock => Js.Dict.t<unknown>)
    blockDict->Js.Dict.set("height", defaultBlockNumber->(Utils.magic: int => unknown))
  }
  block
}

// Fuel simulate transaction schema — fields: id
let fuelSimulateTransactionSchema = S.schema(s =>
  {
    "id": s.matches(S.null(S.string)->S.Option.getOr("")),
  }
)

let parseFuelSimulateTransaction = (
  ~transactionJson: option<Js.Json.t>,
): Internal.eventTransaction => {
  let transaction = switch transactionJson {
  | Some(json) => json->S.convertOrThrow(fuelSimulateTransactionSchema)
  | None =>
    Js.Dict.empty()
    ->(Utils.magic: dict<unit> => Js.Json.t)
    ->S.convertOrThrow(fuelSimulateTransactionSchema)
  }
  transaction->(Utils.magic: _ => Internal.eventTransaction)
}

// Raw JSON item from user - discriminated by presence of "contract"+"event" keys
type rawSimulateItem

@get external getContract: rawSimulateItem => option<string> = "contract"
@get external getEvent: rawSimulateItem => option<string> = "event"

let findEventConfig = (~config: Config.t, ~contractName: string, ~eventName: string) => {
  let found = ref(None)
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      if contract.name === contractName {
        contract.events->Array.forEach(
          eventConfig => {
            if eventConfig.name === eventName {
              found := Some(eventConfig)
            }
          },
        )
      }
    })
  })
  found.contents
}

let parse = (
  ~simulateItems: array<Js.Json.t>,
  ~config: Config.t,
  ~chainConfig: Config.chain,
): array<Internal.item> => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
  let chainId = chainConfig.id
  let startBlock = chainConfig.startBlock
  let currentBlock = ref(startBlock)
  let currentLogIndex = ref(0)

  let items = []

  simulateItems->Array.forEach(rawJson => {
    let raw = rawJson->(Utils.magic: Js.Json.t => rawSimulateItem)

    switch (raw->getContract, raw->getEvent) {
    | (Some(contractName), Some(eventName)) =>
      // Event simulate item
      let eventConfig = switch findEventConfig(~config, ~contractName, ~eventName) {
      | Some(ec) => ec
      | None =>
        Js.Exn.raiseError(
          `simulate: Event "${eventName}" not found on contract "${contractName}". ` ++ `Check that the contract and event names match your config.yaml.`,
        )
      }

      // Parse event item fields
      let item = rawJson->(Utils.magic: Js.Json.t => Envio.evmSimulateItem)

      // Parse params using the simulate schema — fills missing fields with defaults
      let paramsJson: Js.Json.t = switch item.params {
      | Some(json) => json
      | None => Js.Dict.empty()->(Utils.magic: dict<unit> => Js.Json.t)
      }
      let params = paramsJson->S.convertOrThrow(eventConfig.simulateParamsSchema)

      let logIndex = switch item.logIndex {
      | Some(li) => li
      | None =>
        let li = currentLogIndex.contents
        currentLogIndex := li + 1
        li
      }

      let srcAddress = switch item.srcAddress {
      | Some(addr) => addr
      | None =>
        // Use first address from contract config
        let addr = ref(Address.unsafeFromString("0x0000000000000000000000000000000000000000"))
        chainConfig.contracts->Array.forEach(contract => {
          if contract.name === contractName {
            switch contract.addresses->Array.get(0) {
            | Some(a) => addr := a
            | None => ()
            }
          }
        })
        addr.contents
      }

      let rawItem = rawJson->(Utils.magic: Js.Json.t => {..})
      let blockJson: option<Js.Json.t> =
        rawItem["block"]->(Utils.magic: 'a => Js.Nullable.t<Js.Json.t>)->Js.Nullable.toOption
      let transactionJson: option<Js.Json.t> =
        rawItem["transaction"]->(Utils.magic: 'a => Js.Nullable.t<Js.Json.t>)->Js.Nullable.toOption
      let (block, blockNumber, timestamp) = switch config.ecosystem.name {
      | Fuel =>
        let block = parseFuelSimulateBlock(~defaultBlockNumber=currentBlock.contents, ~blockJson)
        let blockFields = block->(Utils.magic: Internal.eventBlock => fuelSimulateBlock)
        (block, blockFields.height, blockFields.time)
      | Evm =>
        let block = parseEvmSimulateBlock(~defaultBlockNumber=currentBlock.contents, ~blockJson)
        let blockFields = block->(Utils.magic: Internal.eventBlock => evmSimulateBlock)
        (block, blockFields.number, blockFields.timestamp)
      | Svm => Js.Exn.raiseError("simulate is not supported for SVM ecosystem")
      }
      let transaction = switch config.ecosystem.name {
      | Fuel => parseFuelSimulateTransaction(~transactionJson)
      | Evm => parseEvmSimulateTransaction(~transactionJson)
      | Svm => Js.Exn.raiseError("simulate is not supported for SVM ecosystem")
      }

      // Update currentBlock for subsequent items
      currentBlock := blockNumber

      items
      ->Array.push(
        Internal.Event({
          eventConfig,
          timestamp,
          chain,
          blockNumber,
          logIndex,
          event: {
            contractName: eventConfig.contractName,
            eventName: eventConfig.name,
            params,
            chainId,
            srcAddress,
            logIndex,
            transaction,
            block,
          }->Internal.fromGenericEvent,
        }),
      )
      ->ignore

    | _ =>
      Js.Exn.raiseError(`simulate: Invalid item. Each item must have "contract" and "event" fields.`)
    }
  })

  items
}

// Apply simulate source config from processConfig JSON to a Config.t
// This patches chainMap entries that have simulate items with CustomSources
let patchConfig = (~config: Config.t, ~processConfig: Js.Json.t): Config.t => {
  let processChains: option<Js.Dict.t<Js.Json.t>> =
    (processConfig->(Utils.magic: Js.Json.t => {..}))["chains"]->Js.Nullable.toOption
  switch processChains {
  | Some(chainsDict) =>
    let newChainMap = config.chainMap->ChainMap.mapWithKey((chain, chainConfig) => {
      let chainIdStr = chain->ChainMap.Chain.toChainId->Int.toString
      switch chainsDict->Js.Dict.get(chainIdStr) {
      | Some(processChainJson) =>
        let simulateRaw: option<array<Js.Json.t>> =
          (processChainJson->(Utils.magic: Js.Json.t => {..}))["simulate"]->Js.Nullable.toOption
        switch simulateRaw {
        | Some(simulateItems) =>
          let items = parse(~simulateItems, ~config, ~chainConfig)
          // Use endBlock from processConfig (the user-specified range)
          let startBlock: int =
            (processChainJson->(Utils.magic: Js.Json.t => {..}))["startBlock"]->(
              Utils.magic: 'a => int
            )
          let endBlock: int =
            (processChainJson->(Utils.magic: Js.Json.t => {..}))["endBlock"]->(
              Utils.magic: 'a => int
            )
          let source = SimulateSource.make(~items, ~endBlock, ~chain)
          {...chainConfig, startBlock, endBlock, sourceConfig: Config.CustomSources([source])}
        | None => chainConfig
        }
      | None => chainConfig
      }
    })
    {...config, chainMap: newChainMap}
  | None => config
  }
}
