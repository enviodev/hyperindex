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
    let accessor = v => Types.Gravatar_NewGravatar(v)
    let schema = Types.Gravatar.NewGravatar.eventArgsSchema
    let eventName = Enums.EventType.Gravatar_NewGravatar
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~schema,
      ~eventName,
      ~params=_,
      ...
    )
  }

  module UpdatedGravatar = {
    let accessor = v => Types.Gravatar_UpdatedGravatar(v)
    let schema = Types.Gravatar.UpdatedGravatar.eventArgsSchema
    let eventName = Enums.EventType.Gravatar_UpdatedGravatar
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~schema,
      ~eventName,
      ~params=_,
      ...
    )
  }
}
