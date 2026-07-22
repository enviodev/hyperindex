let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let getEventConfig = (~config=?, ~contractName, ~eventName, ~chainId=?) => {
  let config = switch config {
  | Some(c) => c
  | None => Config.load()
  }
  config
  ->Config.getEventConfig(~contractName, ~eventName, ~chainId?)
  ->Option.getOrThrow
}

let getEvmEventConfig = (~config=?, ~contractName, ~eventName, ~chainId=?) =>
  getEventConfig(~config?, ~contractName, ~eventName, ~chainId?)->(
    Utils.magic: Internal.eventConfig => Internal.evmEventConfig
  )

// The first per-(event, chain) registration built from the event definition +
// the registered handlers. Handlers must have been registered
// (`HandlerLoader.registerAllHandlers`) before calling; falls back to a bare
// registration when the event has none.
let getOnEventRegistration = (~config=?, ~contractName, ~eventName, ~chainId=?) => {
  let config = switch config {
  | Some(c) => c
  | None => Config.load()
  }
  let eventConfig = getEventConfig(~config, ~contractName, ~eventName, ~chainId?)
  let probeChainId = switch chainId {
  | Some(id) => id
  | None => config.chainMap->ChainMap.values->Array.get(0)->Option.mapOr(0, c => c.id)
  }
  HandlerRegister.getSimulateOnEventRegistrations(~config, ~chainId=probeChainId, ~eventConfig)
  ->Array.get(0)
  ->Option.getOrThrow
}

let getEvmOnEventRegistration = (~config=?, ~contractName, ~eventName, ~chainId=?) =>
  getOnEventRegistration(~config?, ~contractName, ~eventName, ~chainId?)->(
    Utils.magic: Internal.onEventRegistration => Internal.evmOnEventRegistration
  )
