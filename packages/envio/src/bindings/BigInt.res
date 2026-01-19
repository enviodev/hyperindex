%%private(
  @inline
  let unsafeToOption: (unit => 'a) => option<'a> = unsafeFunc => {
    try {
      unsafeFunc()->Some
    } catch {
    | Js.Exn.Error(_obj) => None
    }
  }
)

// constructors and methods
@val external fromInt: int => bigint = "BigInt"
@val external fromStringUnsafe: string => bigint = "BigInt"
@val external fromUnknownUnsafe: unknown => bigint = "BigInt"
let fromString = str => unsafeToOption(() => str->fromStringUnsafe)
@send external toString: bigint => string = "toString"
let toInt = (b: bigint): option<int> => b->toString->Belt.Int.fromString

//silence unused var warnings for raw bindings
@@warning("-27")
// operation
let add = (a: bigint, b: bigint): bigint => %raw("a + b")
let sub = (a: bigint, b: bigint): bigint => %raw("a - b")
let mul = (a: bigint, b: bigint): bigint => %raw("a * b")
let div = (a: bigint, b: bigint): bigint => %raw("b > 0n ? a / b : 0n")
let pow = (a: bigint, b: bigint): bigint => %raw("a ** b")
let mod = (a: bigint, b: bigint): bigint => %raw("b > 0n ? a % b : 0n")

// comparison
let eq = (a: bigint, b: bigint): bool => %raw("a === b")
let neq = (a: bigint, b: bigint): bool => %raw("a !== b")
let gt = (a: bigint, b: bigint): bool => %raw("a > b")
let gte = (a: bigint, b: bigint): bool => %raw("a >= b")
let lt = (a: bigint, b: bigint): bool => %raw("a < b")
let lte = (a: bigint, b: bigint): bool => %raw("a <= b")

module Bitwise = {
  let shift_left = (a: bigint, b: bigint): bigint => %raw("a << b")
  let shift_right = (a: bigint, b: bigint): bigint => %raw("a >> b")
  let logor = (a: bigint, b: bigint): bigint => %raw("a | b")
  let logand = (a: bigint, b: bigint): bigint => %raw("a & b")
}

let zero = fromInt(0)

@genType
let schema =
  S.string
  ->S.setName("BigInt")
  ->S.transform(s => {
    parser: string =>
      switch string->fromString {
      | Some(bigInt) => bigInt
      | None => s.fail("The string is not valid BigInt")
      },
    serializer: bigint => bigint->toString,
  })

let nativeSchema = S.bigint
