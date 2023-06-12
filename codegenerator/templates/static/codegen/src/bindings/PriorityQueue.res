type t<'a> = Js.t<{"length": int}>

@module("js-sdsl") @new
external makeAdvanced: (array<'a>, ('a, 'a) => int) => t<'a> = "PriorityQueue"

// Return a priority queue which prioritises lower numbers
let makeAsc = () => makeAdvanced([], (a, b) => a - b)

@send external pop: t<'a> => option<'a> = "pop"
@send external push: (t<'a>, 'a) => unit = "push"
@val external length: t<'a> => int = "length"
