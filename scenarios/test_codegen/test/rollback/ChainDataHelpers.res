let makeEventConstructorWithDefaultSrcAddress = MockChainData.makeEventConstructor(
  ~srcAddress=Ethers.Addresses.defaultAddress,
)
module Gravatar = {
  module NewGravatar = {
    let accessor = Types.gravatarContract_NewGravatar
    let serializer = Types.GravatarContract.NewGravatarEvent.eventArgs_encode
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(~accessor, ~serializer, ~params=_)
  }
  module UpdatedGravatar = {
    let accessor = Types.gravatarContract_UpdatedGravatar
    let serializer = Types.GravatarContract.UpdatedGravatarEvent.eventArgs_encode
    let mkEventConstr = makeEventConstructorWithDefaultSrcAddress(~accessor, ~serializer, ~params=_)
  }
}
