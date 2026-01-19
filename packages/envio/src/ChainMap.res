open Belt

module Chain = {
  type t = int

  external toChainId: t => int = "%identity"

  let toString = chainId => chainId->Int.toString

  let makeUnsafe = (~chainId) => chainId
}

module ChainIdCmp = Belt.Id.MakeComparableU({
  type t = Chain.t
  let cmp = (a, b) => Pervasives.compare(a->Chain.toChainId, b->Chain.toChainId)
})

type t<'a> = Belt.Map.t<ChainIdCmp.t, 'a, ChainIdCmp.identity>

let fromArrayUnsafe: array<(Chain.t, 'a)> => t<'a> = arr => {
  arr->Map.fromArray(~id=module(ChainIdCmp))
}

let get: (t<'a>, Chain.t) => 'a = (self, chain) =>
  switch Map.get(self, chain) {
  | Some(v) => v
  | None =>
    // Should be unreachable, since we validate on Chain.t creation
    // Still throw just in case something went wrong
    Js.Exn.raiseError("No chain with id " ++ chain->Chain.toString ++ " found in chain map")
  }

let set: (t<'a>, Chain.t, 'a) => t<'a> = (map, chain, v) => Map.set(map, chain, v)
let values: t<'a> => array<'a> = map => Map.valuesToArray(map)
let keys: t<'a> => array<Chain.t> = map => Map.keysToArray(map)
let entries: t<'a> => array<(Chain.t, 'a)> = map => Map.toArray(map)
let has: (t<'a>, Chain.t) => bool = (map, chain) => Map.has(map, chain)
let map: (t<'a>, 'a => 'b) => t<'b> = (map, fn) => Map.map(map, fn)
let mapWithKey: (t<'a>, (Chain.t, 'a) => 'b) => t<'b> = (map, fn) => Map.mapWithKey(map, fn)
let size: t<'a> => int = map => Map.size(map)
let update: (t<'a>, Chain.t, 'a => 'a) => t<'a> = (map, chain, updateFn) =>
  Map.update(map, chain, opt => opt->Option.map(updateFn))
