let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let getEventConfig = (~config=?, ~contractName, ~eventName, ~chainId=?) => {
  let config = switch config {
  | Some(c) => c
  | None => Config.loadWithoutRegistrations()
  }
  config
  ->Config.getEventConfig(~contractName, ~eventName, ~chainId?)
  ->Option.getOrThrow
}

let getEvmEventConfig = (~config=?, ~contractName, ~eventName, ~chainId=?) =>
  getEventConfig(~config?, ~contractName, ~eventName, ~chainId?)->(
    Utils.magic: Internal.eventConfig => Internal.evmEventConfig
  )

// Build the per-(event, chain) registration from the event definition + the
// registered handlers, mirroring `ChainState.makeInternal`. Handlers must have
// been registered (`HandlerLoader.registerAllHandlers`) before calling.
let getOnEventRegistration = (~config=?, ~contractName, ~eventName, ~chainId=?) => {
  let config = switch config {
  | Some(c) => c
  | None => Config.loadWithoutRegistrations()
  }
  let eventConfig = getEventConfig(~config, ~contractName, ~eventName, ~chainId?)
  let probeChainId = switch chainId {
  | Some(id) => id
  | None => config.chainMap->ChainMap.values->Array.get(0)->Option.mapOr(0, c => c.id)
  }
  let isWildcard = HandlerRegister.isWildcard(~contractName, ~eventName)
  let handler = HandlerRegister.getHandler(~contractName, ~eventName)
  let contractRegister = HandlerRegister.getContractRegister(~contractName, ~eventName)
  switch config.ecosystem.name {
  | Evm =>
    (EventConfigBuilder.buildEvmOnEventRegistration(
      ~eventConfig=eventConfig->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig),
      ~isWildcard,
      ~handler,
      ~contractRegister,
      ~eventFilters=HandlerRegister.getOnEventWhere(~contractName, ~eventName),
      ~probeChainId,
      ~onEventBlockFilterSchema=config.ecosystem.onEventBlockFilterSchema,
    ) :> Internal.onEventRegistration)
  | Fuel =>
    (EventConfigBuilder.buildFuelOnEventRegistration(
      ~eventConfig=eventConfig->(Utils.magic: Internal.eventConfig => Internal.fuelEventConfig),
      ~isWildcard,
      ~handler,
      ~contractRegister,
    ) :> Internal.onEventRegistration)
  | Svm =>
    (EventConfigBuilder.buildSvmOnEventRegistration(
      ~eventConfig=eventConfig->(
        Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig
      ),
      ~isWildcard,
      ~handler,
      ~contractRegister,
    ) :> Internal.onEventRegistration)
  }
}

let getEvmOnEventRegistration = (~config=?, ~contractName, ~eventName, ~chainId=?) =>
  getOnEventRegistration(~config?, ~contractName, ~eventName, ~chainId?)->(
    Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration
  )
