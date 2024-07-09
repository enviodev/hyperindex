open Belt
module Gravatar = {
  let contractName = "Gravatar"
  let chainConfig = Config.getGenerated().chainMap->ChainMap.get(MockConfig.chain1337)
  let contract = chainConfig.contracts->Js.Array2.find(c => c.name == contractName)->Option.getExn
  let defaultAddress = contract.addresses[0]->Option.getExn

  let makeEventConstructorWithDefaultSrcAddress =
    MockChainData.makeEventConstructor(~srcAddress=defaultAddress, ...)

  module NewGravatar = {
    let accessor = v => Types.Gravatar_NewGravatar(v)
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~eventMod=module(Types.Gravatar.NewGravatar),
      ~params=_,
      ...
    )
  }

  module UpdatedGravatar = {
    let accessor = v => Types.Gravatar_UpdatedGravatar(v)
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(
      ~accessor,
      ~eventMod=module(Types.Gravatar.UpdatedGravatar),
      ~params=_,
      ...
    )
  }
}
