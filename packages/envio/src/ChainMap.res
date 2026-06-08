module Chain = {
  type t = int

  external toChainId: t => int = "%identity"

  let toString = chainId => chainId->Int.toString

  let makeUnsafe = (~chainId) => chainId
}

// Keyed by the chain id as a string. JS iterates integer-like object keys in
// ascending numeric order, which matches the chain-id ordering callers expect.
type t<'a> = dict<'a>

let keyOf = (chain: Chain.t) => chain->Chain.toChainId->Int.toString
let chainOf = (key: string): Chain.t => Chain.makeUnsafe(~chainId=key->Int.fromString->Option.getOrThrow)

let fromArrayUnsafe: array<(Chain.t, 'a)> => t<'a> = arr =>
  arr->Array.map(((chain, v)) => (chain->keyOf, v))->Dict.fromArray

let get: (t<'a>, Chain.t) => 'a = (self, chain) =>
  switch self->Dict.get(chain->keyOf) {
  | Some(v) => v
  | None =>
    // Should be unreachable, since we validate on Chain.t creation
    // Still throw just in case something went wrong
    JsError.throwWithMessage("No chain with id " ++ chain->Chain.toString ++ " found in chain map")
  }

let set: (t<'a>, Chain.t, 'a) => t<'a> = (map, chain, v) => {
  let next = map->Dict.copy
  next->Dict.set(chain->keyOf, v)
  next
}
let values: t<'a> => array<'a> = map => map->Dict.valuesToArray
let keys: t<'a> => array<Chain.t> = map => map->Dict.keysToArray->Array.map(chainOf)
let entries: t<'a> => array<(Chain.t, 'a)> = map =>
  map->Dict.toArray->Array.map(((key, v)) => (key->chainOf, v))
let has: (t<'a>, Chain.t) => bool = (map, chain) => map->Dict.get(chain->keyOf)->Option.isSome
let map: (t<'a>, 'a => 'b) => t<'b> = (map, fn) =>
  map->Dict.toArray->Array.map(((key, v)) => (key, fn(v)))->Dict.fromArray
let mapWithKey: (t<'a>, (Chain.t, 'a) => 'b) => t<'b> = (map, fn) =>
  map->Dict.toArray->Array.map(((key, v)) => (key, fn(key->chainOf, v)))->Dict.fromArray
let size: t<'a> => int = map => map->Dict.keysToArray->Array.length
let update: (t<'a>, Chain.t, 'a => 'a) => t<'a> = (map, chain, updateFn) => {
  let next = map->Dict.copy
  switch next->Dict.get(chain->keyOf) {
  | Some(v) => next->Dict.set(chain->keyOf, updateFn(v))
  | None => ()
  }
  next
}
