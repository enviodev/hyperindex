
module PriorityQueue = {
  type t<'a> = Js.t<{"length": int}>

  @module("js-sdsl") @new
  external makeAdvanced: (array<'a>, ('a, 'a) => int) => t<'a> = "PriorityQueue"

  // Return a priority queue which prioritises lower numbers
  let makeAsc = () => makeAdvanced([], (a, b) => a - b)

  @send external pop: t<'a> => option<'a> = "pop"
  @send external push: (t<'a>, 'a) => unit = "push"
}

module Deque = {
  type t<'a>

  @module("js-sdsl") @new external make: unit => t<'a> = "Deque"

  type containerSize = int
  @send external size: t<'a> => containerSize = "size"
  @send external pushBack: (t<'a>, 'a) => containerSize = "pushBack"
  @send external pushFront: (t<'a>, 'a) => containerSize = "pushFront"
  @send external popBack: t<'a> => option<'a> = "popBack"
  @send external popFront: t<'a> => option<'a> = "popFront"
}
