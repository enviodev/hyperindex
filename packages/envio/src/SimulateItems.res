open Belt

type simulateEventItem = {
  contract: string,
  event: string,
  params: option<Js.Json.t>,
  srcAddress: option<Address.t>,
  logIndex: option<int>,
  number: option<int>,
  block: option<Js.Json.t>,
  transaction: option<Js.Json.t>,
}

type simulateBlockItem = {
  block: string,
  number: option<int>,
}

// Raw JSON item from user - discriminated by presence of "contract"+"event" vs "block" keys
type rawSimulateItem

@get external getContract: rawSimulateItem => option<string> = "contract"
@get external getEvent: rawSimulateItem => option<string> = "event"
@get external getBlock: rawSimulateItem => option<string> = "block"

let findEventConfig = (~config: Config.t, ~contractName: string, ~eventName: string) => {
  let found = ref(None)
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig => {
    chainConfig.contracts->Array.forEach(contract => {
      if contract.name === contractName {
        contract.events->Array.forEach(eventConfig => {
          if eventConfig.name === eventName {
            found := Some(eventConfig)
          }
        })
      }
    })
  })
  found.contents
}

let parse = (
  ~simulateItems: array<Js.Json.t>,
  ~config: Config.t,
  ~chainConfig: Config.chain,
  ~registrations: HandlerRegister.registrations,
): array<Internal.item> => {
  let chain = ChainMap.Chain.makeUnsafe(~chainId=chainConfig.id)
  let chainId = chainConfig.id
  let startBlock = chainConfig.startBlock
  let currentBlock = ref(startBlock)
  let currentLogIndex = ref(0)

  let items = []

  simulateItems->Array.forEach(rawJson => {
    let raw = rawJson->(Utils.magic: Js.Json.t => rawSimulateItem)

    switch (raw->getContract, raw->getEvent, raw->getBlock) {
    | (Some(contractName), Some(eventName), _) =>
      // Event simulate item
      let eventConfig = switch findEventConfig(~config, ~contractName, ~eventName) {
      | Some(ec) => ec
      | None =>
        Js.Exn.raiseError(
          `simulate: Event "${eventName}" not found on contract "${contractName}". ` ++
          `Check that the contract and event names match your config.yaml.`,
        )
      }

      let item = rawJson->(Utils.magic: Js.Json.t => simulateEventItem)

      // Parse params using the event's schema
      let params = switch item.params {
      | Some(paramsJson) => paramsJson->S.parseOrThrow(eventConfig.paramsRawEventSchema)
      | None => Js.Dict.empty()->(Utils.magic: dict<unit> => Internal.eventParams)
      }

      let blockNumber = switch item.number {
      | Some(n) => n
      | None => currentBlock.contents
      }
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

      // Build block and transaction as empty objects with optional overrides
      let block = switch item.block {
      | Some(b) => b->(Utils.magic: Js.Json.t => Internal.eventBlock)
      | None =>
        {"number": blockNumber, "timestamp": 0}->(
          Utils.magic: {"number": int, "timestamp": int} => Internal.eventBlock
        )
      }

      let transaction = switch item.transaction {
      | Some(t) => t->(Utils.magic: Js.Json.t => Internal.eventTransaction)
      | None => Js.Dict.empty()->(Utils.magic: dict<unit> => Internal.eventTransaction)
      }

      items
      ->Array.push(
        Internal.Event({
          eventConfig,
          timestamp: 0,
          chain,
          blockNumber,
          logIndex,
          event: {
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

    | (_, _, Some(blockHandlerName)) =>
      // Block simulate item
      let item = rawJson->(Utils.magic: Js.Json.t => simulateBlockItem)

      let chainIdStr = chainId->Int.toString
      let onBlockConfigs =
        registrations.onBlockByChainId
        ->Utils.Dict.dangerouslyGetNonOption(chainIdStr)
        ->Option.getWithDefault([])

      let onBlockConfig = switch onBlockConfigs->Array.getBy(c => c.name === blockHandlerName) {
      | Some(c) => c
      | None =>
        let availableNames =
          onBlockConfigs->Array.map(c => `"${c.name}"`)
        Js.Exn.raiseError(
          `simulate: Block handler "${blockHandlerName}" not found for chain ${chainIdStr}. ` ++
          `Available block handlers: [${availableNames->Js.Array2.joinWith(", ")}]`,
        )
      }

      let blockNumber = switch item.number {
      | Some(n) => n
      | None => currentBlock.contents
      }

      items
      ->Array.push(
        Internal.Block({
          onBlockConfig,
          blockNumber,
          logIndex: onBlockConfig.index,
        }),
      )
      ->ignore

    | _ =>
      Js.Exn.raiseError(
        `simulate: Invalid item. Each item must have either "contract" + "event" fields (for events) or a "block" field (for block handlers).`,
      )
    }
  })

  items
}

// Apply simulate source config from processConfig JSON to a Config.t
// This patches chainMap entries that have simulate items with CustomSources
let patchConfig = (
  ~config: Config.t,
  ~processConfig: Js.Json.t,
  ~registrations: HandlerRegister.registrations,
): Config.t => {
  let processChains: option<Js.Dict.t<Js.Json.t>> =
    (processConfig->(Utils.magic: Js.Json.t => {..}))["chains"]
    ->Js.Nullable.toOption
  switch processChains {
  | Some(chainsDict) =>
    let newChainMap = config.chainMap->ChainMap.mapWithKey((chain, chainConfig) => {
      let chainIdStr = chain->ChainMap.Chain.toChainId->Int.toString
      switch chainsDict->Js.Dict.get(chainIdStr) {
      | Some(processChainJson) =>
        let simulateRaw: option<array<Js.Json.t>> =
          (processChainJson->(Utils.magic: Js.Json.t => {..}))["simulate"]
          ->Js.Nullable.toOption
        switch simulateRaw {
        | Some(simulateItems) =>
          let items = parse(
            ~simulateItems,
            ~config,
            ~chainConfig,
            ~registrations,
          )
          // Use endBlock from processConfig (the user-specified range)
          let endBlock: int =
            (processChainJson->(Utils.magic: Js.Json.t => {..}))["endBlock"]
            ->(Utils.magic: 'a => int)
          let source = SimulateSource.make(~items, ~endBlock, ~chain)
          {...chainConfig, sourceConfig: Config.CustomSources([source])}
        | None => chainConfig
        }
      | None => chainConfig
      }
    })
    {...config, chainMap: newChainMap}
  | None => config
  }
}
