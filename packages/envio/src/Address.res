type t

let schema = S.string->S.setName("Address")->(Utils.magic: S.t<string> => S.t<t>)

external toString: t => string = "%identity"

external unsafeFromString: string => t = "%identity"

module Evm = {
  @module("viem")
  external fromStringOrThrow: string => t = "getAddress"

  // NOTE: the function is named to be overshadowed by the one below, so that we don't have to import viem in the handler code
  @module("viem")
  external fromStringLowercaseOrThrow: string => bool = "isAddress"

  // f64 has 53 bits of mantissa; a 160-bit address round-tripped through
  // Number leaves at least 26 trailing zero hex characters. yaml-language-server
  // resolves unquoted `0x…` scalars as YAML 1.1 hex ints — Prettier or
  // similar formatters then save the file back through Number and silently
  // truncate the address. Surface this loudly instead of letting the
  // indexer query a non-existent contract and skip every event.
  let throwIfTruncatedByF64 = string => {
    let lower = string->String.toLowerCase
    if lower->String.length === 42 && lower->String.startsWith("0x") {
      let body = lower->String.sliceToEnd(~start=2)
      let trailingZeros = ref(0)
      let i = ref(body->String.length - 1)
      while i.contents >= 0 && body->String.charAt(i.contents) === "0" {
        trailingZeros := trailingZeros.contents + 1
        i := i.contents - 1
      }
      if trailingZeros.contents >= 26 && trailingZeros.contents < 40 {
        JsError.throwWithMessage(
          `Address "${string}" looks truncated by a 64-bit float — its lower bits are all zero, the signature left when an editor (yaml-language-server / Prettier in YAML 1.1 mode) resolves an unquoted "0x…" scalar as a hex integer and re-saves it through Number. Quote the address in config.yaml ('"${string}"' → the original value) and reopen the file, or upgrade your YAML extension to one that respects YAML 1.2 string resolution.`,
        )
      }
    }
  }

  // Reassign since the function might be used in the handler code
  // and we don't want to have a "viem" import there. It's needed to keep "viem" a dependency
  // of generated code instead of adding it to the indexer project dependencies.
  // Also, we want a custom error message, which is searchable in our codebase.
  // Validate that the string is a proper address but return a lowercased value
  let fromStringLowercaseOrThrow = string => {
    throwIfTruncatedByF64(string)
    if fromStringLowercaseOrThrow(string) {
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
    throwIfTruncatedByF64(string)
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
