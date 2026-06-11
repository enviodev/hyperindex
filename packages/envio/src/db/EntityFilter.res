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

let codegenHelpMessage = `Rerun 'pnpm dev' to update generated code after schema.graphql changes.`

let getUndefinedOrNullName = (value: 'a) =>
  if value === %raw(`undefined`) {
    Some("undefined")
  } else if value === %raw(`null`) {
    Some("null")
  } else {
    None
  }

// Nullish values would otherwise turn into a "= NULL" query
// silently matching nothing.
let throwUnsupportedGetWhereValue = (~valueName, ~entityName, ~filterDisplay, ~hint="") =>
  JsError.throwWithMessage(
    `Invalid ${valueName} value passed to context.${entityName}.getWhere(${filterDisplay}). Filtering by null or undefined values is not supported in getWhere.${hint}`,
  )

// Each returned filter should be loaded separately and the results flattened:
// _in maps to one Eq per value so loads memoize on the per-value level,
// and _gte/_lte are composed from Eq + Gt/Lt
let parseOrThrow = (filter: dict<dict<unknown>>, ~entityName, ~table: Table.table): array<t> => {
  let filterKeys = filter->Dict.keysToArray

  if filterKeys->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty filter passed to context.${entityName}.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
    )
  }
  if filterKeys->Array.length > 1 {
    JsError.throwWithMessage(
      `Multiple filter fields passed to context.${entityName}.getWhere(). Currently only one filter field per call is supported. Received fields: ${filterKeys->Array.joinUnsafe(
          ", ",
        )}.`,
    )
  }

  let apiFieldName = filterKeys->Array.getUnsafe(0)
  let operatorObj = filter->Dict.getUnsafe(apiFieldName)

  switch operatorObj->getUndefinedOrNullName {
  | Some(valueName) =>
    throwUnsupportedGetWhereValue(
      ~valueName,
      ~entityName,
      ~filterDisplay=`{ ${apiFieldName}: ${valueName} }`,
      ~hint=` Please provide an operator like { _eq: value }.`,
    )
  | None => ()
  }

  let operatorKeys = operatorObj->Dict.keysToArray

  if operatorKeys->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty operator passed to context.${entityName}.getWhere({ ${apiFieldName}: {} }). Please provide an operator like { _eq: value }, { _gt: value }, { _lt: value }, { _gte: value }, { _lte: value }, or { _in: [values] }.`,
    )
  }
  if operatorKeys->Array.length > 1 {
    JsError.throwWithMessage(
      `Multiple operators passed to context.${entityName}.getWhere({ ${apiFieldName}: ... }). Currently only one operator per filter field is supported. Received operators: ${operatorKeys->Array.joinUnsafe(
          ", ",
        )}.`,
    )
  }

  let operatorKey = operatorKeys->Array.getUnsafe(0)

  let throwInvalidOperator = () =>
    JsError.throwWithMessage(
      `Invalid operator "${operatorKey}" in context.${entityName}.getWhere({ ${apiFieldName}: { ${operatorKey}: ... } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
    )

  // Validate the operator and the field before the value, so a typoed
  // operator or field gets the more specific error even when the value
  // is also nullish
  switch operatorKey {
  | "_eq" | "_gt" | "_lt" | "_gte" | "_lte" | "_in" => ()
  | _ => throwInvalidOperator()
  }

  switch table->Table.getFieldByApiName(apiFieldName) {
  | None =>
    JsError.throwWithMessage(
      `Invalid field "${apiFieldName}" in context.${entityName}.getWhere(). The field doesn't exist. ${codegenHelpMessage}`,
    )
  | Some(DerivedFrom(_)) =>
    JsError.throwWithMessage(
      `The field "${apiFieldName}" on entity "${entityName}" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
    )
  | Some(Field({isIndex: false, linkedEntity: None})) =>
    JsError.throwWithMessage(
      `The field "${apiFieldName}" on entity "${entityName}" does not have an index. To use it in getWhere(), add the @index directive in your schema.graphql:\n\n  ${apiFieldName}: ... @index\n\nThen run 'pnpm envio codegen' to regenerate.`,
    )
  | Some(Field(_)) => ()
  }

  let fieldValue = operatorObj->Dict.getUnsafe(operatorKey)
  switch fieldValue->getUndefinedOrNullName {
  | Some(valueName) =>
    throwUnsupportedGetWhereValue(
      ~valueName,
      ~entityName,
      ~filterDisplay=`{ ${apiFieldName}: { ${operatorKey}: ${valueName} } }`,
    )
  | None => ()
  }

  if operatorKey === "_in" {
    let fieldValues = fieldValue->(Utils.magic: unknown => array<unknown>)

    fieldValues->Array.mapWithIndex((fieldValue, index) => {
      switch fieldValue->getUndefinedOrNullName {
      | Some(valueName) =>
        throwUnsupportedGetWhereValue(
          ~valueName,
          ~entityName,
          ~filterDisplay=`{ ${apiFieldName}: { _in: [...] } }`,
          ~hint=` The ${valueName} value is at index ${index->Int.toString} of the _in array.`,
        )
      | None => ()
      }
      Eq({fieldName: apiFieldName, fieldValue})
    })
  } else if operatorKey === "_gte" || operatorKey === "_lte" {
    [
      Eq({fieldName: apiFieldName, fieldValue}),
      operatorKey === "_gte"
        ? Gt({fieldName: apiFieldName, fieldValue})
        : Lt({fieldName: apiFieldName, fieldValue}),
    ]
  } else {
    [
      switch operatorKey {
      | "_eq" => Eq({fieldName: apiFieldName, fieldValue})
      | "_gt" => Gt({fieldName: apiFieldName, fieldValue})
      | "_lt" => Lt({fieldName: apiFieldName, fieldValue})
      | _ => throwInvalidOperator()
      },
    ]
  }
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
