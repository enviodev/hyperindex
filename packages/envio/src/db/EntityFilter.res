// Serializes a filter value for the in-memory cache key. Built once per
// getWhere registration, never per entity, so a single generic pass is fine —
// it only has to be unambiguous across distinct values. bigint stringifies
// natively, bignumber.js and Date are objects with a toString, arrays recurse.
let serializeValue: unknown => string = %raw(`function ser(v) {
  if (v === undefined || v === null) return "undefined";
  if (Array.isArray(v)) return "[" + v.map(ser).join(",") + "]";
  if (typeof v === "object") return v.toString();
  return String(v);
}`)

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
  | Eq({fieldName, fieldValue}) => `${fieldName}:Eq:${fieldValue->serializeValue}`
  | Gt({fieldName, fieldValue}) => `${fieldName}:Gt:${fieldValue->serializeValue}`
  | Lt({fieldName, fieldValue}) => `${fieldName}:Lt:${fieldValue->serializeValue}`
  | In({fieldName, fieldValue}) =>
    `${fieldName}:In:[${fieldValue->Array.map(serializeValue)->Array.join(",")}]`
  | And({filters}) => `And(${filters->Array.map(toString)->Array.join(",")})`
  }

let rec valuesCount = (filter: t) =>
  switch filter {
  | Eq(_) | Gt(_) | Lt(_) => 1
  | In({fieldValue}) => fieldValue->Array.length
  | And({filters}) => filters->Array.reduce(0, (acc, filter) => acc + filter->valuesCount)
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
// and _gte/_lte are composed from Eq + Gt/Lt. Each field+operator pair
// expands into a group of such alternatives, and multiple pairs combine
// as a cross product of And filters — the groups stay disjoint, so the
// flattened results contain no duplicates.
let parseGetWhereOrThrow = (filter: dict<dict<unknown>>, ~entityName, ~table: Table.table): array<
  t,
> => {
  let filterKeys = filter->Dict.keysToArray

  if filterKeys->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty filter passed to context.${entityName}.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
    )
  }

  let filterGroups = filterKeys->Array.flatMap(apiFieldName => {
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

    // A primitive operator value wouldn't throw on Dict.keysToArray, but report
    // string indices or no keys as operators, so catch it with a real hint instead
    if operatorObj->typeof !== #object || operatorObj->Array.isArray {
      JsError.throwWithMessage(
        `Invalid value passed to context.${entityName}.getWhere({ ${apiFieldName}: ... }). Please provide an operator like { _eq: value }.`,
      )
    }

    let operatorKeys = operatorObj->Dict.keysToArray

    if operatorKeys->Array.length === 0 {
      JsError.throwWithMessage(
        `Empty operator passed to context.${entityName}.getWhere({ ${apiFieldName}: {} }). Please provide an operator like { _eq: value }, { _gt: value }, { _lt: value }, { _gte: value }, { _lte: value }, or { _in: [values] }.`,
      )
    }

    let throwInvalidOperator = operatorKey =>
      JsError.throwWithMessage(
        `Invalid operator "${operatorKey}" in context.${entityName}.getWhere({ ${apiFieldName}: { ${operatorKey}: ... } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
      )

    // Validate the operators and the field before the values, so a typoed
    // operator or field gets the more specific error even when the value
    // is also nullish
    operatorKeys->Array.forEach(operatorKey =>
      switch operatorKey {
      | "_eq" | "_gt" | "_lt" | "_gte" | "_lte" | "_in" => ()
      | _ => throwInvalidOperator(operatorKey)
      }
    )

    switch table->Table.getFieldByApiName(apiFieldName) {
    | None =>
      JsError.throwWithMessage(
        `Invalid field "${apiFieldName}" in context.${entityName}.getWhere(). The field doesn't exist. ${codegenHelpMessage}`,
      )
    | Some(DerivedFrom(_)) =>
      JsError.throwWithMessage(
        `The field "${apiFieldName}" on entity "${entityName}" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
      )
    | Some(Field({isPrimaryKey: false, isIndex: false, linkedEntity: None})) =>
      JsError.throwWithMessage(
        `The field "${apiFieldName}" on entity "${entityName}" does not have an index. To use it in getWhere(), add the @index directive in your schema.graphql:\n\n  ${apiFieldName}: ... @index\n\nThen run 'pnpm envio codegen' to regenerate.`,
      )
    | Some(Field(_)) => ()
    }

    operatorKeys->Array.map(operatorKey => {
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

      switch operatorKey {
      | "_in" => {
          if !(fieldValue->Array.isArray) {
            JsError.throwWithMessage(
              `Invalid value passed to context.${entityName}.getWhere({ ${apiFieldName}: { _in: ... } }). The _in operator expects an array of values.`,
            )
          }
          let fieldValues = fieldValue->(Utils.magic: unknown => array<unknown>)

          fieldValues->Array.mapWithIndex(
            (fieldValue, index) => {
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
            },
          )
        }
      | "_gte" => [
          Eq({fieldName: apiFieldName, fieldValue}),
          Gt({fieldName: apiFieldName, fieldValue}),
        ]
      | "_lte" => [
          Eq({fieldName: apiFieldName, fieldValue}),
          Lt({fieldName: apiFieldName, fieldValue}),
        ]
      | "_eq" => [Eq({fieldName: apiFieldName, fieldValue})]
      | "_gt" => [Gt({fieldName: apiFieldName, fieldValue})]
      | "_lt" => [Lt({fieldName: apiFieldName, fieldValue})]
      | _ => throwInvalidOperator(operatorKey)
      }
    })
  })

  filterGroups
  ->Array.reduce([[]], (combinations, group) =>
    combinations->Array.flatMap(combination =>
      group->Array.map(filter => combination->Array.concat([filter]))
    )
  )
  ->Array.map(filters =>
    switch filters {
    | [filter] => filter
    | _ => And({filters: filters})
    }
  )
}

let rec printOperationFilter = (filter: t, ~paramsCount: ref<int>) =>
  switch filter {
  | Eq({fieldName}) => {
      paramsCount := paramsCount.contents + 1
      `${fieldName}: $${paramsCount.contents->Int.toString}`
    }
  | Gt({fieldName}) => {
      paramsCount := paramsCount.contents + 1
      `${fieldName}: {_gt: $${paramsCount.contents->Int.toString}}`
    }
  | Lt({fieldName}) => {
      paramsCount := paramsCount.contents + 1
      `${fieldName}: {_lt: $${paramsCount.contents->Int.toString}}`
    }
  | In({fieldName}) => {
      paramsCount := paramsCount.contents + 1
      `${fieldName}: {_in: $${paramsCount.contents->Int.toString}}`
    }
  | And({filters}) => {
      let acc = ref("")
      for idx in 0 to filters->Array.length - 1 {
        let part = filters->Array.getUnsafe(idx)->printOperationFilter(~paramsCount)
        acc := (acc.contents === "" ? part : `${acc.contents}, ${part}`)
      }
      acc.contents
    }
  }

// Filters that may be batched into a single storage query must produce
// the same key, so concrete values are replaced with $N placeholders.
// The flat cases duplicate printOperationFilter to keep this hot path
// allocation-free.
let toOperationKey = (filter: t, ~entityName) =>
  switch filter {
  | Eq({fieldName}) => `${entityName}.getWhere({${fieldName}: $1})`
  | Gt({fieldName}) => `${entityName}.getWhere({${fieldName}: {_gt: $1}})`
  | Lt({fieldName}) => `${entityName}.getWhere({${fieldName}: {_lt: $1}})`
  | In({fieldName}) => `${entityName}.getWhere({${fieldName}: {_in: $1}})`
  | And(_) => `${entityName}.getWhere({${filter->printOperationFilter(~paramsCount=ref(0))}})`
  }

// Values bound to the operation key's $N placeholders, in placeholder
// order. A top-level In is reported flat, since a merged query holds one
// value per batched call there, while an In nested in And binds its whole
// array to a single placeholder, mirroring the one paramsCount increment
// per flat filter in printOperationFilter.
let getParams = (filter: t) =>
  switch filter {
  | Eq({fieldValue}) => [fieldValue]
  | Gt({fieldValue}) => [fieldValue]
  | Lt({fieldValue}) => [fieldValue]
  | In({fieldValue}) => fieldValue
  | And(_) => {
      let acc = []
      let rec collect = (filter: t) =>
        switch filter {
        | Eq({fieldValue}) => acc->Array.push(fieldValue)->ignore
        | Gt({fieldValue}) => acc->Array.push(fieldValue)->ignore
        | Lt({fieldValue}) => acc->Array.push(fieldValue)->ignore
        | In({fieldValue}) =>
          acc->Array.push(fieldValue->(Utils.magic: array<unknown> => unknown))->ignore
        | And({filters}) => filters->Array.forEach(collect)
        }
      collect(filter)
      acc
    }
  }

// Collapses filters sharing an operation key into fewer storage queries:
// Eq and In batches merge into a single In on the field. Gt/Lt/And have
// no lossless single-query form without an Or operator, so they stay as is.
// Expects a homogeneous batch — filters with the same operation key.
// A mismatched filter throws: dropping it would leave its already
// registered index without the matching db rows, silently losing data.
let throwUnmergeable = (filter: t) =>
  JsError.throwWithMessage(
    `Unexpected filter ${filter->toString} in a merged batch. Filters batched into a single query must use the same operator and field.`,
  )

let merge = (filters: array<t>) =>
  switch filters {
  | [] | [_] => filters
  | _ =>
    switch filters->Array.getUnsafe(0) {
    | Eq({fieldName}) => [
        In({
          fieldName,
          fieldValue: filters->Array.map(filter =>
            switch filter {
            | Eq({fieldValue}) => fieldValue
            | _ => throwUnmergeable(filter)
            }
          ),
        }),
      ]
    | In({fieldName}) => [
        In({
          fieldName,
          fieldValue: filters
          ->Array.map(filter =>
            switch filter {
            | In({fieldValue}) => fieldValue
            | _ => throwUnmergeable(filter)
            }
          )
          ->Array.flat,
        }),
      ]
    | Gt(_) | Lt(_) | And(_) => filters
    }
  }

// A predicate specialized to a single filter. The field's comparison is
// resolved once from the table config, so per-entity matching avoids both the
// operator dispatch and the polymorphic Caml_obj compare.
type matcher = Internal.entity => bool

// Reads a field off an entity by its API name. Indexed/queryable fields hold
// raw runtime values, so the result is compared directly.
@get_index external getField: (Internal.entity, string) => unknown = ""

// Compares (entityValue, filterValue) raw runtime values for one field. A
// nullish entity value (a missing or null column) matches nothing, mirroring
// SQL NULL semantics and the Postgres-side filter. Native operators already
// return false for undefined, so only the object-typed comparators guard
// explicitly to avoid calling methods on a missing value.
type valueCompare = {
  eq: (unknown, unknown) => bool,
  gt: (unknown, unknown) => bool,
  lt: (unknown, unknown) => bool,
}

let nullish: unknown => bool = %raw(`v => v === undefined || v === null`)

// `>`/`<` on `unknown` would compile to the polymorphic Caml_obj path; the raw
// operators give native JS comparison for primitive (string/number/bigint)
// fields. `===` is already physical equality.
let nativeEq = (a: unknown, b: unknown) => a === b
let nativeGt: (unknown, unknown) => bool = %raw(`(a, b) => a > b`)
let nativeLt: (unknown, unknown) => bool = %raw(`(a, b) => a < b`)
let native = {eq: nativeEq, gt: nativeGt, lt: nativeLt}

let asBigDecimal = (v: unknown) => v->(Utils.magic: unknown => BigDecimal.t)
let bigDecimal = {
  eq: (a, b) => !(a->nullish) && BigDecimal.equals(a->asBigDecimal, b->asBigDecimal),
  gt: (a, b) => !(a->nullish) && BigDecimal.gt(a->asBigDecimal, b->asBigDecimal),
  lt: (a, b) => !(a->nullish) && BigDecimal.lt(a->asBigDecimal, b->asBigDecimal),
}

let getTime = (v: unknown) => v->(Utils.magic: unknown => Date.t)->Date.getTime
let date = {
  eq: (a, b) => !(a->nullish) && getTime(a) === getTime(b),
  gt: (a, b) => !(a->nullish) && getTime(a) > getTime(b),
  lt: (a, b) => !(a->nullish) && getTime(a) < getTime(b),
}

// Json has no meaningful ordering, so reuse the structural compare for every
// operator. Polymorphic `==` is intentional here.
let json = {
  eq: (a: unknown, b: unknown) => !(a->nullish) && a == b,
  gt: (a, b) => !(a->nullish) && a > b,
  lt: (a, b) => !(a->nullish) && a < b,
}

let scalarCompare = (fieldType: Table.fieldType): valueCompare =>
  switch fieldType {
  | BigDecimal(_) => bigDecimal
  | Date => date
  | Json => json
  | String
  | Boolean
  | Uint32
  | UInt52
  | UInt64
  | Int32
  | Number
  | BigInt(_)
  | Serial
  | BigSerial
  | Enum(_)
  | Entity(_) => native
  }

let asArray = (v: unknown) => v->(Utils.magic: unknown => array<unknown>)

// Array-valued fields compare element-wise with the element type's comparator:
// equality is length + pairwise eq, ordering is lexicographic where the first
// differing element decides and a proper prefix is the smaller array.
let arrayCompare = (element: valueCompare): valueCompare => {
  let eq = (a, b) =>
    !(a->nullish) && {
      let a = a->asArray
      let b = b->asArray
      let len = a->Array.length
      len === b->Array.length && {
        let rec go = i =>
          i >= len || (element.eq(a->Array.getUnsafe(i), b->Array.getUnsafe(i)) && go(i + 1))
        go(0)
      }
    }
  let order = (~gt) => (a, b) =>
    !(a->nullish) && {
      let a = a->asArray
      let b = b->asArray
      let la = a->Array.length
      let lb = b->Array.length
      let len = la < lb ? la : lb
      let rec go = i =>
        if i >= len {
          gt ? la > lb : la < lb
        } else {
          let x = a->Array.getUnsafe(i)
          let y = b->Array.getUnsafe(i)
          if element.eq(x, y) {
            go(i + 1)
          } else {
            gt ? element.gt(x, y) : element.lt(x, y)
          }
        }
      go(0)
    }
  {eq, gt: order(~gt=true), lt: order(~gt=false)}
}

let rec makeMatcher = (filter: t, ~table: Table.table): matcher => {
  let fieldCompare = fieldName =>
    switch table->Table.getFieldByApiName(fieldName) {
    | Some(Field({fieldType, isArray})) =>
      let element = scalarCompare(fieldType)
      isArray ? arrayCompare(element) : element
    // Filters are validated against the table before reaching here, so a
    // missing or derived field is unexpected; compare structurally instead of
    // crashing.
    | _ => json
    }

  switch filter {
  | Eq({fieldName, fieldValue}) =>
    let eq = (fieldName->fieldCompare).eq
    entity => eq(entity->getField(fieldName), fieldValue)
  | Gt({fieldName, fieldValue}) =>
    let gt = (fieldName->fieldCompare).gt
    entity => gt(entity->getField(fieldName), fieldValue)
  | Lt({fieldName, fieldValue}) =>
    let lt = (fieldName->fieldCompare).lt
    entity => lt(entity->getField(fieldName), fieldValue)
  | In({fieldName, fieldValue}) =>
    let eq = (fieldName->fieldCompare).eq
    entity => {
      let entityFieldValue = entity->getField(fieldName)
      fieldValue->Array.some(value => eq(entityFieldValue, value))
    }
  | And({filters: []}) =>
    _ => JsError.throwWithMessage(`The "and" filter must contain at least one nested filter.`)
  | And({filters}) =>
    let matchers = filters->Array.map(filter => filter->makeMatcher(~table))
    entity => matchers->Array.every(matcher => matcher(entity))
  }
}

// In values are mapped as one array (isArray=true), so they can be
// converted with the table's cached array schema in a single pass.
let rec mapValues = (
  filter: t,
  ~mapValue: (~fieldName: string, ~fieldValue: unknown, ~isArray: bool) => unknown,
) =>
  switch filter {
  | Eq({fieldName, fieldValue}) =>
    Eq({fieldName, fieldValue: mapValue(~fieldName, ~fieldValue, ~isArray=false)})
  | Gt({fieldName, fieldValue}) =>
    Gt({fieldName, fieldValue: mapValue(~fieldName, ~fieldValue, ~isArray=false)})
  | Lt({fieldName, fieldValue}) =>
    Lt({fieldName, fieldValue: mapValue(~fieldName, ~fieldValue, ~isArray=false)})
  | In({fieldName, fieldValue}) =>
    In({
      fieldName,
      fieldValue: mapValue(
        ~fieldName,
        ~fieldValue=fieldValue->(Utils.magic: array<unknown> => unknown),
        ~isArray=true,
      )->(Utils.magic: unknown => array<unknown>),
    })
  | And({filters}) => And({filters: filters->Array.map(filter => filter->mapValues(~mapValue))})
  }
