type t

external toChainId: t => int = "%identity"

let toString: t => string

let makeUnsafe: (~chainId: int) => t

module Map: {
  type key = t
  type t<'a>
  let fromArrayUnsafe: array<(key, 'a)> => t<'a>
  let get: (t<'a>, key) => 'a
  let set: (t<'a>, key, 'a) => t<'a>
  let values: t<'a> => array<'a>
  let keys: t<'a> => array<key>
  let entries: t<'a> => array<(key, 'a)>
  let has: (t<'a>, key) => bool
  let map: (t<'a>, 'a => 'b) => t<'b>
  let mapWithKey: (t<'a>, (key, 'a) => 'b) => t<'b>
  let size: t<'a> => int
  let update: (t<'a>, key, 'a => 'a) => t<'a>
}
