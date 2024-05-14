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
    let accessor = v => Types.GravatarContract_NewGravatar(v)
    let schema = Types.GravatarContract.NewGravatarEvent.eventArgsSchema
    let eventName = Types.Gravatar_NewGravatar
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~schema,
      ~eventName,
      ~params=_,
    )
  }

  module UpdatedGravatar = {
    let accessor = v => Types.GravatarContract_UpdatedGravatar(v)
    let schema = Types.GravatarContract.UpdatedGravatarEvent.eventArgsSchema
    let eventName = Types.Gravatar_UpdatedGravatar
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~schema,
      ~eventName,
      ~params=_,
    )
  }
}