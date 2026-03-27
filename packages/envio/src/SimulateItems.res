open Belt

type evmSimulateEventItem = {
  contract: string,
  event: string,
  params?: Js.Json.t,
  srcAddress?: Address.t,
  logIndex?: int,
  block?: Js.Json.t,
  transaction?: Js.Json.t,
}

// Codegen-facing type for constructing simulate items (all fields optional)
type simulateItem = {
  event?: string,
  contract?: string,
  params?: Js.Json.t,
  srcAddress?: Address.t,
  logIndex?: int,
  block?: Js.Json.t,
  transaction?: Js.Json.t,
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

      // Parse event item fields (both ecosystem types have the same optional fields now)
      let item = rawJson->(Utils.magic: Js.Json.t => evmSimulateEventItem)

      // Parse params using the event's schema
      // Use undefined for events with no params (e.g. EmptyEvent()) to match codegen behavior
      let params = switch item.params {
      | Some(paramsJson) => paramsJson->S.parseOrThrow(eventConfig.paramsRawEventSchema)
      | None => %raw(`undefined`)->(Utils.magic: 'a => Internal.eventParams)
      }

      let blockNumber = currentBlock.contents
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
        let blockDict = Js.Dict.empty()
        blockDict->Js.Dict.set(
          config.ecosystem.blockNumberName,
          blockNumber->(Utils.magic: int => unknown),
        )
        blockDict->Js.Dict.set(
          config.ecosystem.blockTimestampName,
          0->(Utils.magic: int => unknown),
        )
        blockDict->(Utils.magic: Js.Dict.t<unknown> => Internal.eventBlock)
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
          let endBlock: int =
            (processChainJson->(Utils.magic: Js.Json.t => {..}))["endBlock"]->(
              Utils.magic: 'a => int
            )
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
