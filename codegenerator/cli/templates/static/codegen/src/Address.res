@genType.import(("./OpaqueTypes.ts", "Address"))
type t

let schema = S.string->S.setName("Address")->(Utils.magic: S.t<string> => S.t<t>)

external toString: t => string = "%identity"

external unsafeFromString: string => t = "%identity"

module Evm = {
  @module("viem")
  external fromStringOrThrow: string => t = "getAddress"
  // Reassign since the function might be used in the handler code
  // and we don't want to have a "viem" import there. It's needed to keep "viem" a dependency
  // of generated code instead of adding it to the indexer project dependencies.
  let fromStringOrThrow = fromStringOrThrow

  exception InvalidAddress({address: string, message: string})
  let sanitizeOrThrow = (address: t): t => {
    switch address->toString->fromStringOrThrow {
    | exception _ =>
      raise(
        InvalidAddress({
          address: address->toString,
          message: "Unable to parse address. Expected a 20-byte hex string starting with 0x.",
        }),
      )
    | address => address
    }
  }
}
