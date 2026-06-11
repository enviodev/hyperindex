module FieldValue = {
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
    | Array(v) => `[${v->Array.map(toString)->Array.join(",")}]`
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

  let lt = (a, b) =>
    switch (a, b) {
    //For big decimal use custom equals operator otherwise let Caml_obj.equal do its magic
    | (Some(BigDecimal(bdA)), Some(BigDecimal(bdB))) => BigDecimal.lt(bdA, bdB)
    | (a, b) => a < b
    }
}

// The And case requires at least one nested filter (storage throws otherwise),
// while In with an empty array matches nothing.
@tag("operator")
type rec t =
  | @as("=") Eq({fieldName: string, fieldValue: unknown})
  | @as(">") Gt({fieldName: string, fieldValue: unknown})
  | @as("<") Lt({fieldName: string, fieldValue: unknown})
  | @as("in") In({fieldName: string, fieldValue: array<unknown>})
  | @as("and") And({filters: array<t>})

// Used as a stable in-memory cache key, so it must be unambiguous
// for any two different filters.
let rec toString = (filter: t) =>
  switch filter {
  | Eq({fieldName, fieldValue}) =>
    `${fieldName}:Eq:${fieldValue->FieldValue.castFrom->FieldValue.toString}`
  | Gt({fieldName, fieldValue}) =>
    `${fieldName}:Gt:${fieldValue->FieldValue.castFrom->FieldValue.toString}`
  | Lt({fieldName, fieldValue}) =>
    `${fieldName}:Lt:${fieldValue->FieldValue.castFrom->FieldValue.toString}`
  | In({fieldName, fieldValue}) =>
    `${fieldName}:In:[${fieldValue
      ->Array.map(v => v->FieldValue.castFrom->FieldValue.toString)
      ->Array.join(",")}]`
  | And({filters}) => `And(${filters->Array.map(toString)->Array.join(",")})`
  }

let rec valuesCount = (filter: t) =>
  switch filter {
  | Eq(_) | Gt(_) | Lt(_) => 1
  | In({fieldValue}) => fieldValue->Array.length
  | And({filters}) => filters->Array.reduce(0, (acc, filter) => acc + filter->valuesCount)
  }

// A field missing on the entity reads as `undefined`, which matches the `None`
// arm of `FieldValue.t` (`option<...>`), so nullable columns omitted on the
// entity object are compared as null rather than crashing.
let rec matches = (filter: t, ~entity: dict<FieldValue.t>) =>
  switch filter {
  | Eq({fieldName, fieldValue}) =>
    entity->Dict.getUnsafe(fieldName)->FieldValue.eq(fieldValue->FieldValue.castFrom)
  | Gt({fieldName, fieldValue}) =>
    entity->Dict.getUnsafe(fieldName)->FieldValue.gt(fieldValue->FieldValue.castFrom)
  | Lt({fieldName, fieldValue}) =>
    entity->Dict.getUnsafe(fieldName)->FieldValue.lt(fieldValue->FieldValue.castFrom)
  | In({fieldName, fieldValue}) => {
      let entityFieldValue = entity->Dict.getUnsafe(fieldName)
      fieldValue->Array.some(fieldValue =>
        entityFieldValue->FieldValue.eq(fieldValue->FieldValue.castFrom)
      )
    }
  | And({filters: []}) =>
    JsError.throwWithMessage(`The "and" filter must contain at least one nested filter.`)
  | And({filters}) => filters->Array.every(filter => filter->matches(~entity))
  }
