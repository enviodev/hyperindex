let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let getEventConfig = (~config=Indexer.Generated.configWithoutRegistrations, ~contractName, ~eventName) =>
  config
  ->Config.getEventConfig(~contractName, ~eventName)
  ->Belt.Option.getExn

let getEvmEventConfig = (~config=?, ~contractName, ~eventName) =>
  getEventConfig(~config?, ~contractName, ~eventName)
  ->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)

