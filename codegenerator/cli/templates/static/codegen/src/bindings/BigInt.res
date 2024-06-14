@genType.import(("./OpaqueTypes.ts", "GenericBigInt"))
type t

module Misc = {
  let unsafeToOption: (unit => 'a) => option<'a> = unsafeFunc => {
    try {
      unsafeFunc()->Some
    } catch {
    | Js.Exn.Error(_obj) => None
    }
  }
}

// constructors and methods
@val external fromInt: int => t = "BigInt"
@val external fromStringUnsafe: string => t = "BigInt"
let fromString = str => Misc.unsafeToOption(() => str->fromStringUnsafe)
@send external toString: t => string = "toString"
let toInt = (b: t): option<int> => b->toString->Belt.Int.fromString

//silence unused var warnings for raw bindings
@@warning("-27")
// operation
let add = (a: t, b: t): t => %raw("a + b")
let sub = (a: t, b: t): t => %raw("a - b")
let mul = (a: t, b: t): t => %raw("a * b")
let div = (a: t, b: t): t => %raw("b > 0n ? a / b : 0n")
let pow = (a: t, b: t): t => %raw("a ** b")
let mod = (a: t, b: t): t => %raw("b > 0n ? a % b : 0n")

// comparison
let eq = (a: t, b: t): bool => %raw("a === b")
let neq = (a: t, b: t): bool => %raw("a !== b")
let gt = (a: t, b: t): bool => %raw("a > b")
let gte = (a: t, b: t): bool => %raw("a >= b")
let lt = (a: t, b: t): bool => %raw("a < b")
let lte = (a: t, b: t): bool => %raw("a <= b")

module Bitwise = {
  let shift_left = (a: t, b: t): t => %raw("a << b")
  let shift_right = (a: t, b: t): t => %raw("a >> b")
  let logor = (a: t, b: t): t => %raw("a | b")
  let logand = (a: t, b: t): t => %raw("a & b")
}

let zero = fromInt(0)

let schema =
  S.string
  ->S.setName("BigInt")
  ->S.transform((. s) => {
    parser: (. string) =>
      switch string->fromString {
      | Some(bigInt) => bigInt
      | None => s.fail(. "The string is not valid BigInt")
      },
    serializer: (. bigint) => bigint->toString,
  })
