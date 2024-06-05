@genType.import(("bignumber.js", "BigNumber"))
type t

// Constructors
@new @module external fromBigInt: Ethers.BigInt.t => t = "bignumber.js"
@new @module external fromFloat: float => t = "bignumber.js"
@new @module external fromInt: int => t = "bignumber.js"
@new @module external fromStringUnsafe: string => t = "bignumber.js"
@new @module external fromString: string => option<t> = "bignumber.js"

// Methods
@send external toString: t => string = "toString"
@send external toFixed: t => string = "toFixed"
let toInt = (b: t): option<int> => b->toString->Belt.Int.fromString

// Arithmetic Operations
@send external plus: (t, t) => t = "plus"
@send external minus: (t, t) => t = "minus"
@send external times: (t, t) => t = "multipliedBy"
@send external div: (t, t) => t = "dividedBy"
// @send external pow: (t, int) => t = "toExponential"
// @send external mod: (t, t) => t = "modulo"

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

// Serialization
let schema =
    S.string
    ->S.setName("Ethers.BigInt")
    ->S.transform((. s) => {
      parser: (. string) =>
        switch string->fromString {
        | Some(bigDecimal) => bigDecimal
        | None => s.fail(. "The string is not valid BigDecimal")
        },
      serializer: (. bigint) => bigint->toString,
    })
