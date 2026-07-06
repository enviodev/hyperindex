type t

let schema = S.string->S.setName("Address")->(Utils.magic: S.t<string> => S.t<t>)

external toString: t => string = "%identity"

external unsafeFromString: string => t = "%identity"

module Evm = {
  @module("viem")
  external fromStringOrThrow: string => t = "getAddress"

  // NOTE: the function is named to be overshadowed by the one below, so that we don't have to import viem in the handler code
  // strict:false checks only the 20-byte hex shape, not EIP-55 checksum casing —
  // since we're about to lowercase it anyway, an all-uppercase or wrongly-cased
  // input address is just as valid as one that's already lowercase.
  @module("viem")
  external fromStringLowercaseOrThrow: (string, {"strict": bool}) => bool = "isAddress"

  // Reassign since the function might be used in the handler code
  // and we don't want to have a "viem" import there. It's needed to keep "viem" a dependency
  // of generated code instead of adding it to the indexer project dependencies.
  // Also, we want a custom error message, which is searchable in our codebase.
  // Validate that the string is a proper address but return a lowercased value
  let fromStringLowercaseOrThrow = string => {
    if fromStringLowercaseOrThrow(string, {"strict": false}) {
      unsafeFromString(string->String.toLowerCase)
    } else {
      JsError.throwWithMessage(
        `Address "${string}" is invalid. Expected a 20-byte hex string starting with 0x.`,
      )
    }
  }

  let fromAddressLowercaseOrThrow = address =>
    address->toString->String.toLowerCase->(Utils.magic: string => t)

  // Reassign since the function might be used in the handler code
  // and we don't want to have a "viem" import there. It's needed to keep "viem" a dependency
  // of generated code instead of adding it to the indexer project dependencies.
  // Also, we want a custom error message, which is searchable in our codebase.
  let fromStringOrThrow = string => {
    try {
      fromStringOrThrow(string)
    } catch {
    | _ =>
      JsError.throwWithMessage(
        `Address "${string}" is invalid. Expected a 20-byte hex string starting with 0x.`,
      )
    }
  }

  let fromAddressOrThrow = address => address->toString->fromStringOrThrow
}
