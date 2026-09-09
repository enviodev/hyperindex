module ChainIdCmp = Belt.Id.MakeComparable({
  type t = ChainId.t
  let cmp = ChainId.compare
})

type t<'a> = Belt.Map.t<ChainIdCmp.t, 'a, ChainIdCmp.identity>

let fromArrayUnsafe: array<(ChainId.t, 'a)> => t<'a> = arr => {
  arr->Belt.Map.fromArray(~id=module(ChainIdCmp))
}

let get: (t<'a>, ChainId.t) => 'a = (self, chainId) =>
  switch Belt.Map.get(self, chainId) {
  | Some(v) => v
  | None =>
    // Should be unreachable, since we validate chain ids when parsing the config.
    // Still throw just in case something went wrong
    JsError.throwWithMessage(
      "No chain with id " ++ chainId->ChainId.toString ++ " found in chain map",
    )
  }

let values: t<'a> => array<'a> = map => Belt.Map.valuesToArray(map)
let keys: t<'a> => array<ChainId.t> = map => Belt.Map.keysToArray(map)
let has: (t<'a>, ChainId.t) => bool = (map, chainId) => Belt.Map.has(map, chainId)
let mapWithKey: (t<'a>, (ChainId.t, 'a) => 'b) => t<'b> = (map, fn) => Belt.Map.mapWithKey(map, fn)
