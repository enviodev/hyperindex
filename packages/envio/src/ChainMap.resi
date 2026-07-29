type t<'a>
let fromArrayUnsafe: array<(ChainId.t, 'a)> => t<'a>
let get: (t<'a>, ChainId.t) => 'a
let set: (t<'a>, ChainId.t, 'a) => t<'a>
let values: t<'a> => array<'a>
let keys: t<'a> => array<ChainId.t>
let entries: t<'a> => array<(ChainId.t, 'a)>
let has: (t<'a>, ChainId.t) => bool
let map: (t<'a>, 'a => 'b) => t<'b>
let mapWithKey: (t<'a>, (ChainId.t, 'a) => 'b) => t<'b>
let size: t<'a> => int
let update: (t<'a>, ChainId.t, 'a => 'a) => t<'a>
