@genType.import(("./OpaqueTypes.ts", "Address"))
type t

let schema =
  S.string->S.setName("Address")->(Utils.magic: S.t<string> => S.t<t>)

external toString: t => string = "%identity"

module Evm = {
  @module("ethers") @scope("ethers")
  external fromStringOrThrow: string => t = "getAddress"

  /**
  Same binding as getAddress from string 
  but used when we receive and address that's not necessarily checksummed
  */
  @module("ethers")
  @scope("ethers")
  external checksum: t => t = "getAddress"
}