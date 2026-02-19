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
@new @module("bignumber.js") external fromBigInt: bigint => t = "default"
@new @module("bignumber.js") external fromFloat: float => t = "default"
@new @module("bignumber.js") external fromInt: int => t = "default"
@new @module("bignumber.js") external fromStringUnsafe: string => t = "default"
@new @module("bignumber.js") external fromString: string => option<t> = "default"

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
  ->Utils.Schema.setName("BigDecimal")
  ->S.transform(s => {
    parser: string =>
      switch string->fromString {
      | Some(bigDecimal) => bigDecimal
      | None => s.fail("The string is not valid BigDecimal")
      },
    serializer: bigDecimal => bigDecimal.toString(),
  })
