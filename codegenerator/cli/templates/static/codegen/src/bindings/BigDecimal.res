@genType.import(("bignumber.js", "default"))
type rec t = {
  toString: (. unit) => string,
  toFixed: (. int) => string,
  plus: (. t) => t,
  minus: (. t) => t,
  times: (. t) => t,
  div: (. t) => t,
  isEqualTo: (. t) => bool,
  gt: (. t) => bool,
  gte: (. t) => bool,
  lt: (. t) => bool,
  lte: (. t) => bool,
}

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
