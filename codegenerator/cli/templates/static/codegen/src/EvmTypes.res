module Hex = {
  type t
  external fromStringUnsafe: string => t = "%identity"
  external fromStringsUnsafe: array<string> => array<t> = "%identity"
}
