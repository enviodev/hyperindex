module Pubkey = {
  type t
  let schema =
    S.string->S.setName("SVM.Pubkey")->(Utils.magic: S.t<string> => S.t<t>)
  external fromStringUnsafe: string => t = "%identity"
  external fromStringsUnsafe: array<string> => array<t> = "%identity"
  external toString: t => string = "%identity"
  external toStrings: array<t> => array<string> = "%identity"
}
