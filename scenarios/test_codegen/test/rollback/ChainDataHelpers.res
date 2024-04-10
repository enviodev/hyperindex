open Belt
module Gravatar = {
  let contractName = "Gravatar"
  let chain = ChainMap.Chain.Chain_1337
  let chainConfig = Config.config->ChainMap.get(chain)
  let contract = chainConfig.contracts->Js.Array2.find(c => c.name == contractName)->Option.getExn
  let defaultAddress = contract.addresses[0]->Option.getExn

  let makeEventConstructorWithDefaultSrcAddress = MockChainData.makeEventConstructor(
    ~srcAddress=defaultAddress,
  )

  module NewGravatar = {
    let accessor = Types.gravatarContract_NewGravatar
    let serializer = Types.GravatarContract.NewGravatarEvent.eventArgs_encode
    let eventName = Types.Gravatar_NewGravatar
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~serializer,
      ~eventName,
      ~params=_,
    )
  }

  module UpdatedGravatar = {
    let accessor = Types.gravatarContract_UpdatedGravatar
    let serializer = Types.GravatarContract.UpdatedGravatarEvent.eventArgs_encode
    let eventName = Types.Gravatar_UpdatedGravatar
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~serializer,
      ~eventName,
      ~params=_,
    )
  }
}
