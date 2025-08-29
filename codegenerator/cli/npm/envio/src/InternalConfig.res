// TODO: rename the file to Config.res after finishing the migration from codegen
// And turn it into PublicConfig instead
// For internal use we should create Indexer.res with a stateful type

type contract = {
  name: string,
  abi: EvmTypes.Abi.t,
  addresses: array<Address.t>,
  events: array<Internal.eventConfig>,
  startBlock: option<int>,
}

type chain = {
  id: int,
  startBlock: int,
  endBlock?: int,
  confirmedBlockThreshold: int,
  contracts: array<contract>,
  sources: array<Source.t>,
}

type ecosystem = | @as("evm") Evm | @as("fuel") Fuel
