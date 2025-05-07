@genType.import(("bignumber.js", "default"))
type rec t = {
  toString: unit => string,
  toFixed: int => string,
  plus: t => t,
  minus: t => t,
  times: t => t,
  div: t => t,
  isEqualTo: t => bool,
  gt: t => bool,
  gte: t => bool,
  lt: t => bool,
  lte: t => bool,
}

// Constructors
@new @module external fromBigInt: bigint => t = "bignumber.js"
@new @module external fromFloat: float => t = "bignumber.js"
@new @module external fromInt: int => t = "bignumber.js"
@new @module external fromStringUnsafe: string => t = "bignumber.js"
@new @module external fromString: string => option<t> = "bignumber.js"

// Methods
@send external toString: t => string = "toString"
@send external toFixed: t => string = "toFixed"
let toInt = (b: t): option<int> => b->toString->Belt.Int.fromString
@send external toNumber: t => float = "toNumber"

// Arithmetic Operations
@send external plus: (t, t) => t = "plus"
@send external minus: (t, t) => t = "minus"
@send external times: (t, t) => t = "multipliedBy"
@send external div: (t, t) => t = "dividedBy"
@send external sqrt: t => t = "sqrt"

// Comparison
@send external equals: (t, t) => bool = "isEqualTo"
let notEquals: (t, t) => bool = (a, b) => !equals(a, b)
@send external gt: (t, t) => bool = "isGreaterThan"
@send external gte: (t, t) => bool = "isGreaterThanOrEqualTo"
@send external lt: (t, t) => bool = "isLessThan"
@send external lte: (t, t) => bool = "isLessThanOrEqualTo"

// Utilities
let zero = fromInt(0)
let one = fromInt(1)
@send external decimalPlaces: (t, int) => t = "decimalPlaces"

// Serialization
@genType
let schema =
  S.string
  ->S.setName("BigDecimal")
  ->S.transform(s => {
    parser: string =>
      switch string->fromString {
      | Some(bigDecimal) => bigDecimal
      | None => s.fail("The string is not valid BigDecimal")
      },
    serializer: bigDecimal => bigDecimal.toString(),
  })
