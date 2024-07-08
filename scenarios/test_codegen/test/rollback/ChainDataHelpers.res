open Belt
module Gravatar = {
  let contractName = "Gravatar"
  let chainConfig = Config.getConfig().chainMap->ChainMap.get(MockConfig.chain1337)
  let contract = chainConfig.contracts->Js.Array2.find(c => c.name == contractName)->Option.getExn
  let defaultAddress = contract.addresses[0]->Option.getExn

  let makeEventConstructorWithDefaultSrcAddress =
    MockChainData.makeEventConstructor(~srcAddress=defaultAddress, ...)

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
