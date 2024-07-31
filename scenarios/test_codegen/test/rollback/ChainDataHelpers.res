open Belt
let makeBlock = (~blockNumber, ~blockTimestamp, ~blockHash): Types.Block.t => {
  number: blockNumber,
  hash: blockHash,
  timestamp: blockTimestamp,
}
let makeTransaction = (~transactionIndex, ~transactionHash): Types.Transaction.t => {
  transactionIndex,
  hash: transactionHash,
}
module Gravatar = {
  let contractName = "Gravatar"
  let chainConfig = Config.getGenerated().chainMap->ChainMap.get(MockConfig.chain1337)
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
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~eventMod=module(Types.Gravatar.NewGravatar),
      ~params=_,
      ...
    )
  }

  module UpdatedGravatar = {
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~eventMod=module(Types.Gravatar.UpdatedGravatar),
      ~params=_,
      ...
    )
  }
}
