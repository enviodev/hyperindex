open Belt

module Chain = {
  type t = {id: int}

  let toChainId = chain => chain.id

  let toString = chain => chain.id->Int.toString

  let evm = chainId => {
    id: chainId,
  }

  module ChainIdCmp = Belt.Id.MakeComparableU({
    type t = t
    let cmp = (a, b) => Pervasives.compare(a->toChainId, b->toChainId)
  })
}

type t<'a> = Belt.Map.t<Chain.ChainIdCmp.t, 'a, Chain.ChainIdCmp.identity>

let make = (~base, fn: Chain.t => 'a): t<'a> => {
  base->Map.mapWithKey((chain, _) => fn(chain))
}

let fromArray: array<(Chain.t, 'a)> => t<'a> = arr => {
  arr->Map.fromArray(~id=module(Chain.ChainIdCmp))
}

let get: (t<'a>, Chain.t) => 'a = (self, chain) =>
  switch Map.get(self, chain) {
  | Some(v) => v
  | None => Js.Exn.raiseError("No chain with id " ++ chain->Chain.toString ++ " found in config.yaml")
  }

let set: (t<'a>, Chain.t, 'a) => t<'a> = (map, chain, v) => Map.set(map, chain, v)
let values: t<'a> => array<'a> = map => Map.valuesToArray(map)
let keys: t<'a> => array<Chain.t> = map => Map.keysToArray(map)
let entries: t<'a> => array<(Chain.t, 'a)> = map => Map.toArray(map)
let has: (t<'a>, Chain.t) => bool = (map, chain) => Map.has(map, chain)
let map: (t<'a>, 'a => 'b) => t<'b> = (map, fn) => Map.map(map, fn)
let mapWithKey: (t<'a>, (Chain.t, 'a) => 'b) => t<'b> = (map, fn) => Map.mapWithKey(map, fn)
let reduce: (t<'a>, 'b, (Chain.t, 'a, 'b) => 'b) => 'b = (map, acc, fn) => Map.reduce(map, acc, fn)
let size: t<'a> => int = map => Map.size(map)
let update: (t<'a>, Chain.t, 'a => 'a) => t<'a> = (map, chain, updateFn) =>
  Map.update(map, chain, opt => opt->Option.map(updateFn))
