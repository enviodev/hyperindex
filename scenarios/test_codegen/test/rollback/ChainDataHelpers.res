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

  let makeEventConstructorWithDefaultSrcAddress = MockChainData.makeEventConstructor(
    ~srcAddress=defaultAddress,
    ~makeBlock,
    ~makeTransaction,
    ...
  )

  module NewGravatar = {
    let mkEventConstr = params =>
      makeEventConstructorWithDefaultSrcAddress(
        ~eventConfig=Types.Gravatar.NewGravatar.register(),
        ~params=params->(Utils.magic: Types.Gravatar.NewGravatar.eventArgs => Internal.eventParams),
        ...
      )
  }

  module UpdatedGravatar = {
    let mkEventConstr = params =>
      makeEventConstructorWithDefaultSrcAddress(
        ~eventConfig=Types.Gravatar.UpdatedGravatar.register(),
        ~params=params->(
          Utils.magic: Types.Gravatar.UpdatedGravatar.eventArgs => Internal.eventParams
        ),
        ...
      )
  }
}
