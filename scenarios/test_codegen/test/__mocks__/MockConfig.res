let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let getEventConfig = (~contractName, ~eventName) =>
  Indexer.Generated.configWithoutRegistrations
  ->Config.getEventConfig(~contractName, ~eventName)
  ->Belt.Option.getExn

let getEvmEventConfig = (~contractName, ~eventName) =>
  getEventConfig(~contractName, ~eventName)
  ->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)

