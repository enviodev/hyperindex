type t<'a>
let fromArrayUnsafe: array<(ChainId.t, 'a)> => t<'a>
let get: (t<'a>, ChainId.t) => 'a
let values: t<'a> => array<'a>
let keys: t<'a> => array<ChainId.t>
let has: (t<'a>, ChainId.t) => bool
let mapWithKey: (t<'a>, (ChainId.t, 'a) => 'b) => t<'b>
