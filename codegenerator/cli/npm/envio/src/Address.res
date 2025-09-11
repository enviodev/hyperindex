@genType.import(("./Types.ts", "Address"))
type t

let schema = S.string->S.setName("Address")->(Utils.magic: S.t<string> => S.t<t>)

external toString: t => string = "%identity"

external unsafeFromString: string => t = "%identity"

module Evm = {
  @module("viem")
  external fromStringOrThrow: string => t = "getAddress"

  // NOTE: We could use a regex for this instead, not sure if it is faster/slower than viem's 'isAddress' function
  //       `/^0x[a-fA-F0-9]{40}$/`
  @module("viem") @private
  external isAddress: string => bool = "isAddress"

  // Validate that the string is a proper address but return a lowercased value
  let fromStringLowercaseOrThrow = string => {
    // NOTE: We could use a regex for this and make this function more strict, so it only accepts lower case addresses as input
    //       eg this regex: `/^0x[a-f0-9]{40}$/`
    if (isAddress(string)) {
      unsafeFromString(string->Js.String2.toLowerCase)
    } else {
      Js.Exn.raiseError(
        `Address "${string}" is invalid. Expected a 20-byte hex string starting with 0x.`,
      )
    }
  }

  let fromAddressLowercaseOrThrow = address =>
    address->toString->fromStringLowercaseOrThrow

  // Reassign since the function might be used in the handler code
  // and we don't want to have a "viem" import there. It's needed to keep "viem" a dependency
  // of generated code instead of adding it to the indexer project dependencies.
  // Also, we want a custom error message, which is searchable in our codebase.
  let fromStringOrThrow = string => {
    try {
      fromStringOrThrow(string)
    } catch {
    | _ =>
      Js.Exn.raiseError(
        `Address "${string}" is invalid. Expected a 20-byte hex string starting with 0x.`,
      )
    }
  }

  let fromAddressOrThrow = address => address->toString->fromStringOrThrow
}
