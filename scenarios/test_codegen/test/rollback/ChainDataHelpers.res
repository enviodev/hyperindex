open Belt
let makeBlock = (~blockNumber, ~blockTimestamp, ~blockHash) =>
  {
    number: blockNumber,
    hash: blockHash,
    timestamp: blockTimestamp,
  }->(Utils.magic: Types.Block.t => Internal.eventBlock)

let makeTransaction = (~transactionIndex, ~transactionHash) =>
  {
    transactionIndex,
    hash: transactionHash,
  }->(Utils.magic: Types.Transaction.t => Internal.eventTransaction)

module Gravatar = {
  let contractName = "Gravatar"
  let chainConfig =
    RegisterHandlers.registerAllHandlers().chainMap->ChainMap.get(MockConfig.chain1337)
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
