let makeBlock = (~blockNumber, ~blockTimestamp, ~blockHash) =>
  {
    number: blockNumber,
    hash: blockHash,
    timestamp: blockTimestamp,
  }->(Utils.magic: Indexer.Block.t => Internal.eventBlock)

let makeTransaction = (~transactionIndex, ~transactionHash) =>
  {
    transactionIndex,
    hash: transactionHash,
  }->(Utils.magic: Indexer.Transaction.t => Internal.eventTransaction)

module Gravatar = {
  let contractName = "Gravatar"
  let chainConfig = (Config.loadWithoutRegistrations()).chainMap->ChainMap.get(MockConfig.chain1337)
  let contract = chainConfig.contracts->Array.find(c => c.name == contractName)->Option.getOrThrow
  let defaultAddress = contract.addresses[0]->Option.getOrThrow

  let makeEventConstructorWithDefaultSrcAddress = MockChainData.makeEventConstructor(
    ~srcAddress=defaultAddress,
    ~makeBlock,
    ~makeTransaction,
    ...
  )

  module NewGravatar = {
    let mkEventConstr = params =>
      makeEventConstructorWithDefaultSrcAddress(
        ~eventConfig=MockConfig.getEvmEventConfig(
          ~contractName="Gravatar",
          ~eventName="NewGravatar",
        ),
        ~params=params->(Utils.magic: Indexer.Gravatar.NewGravatar.params => Internal.eventParams),
        ...
      )
  }

  module UpdatedGravatar = {
    let mkEventConstr = params =>
      makeEventConstructorWithDefaultSrcAddress(
        ~eventConfig=MockConfig.getEvmEventConfig(
          ~contractName="Gravatar",
          ~eventName="UpdatedGravatar",
        ),
        ~params=params->(
          Utils.magic: Indexer.Gravatar.UpdatedGravatar.params => Internal.eventParams
        ),
        ...
      )
  }
}
