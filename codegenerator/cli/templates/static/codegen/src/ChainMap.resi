module Chain: {
  type t

  external toChainId: t => int = "%identity"

  let toString: t => string

  let makeUnsafe: (~chainId: int) => t
}

type t<'a>
let fromArrayUnsafe: array<(Chain.t, 'a)> => t<'a>
let get: (t<'a>, Chain.t) => 'a
let set: (t<'a>, Chain.t, 'a) => t<'a>
let values: t<'a> => array<'a>
let keys: t<'a> => array<Chain.t>
let entries: t<'a> => array<(Chain.t, 'a)>
let has: (t<'a>, Chain.t) => bool
let map: (t<'a>, 'a => 'b) => t<'b>
let mapWithKey: (t<'a>, (Chain.t, 'a) => 'b) => t<'b>
let size: t<'a> => int
let update: (t<'a>, Chain.t, 'a => 'a) => t<'a>
