let chain1 = ChainMap.Chain.makeUnsafe(~chainId=1)
let chain137 = ChainMap.Chain.makeUnsafe(~chainId=137)
let chain1337 = ChainMap.Chain.makeUnsafe(~chainId=1337)

let getEventConfig = (
  ~config=Indexer.Generated.configWithoutRegistrations,
  ~contractName,
  ~eventName,
  ~chainId=?,
) =>
  config
  ->Config.getEventConfig(~contractName, ~eventName, ~chainId?)
  ->Belt.Option.getExn

let getEvmEventConfig = (~config=?, ~contractName, ~eventName, ~chainId=?) =>
  getEventConfig(~config?, ~contractName, ~eventName, ~chainId?)
  ->(Utils.magic: Internal.eventConfig => Internal.evmEventConfig)

