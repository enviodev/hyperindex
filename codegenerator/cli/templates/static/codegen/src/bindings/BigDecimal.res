@genType
type rec bigDecimal = {
  toString: (. unit) => string,
  toFixed: (. int) => string,
  plus: (. bigDecimal) => bigDecimal,
  minus: (. bigDecimal) => bigDecimal,
  times: (. bigDecimal) => bigDecimal,
  div: (. bigDecimal) => bigDecimal,
  isEqualTo: (. bigDecimal) => bool,
  gt: (. bigDecimal) => bool,
  gte: (. bigDecimal) => bool,
  lt: (. bigDecimal) => bool,
  lte: (. bigDecimal) => bool,
}

@genType.import(("bignumber.js", "default"))
type rec t = bigDecimal

// Constructors
@new @module external fromBigInt: Ethers.BigInt.t => t = "bignumber.js"
@new @module external fromFloat: float => t = "bignumber.js"
@new @module external fromInt: int => t = "bignumber.js"
@new @module external fromStringUnsafe: string => t = "bignumber.js"
@new @module external fromString: string => option<t> = "bignumber.js"

// Utilities
let zero = fromInt(0)
let one = fromInt(1)

// Serialization
let schema =
  S.string
  ->S.setName("BigDecimal")
  ->S.transform((. s) => {
    parser: (. string) =>
      switch string->fromString {
      | Some(bigDecimal) => bigDecimal
      | None => s.fail(. "The string is not valid BigDecimal")
      },
    serializer: (. bigDecimal) => bigDecimal.toString(),
  })

@genType
module BigDecimalTypescript = {
  @getType
  type t = bigDecimal

  @getType
  let fromBigInt = fromBigInt
  @getType
  let fromFloat = fromFloat
  @getType
  let fromInt = fromInt
  @getType
  let fromString = fromString
  @getType
  let fromStringUnsafe = fromStringUnsafe
}
