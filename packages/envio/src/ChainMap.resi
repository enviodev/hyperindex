module Chain: {
  type t

  external toChainId: t => ChainId.t = "%identity"

  let toString: t => string

  external makeUnsafe: (~chainId: ChainId.t) => t = "%identity"
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
