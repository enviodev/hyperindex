module Hex = {
  type t
  external fromStringUnsafe: string => t = "%identity"
  external fromStringsUnsafe: array<string> => array<t> = "%identity"
  external toString: t => string = "%identity"
  external toStrings: array<t> => array<string> = "%identity"
}
