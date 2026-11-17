module ChainIdCmp = Belt.Id.MakeComparable({
  type t = ChainId.t
  let cmp = ChainId.compare
})

// `keys` and `values` are parallel arrays in insertion order, which for a
// config's chains is the order config.yaml lists them: the run splits chains
// across workers in that order. `byChainId` only serves lookups by id.
type t<'a> = {
  keys: array<ChainId.t>,
  values: array<'a>,
  byChainId: Belt.Map.t<ChainIdCmp.t, 'a, ChainIdCmp.identity>,
}

let fromArrayUnsafe: array<(ChainId.t, 'a)> => t<'a> = arr => {
  keys: arr->Array.map(((chainId, _)) => chainId),
  values: arr->Array.map(((_, value)) => value),
  byChainId: arr->Belt.Map.fromArray(~id=module(ChainIdCmp)),
}

let get: (t<'a>, ChainId.t) => 'a = (self, chainId) =>
  switch Belt.Map.get(self.byChainId, chainId) {
  | Some(v) => v
  | None =>
    // Should be unreachable, since we validate chain ids when parsing the config.
    // Still throw just in case something went wrong
    JsError.throwWithMessage(
      "No chain with id " ++ chainId->ChainId.toString ++ " found in chain map",
    )
  }

let values: t<'a> => array<'a> = self => self.values
let keys: t<'a> => array<ChainId.t> = self => self.keys
let has: (t<'a>, ChainId.t) => bool = (self, chainId) => Belt.Map.has(self.byChainId, chainId)
let mapWithKey: (t<'a>, (ChainId.t, 'a) => 'b) => t<'b> = (self, fn) =>
  self.keys
  ->Array.mapWithIndex((chainId, index) => (
    chainId,
    fn(chainId, self.values->Array.getUnsafe(index)),
  ))
  ->fromArrayUnsafe
