module PriorityQueue = {
  type t<'a>

  @module("js-sdsl") @new
  external makeAdvanced: (array<'a>, ('a, 'a) => int) => t<'a> = "PriorityQueue"

  // Return a priority queue which prioritises lower numbers
  let makeAsc = () => makeAdvanced([], (a, b) => a - b)

  @send external pop: t<'a> => option<'a> = "pop"
  @send external push: (t<'a>, 'a) => unit = "push"
  @get external length: t<'a> => int = "length"
  //Returns the top item without popping it
  @send external top: t<'a> => option<'a> = "top"
  @send external toArray: t<'a> => array<'a> = "toArray"
}

module Queue = {
  type t<'a>

  @module("js-sdsl") @new external make: unit => t<'a> = "Queue"

  type containerSize = int
  @send external size: t<'a> => containerSize = "size"
  @send external push: (t<'a>, 'a) => containerSize = "push"
  @send external pop: t<'a> => option<'a> = "pop"
  //Returns the front item without popping it
  @send external front: t<'a> => option<'a> = "front"

  let rec popForEach = (self: t<'a>, callback: 'a => unit) => {
    self
    ->pop
    ->Belt.Option.map(item => {
      callback(item)
      popForEach(self, callback)
    })
    ->ignore
  }
}
