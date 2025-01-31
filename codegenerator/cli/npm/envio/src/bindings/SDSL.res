module Queue = {
  type t<'a>

  @module("js-sdsl") @new external make: unit => t<'a> = "Queue"

  type containerSize = int
  @send external size: t<'a> => containerSize = "size"
  @send external push: (t<'a>, 'a) => containerSize = "push"
  @send external pop: t<'a> => option<'a> = "pop"
  //Returns the front item without popping it
  @send external front: t<'a> => option<'a> = "front"
}
