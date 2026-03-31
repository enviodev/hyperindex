open Belt
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
  let chainConfig = Indexer.Generated.makeGeneratedConfig().chainMap->ChainMap.get(MockConfig.chain1337)
  let contract = chainConfig.contracts->Js.Array2.find(c => c.name == contractName)->Option.getExn
  let defaultAddress = contract.addresses[0]->Option.getExn

  let makeEventConstructorWithDefaultSrcAddress =
    MockChainData.makeEventConstructor(
      ~srcAddress=defaultAddress,
      ~makeBlock,
      ~makeTransaction,
      ...
    )

  module NewGravatar = {
    let mkEventConstr = params =>
      makeEventConstructorWithDefaultSrcAddress(
        ~eventConfig=Indexer.Gravatar.NewGravatar.register(),
        ~params=params->(Utils.magic: Indexer.Gravatar.NewGravatar.eventArgs => Internal.eventParams),
        ...
      )
  }

  module UpdatedGravatar = {
    let mkEventConstr = params =>
      makeEventConstructorWithDefaultSrcAddress(
        ~eventConfig=Indexer.Gravatar.UpdatedGravatar.register(),
        ~params=params->(
          Utils.magic: Indexer.Gravatar.UpdatedGravatar.eventArgs => Internal.eventParams
        ),
        ...
      )
  }
}
