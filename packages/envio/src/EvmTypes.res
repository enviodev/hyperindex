module Hex = {
  type t
  /**No string validation in schema*/
  let schema =
    S.string->S.setName("EVM.Hex")->(Utils.magic: S.t<string> => S.t<t>)
  external fromStringUnsafe: string => t = "%identity"
  external fromStringsUnsafe: array<string> => array<t> = "%identity"
  external toString: t => string = "%identity"
  external toStrings: array<t> => array<string> = "%identity"
}

module Abi = {
  type t
}
