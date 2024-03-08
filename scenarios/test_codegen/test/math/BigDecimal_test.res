
module BigDecimal = {
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
  let t_encode = (bn: t) => bn->toString->Js.Json.string
  let t_decode: Js.Json.t => result<t, string> = json =>
    switch json->Js.Json.decodeString {
    | Some(stringBN) => Ok(fromString(stringBN))
    | None => Error("Json not deserializeable to BigNumber")
    }
}

open RescriptMocha
open Mocha

describe.only("BigDecimal Operations", () => {
  it("BigDecimal add 123.456 + 654.123 = 777.579", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromString("654.123")

    let c = a->BigDecimal.plus(b)

    Assert.equal(c->BigDecimal.toString, "777.579")
  })

  it("minus: 654.321 - 123.123 = 531.198", () => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromString("123.123")

    let result = a->BigDecimal.minus(b)

    Assert.equal(result->BigDecimal.toString, "531.198")
  })

  it("times: 123.456 * 2 = 246.912", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromInt(2)

    let result = a->BigDecimal.times(b)

    Assert.equal(result->BigDecimal.toString, "246.912")
  })

  it("div: 246.912 / 2 = 123.456", () => {
    let a = BigDecimal.fromFloat(246.912)
    let b = BigDecimal.fromInt(2)

    let result = a->BigDecimal.div(b)

    Assert.equal(result->BigDecimal.toString, "123.456")
  })

  it("equals: 123.456 == 123.456", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a->BigDecimal.equals(b)

    Assert.equal(result, true)
  })

  it("notEquals: 123.456 != 654.321", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(654.321)

    let result = BigDecimal.notEquals(a, b)

    Assert.equal(result, true)
  })

  it("gt: 654.321 > 123.456", () => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(123.456)

    let result = a->BigDecimal.gt(b)

    Assert.equal(result, true)
  })

  it("gte: 654.321 >= 654.321", () => {
    let a = BigDecimal.fromFloat(654.321)
    let b = BigDecimal.fromFloat(654.321)

    let result = a->BigDecimal.gte(b)

    Assert.equal(result, true)
  })

  it("lt: 123.456 < 654.321", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(654.321)

    let result = a->BigDecimal.lt(b)

    Assert.equal(result, true)
  })

  it("lte: 123.456 <= 123.456", () => {
    let a = BigDecimal.fromFloat(123.456)
    let b = BigDecimal.fromFloat(123.456)

    let result = a->BigDecimal.lte(b)

    Assert.equal(result, true)
  })
})
