module ChainIdCmp = Belt.Id.MakeComparable({
  type t = ChainId.t
  let cmp = ChainId.compare
})

// `keys` holds the insertion order, which for a config's chains is the order
// config.yaml lists them: the run splits chains across workers in that order.
type t<'a> = {
  map: Belt.Map.t<ChainIdCmp.t, 'a, ChainIdCmp.identity>,
  keys: array<ChainId.t>,
}

let fromArrayUnsafe: array<(ChainId.t, 'a)> => t<'a> = arr => {
  map: arr->Belt.Map.fromArray(~id=module(ChainIdCmp)),
  keys: arr->Array.map(((chainId, _)) => chainId),
}

let get: (t<'a>, ChainId.t) => 'a = (self, chainId) =>
  switch Belt.Map.get(self.map, chainId) {
  | Some(v) => v
  | None =>
    // Should be unreachable, since we validate chain ids when parsing the config.
    // Still throw just in case something went wrong
    JsError.throwWithMessage(
      "No chain with id " ++ chainId->ChainId.toString ++ " found in chain map",
    )
  }

let values: t<'a> => array<'a> = self => self.keys->Array.map(chainId => self->get(chainId))
let keys: t<'a> => array<ChainId.t> = self => self.keys
let has: (t<'a>, ChainId.t) => bool = (self, chainId) => Belt.Map.has(self.map, chainId)
let mapWithKey: (t<'a>, (ChainId.t, 'a) => 'b) => t<'b> = (self, fn) => {
  map: Belt.Map.mapWithKey(self.map, fn),
  keys: self.keys,
}
