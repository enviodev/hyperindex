module FieldValue = {
  open Belt
  @unboxed
  type rec tNonOptional =
    | String(string)
    | BigInt(bigint)
    | Int(int)
    | BigDecimal(BigDecimal.t)
    | Bool(bool)
    | Array(array<tNonOptional>)

  let rec toString = tNonOptional =>
    switch tNonOptional {
    | String(v) => v
    | BigInt(v) => v->BigInt.toString
    | Int(v) => v->Int.toString
    | BigDecimal(v) => v->BigDecimal.toString
    | Bool(v) => v ? "true" : "false"
    | Array(v) => `[${v->Array.joinWith(",", toString)}]`
    }

  //This needs to be a castable type from any type that we
  //support in entities so that we can create evaluations
  //and serialize the types without parsing/wrapping them
  type t = option<tNonOptional>

  let toString = (value: t) =>
    switch value {
    | Some(v) => v->toString
    | None => "undefined"
    }

  external castFrom: 'a => t = "%identity"
  external castTo: t => 'a = "%identity"

  let eq = (a, b) =>
    switch (a, b) {
    //For big decimal use custom equals operator otherwise let Caml_obj.equal do its magic
    | (Some(BigDecimal(bdA)), Some(BigDecimal(bdB))) => BigDecimal.equals(bdA, bdB)
    | (a, b) => a == b
    }

  let gt = (a, b) =>
    switch (a, b) {
    //For big decimal use custom equals operator otherwise let Caml_obj.equal do its magic
    | (Some(BigDecimal(bdA)), Some(BigDecimal(bdB))) => BigDecimal.gt(bdA, bdB)
    | (a, b) => a > b
    }
}

module Operator = {
  type t = Eq | Gt

  let values = [Eq, Gt]
}

module SingleIndex = {
  type t = {fieldName: string, fieldValue: FieldValue.t, operator: Operator.t}

  let make = (~fieldName, ~fieldValue: 'a, ~operator) => {
    fieldName,
    fieldValue: FieldValue.castFrom(fieldValue),
    operator,
  }

  // Should much hashing logic in InMemoryTable
  let toString = ({fieldName, fieldValue, operator}) =>
    `${fieldName}:${(operator :> string)}:${fieldValue->FieldValue.toString}`

  let evaluate = (self: t, ~fieldName, ~fieldValue) =>
    self.fieldName === fieldName &&
      switch self.operator {
      | Eq => fieldValue->FieldValue.eq(self.fieldValue)
      | Gt => fieldValue->FieldValue.gt(self.fieldValue)
      }
}

module Index = {
  //Next step is to support composite indexes
  @unboxed
  type t = Single(SingleIndex.t) //| Composite(array<SingleIndex.t>)

  let makeSingle = (~fieldName, ~fieldValue, ~operator) => Single(
    SingleIndex.make(~fieldName, ~fieldValue, ~operator),
  )

  let getFieldName = index =>
    switch index {
    | Single(index) => index.fieldName
    }

  let toString = index =>
    switch index {
    | Single(index) => index->SingleIndex.toString
    }

  let evaluate = (index: t, ~fieldName, ~fieldValue) =>
    switch index {
    | Single(index) => SingleIndex.evaluate(index, ~fieldName, ~fieldValue)
    }
}
