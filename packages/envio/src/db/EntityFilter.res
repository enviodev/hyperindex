@scope("JSON") @val external jsonStringify: unknown => string = "stringify"

let nullish: unknown => bool = %raw(`v => v === undefined || v === null`)

// Renders one already-projected value into a cache key: a type tag, then the
// length, then the value. The tag keeps "5" apart from 5, and the length means
// a delimiter inside a value can't imitate the delimiter, so no escaping pass
// is needed. Both together make the encoding injective, which is the only
// property a key needs.
//
// Every branch but the last is reached because the column's projection already
// collapsed its values to a primitive — a Date to its epoch millis, a Bytea to
// hex — so nothing here has to guess a value's type at runtime. JSON is the
// last resort, for a column whose values are objects in the first place.
let encodeValueKey: unknown => string = %raw(`v => {
  if (v === null) return "z"
  switch (typeof v) {
    case "string": return "s" + v.length + ":" + v
    case "number": { const s = "" + v; return "n" + s.length + ":" + s }
    case "bigint": { const s = "" + v; return "g" + s.length + ":" + s }
    case "boolean": return v ? "t" : "f"
    case "undefined": return "u"
    default: { const s = JSON.stringify(v); return "o" + s.length + ":" + s }
  }
}`)

// JSON is the one step above that can fail, and only on an object: one holding
// a bigint, or one that refers to itself. An array is walked rather than
// stringified, because its key is built from its elements' keys.
let isKeyable: unknown => bool = %raw(`function isKeyable(v) {
  if (typeof v !== "object" || v === null) return true
  if (Array.isArray(v)) return v.every(isKeyable)
  try { JSON.stringify(v); return true } catch { return false }
}`)

// The filter as the handler wrote it: field -> operator -> value. Everything
// downstream reads this shape, so what reaches storage is a flat map rather
// than a recursive tree.
type t = dict<dict<unknown>>

let valuesCount = (filter: t) => {
  let count = ref(0)
  filter->Utils.Dict.forEachWithKey((operators, _) =>
    operators->Utils.Dict.forEachWithKey((fieldValue, operator) =>
      count :=
        count.contents + (
          operator === "_in"
            ? fieldValue->(Utils.magic: unknown => array<unknown>)->Array.length
            : 1
        )
    )
  )
  count.contents
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

let isDate: unknown => bool = %raw(`v => v instanceof Date`)

// Columns whose comparison needs a specific object shape. The rest compare
// natively, so whatever they're handed is already safe.
let expectedValueType = (field: Table.field) =>
  switch field.fieldType {
  | Date => Some(field.isArray ? "an array of Date" : "a Date")
  | Bytea => Some(field.isArray ? "an array of Uint8Array" : "a Uint8Array")
  | _ => None
  }

// Whether this column's values can reach JSON when a key is built. Date, Bytea
// and BigDecimal collapse to a primitive first, and an array's elements follow
// the same rule as the scalar they hold.
let keyUsesSerializer = (field: Table.field) =>
  switch field.fieldType {
  | Date | Bytea | BigDecimal(_) => false
  | _ => true
  }

let matchesFieldType = (value: unknown, ~field: Table.field) => {
  let matchesScalar = value =>
    switch field.fieldType {
    | Date => value->isDate
    | Bytea => value->Utils.Bytes.asUint8Array->Option.isSome
    | _ => true
    }
  field.isArray
    ? value->Array.isArray &&
        value->(Utils.magic: unknown => array<unknown>)->Array.every(matchesScalar)
    : value->matchesScalar
}

// Runs once per getWhere registration, before the filter reaches an index or a
// query, so a bad field, operator or value is reported against the call the
// handler made rather than surfacing later as a comparator or SQL failure.
let validateOrThrow = (filter: t, ~entityName, ~table: Table.table): unit => {
  let filterKeys = filter->Dict.keysToArray

  if filterKeys->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty filter passed to context.${entityName}.getWhere(). Please provide a filter like { fieldName: { _eq: value } }.`,
    )
  }

  filterKeys->Array.forEach(apiFieldName => {
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

    let field = switch table->Table.getFieldByApiName(apiFieldName) {
    | None =>
      JsError.throwWithMessage(
        `Invalid field "${apiFieldName}" in context.${entityName}.getWhere(). The field doesn't exist. ${codegenHelpMessage}`,
      )
    | Some(DerivedFrom(_)) =>
      JsError.throwWithMessage(
        `The field "${apiFieldName}" on entity "${entityName}" is a derived field and cannot be used in getWhere(). Use the source entity's indexed field instead.`,
      )
    | Some(Field(field)) => field
    }

    // Constant per field, and None for every column that accepts any runtime
    // shape — so the per-value check below is a single comparison on the path
    // that matters, an _in of many values that are all about to pass.
    let expectedType = field->expectedValueType
    let checkKeyable = field->keyUsesSerializer

    operatorKeys->Array.forEach(operatorKey => {
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
      let throwUnexpectedType = (~typeName, ~hint) =>
        JsError.throwWithMessage(
          `Invalid value passed to context.${entityName}.getWhere({ ${apiFieldName}: { ${operatorKey}: ... } }). The field "${apiFieldName}" expects ${typeName}.${hint}`,
        )
      let throwUnkeyable = (~hint) =>
        JsError.throwWithMessage(
          `Invalid value passed to context.${entityName}.getWhere({ ${apiFieldName}: { ${operatorKey}: ... } }). The value can't be serialized, so it can't be used as a filter. An object holding a bigint, or a circular reference, is not supported.${hint}`,
        )

      switch operatorKey {
      | "_in" => {
          if !(fieldValue->Array.isArray) {
            JsError.throwWithMessage(
              `Invalid value passed to context.${entityName}.getWhere({ ${apiFieldName}: { _in: ... } }). The _in operator expects an array of values.`,
            )
          }
          let fieldValues = fieldValue->(Utils.magic: unknown => array<unknown>)

          fieldValues->Array.forEachWithIndex(
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
              switch expectedType {
              | Some(typeName) if !(fieldValue->matchesFieldType(~field)) =>
                throwUnexpectedType(
                  ~typeName,
                  ~hint=` The value is at index ${index->Int.toString} of the _in array.`,
                )
              | _ => ()
              }
              if checkKeyable && !(fieldValue->isKeyable) {
                throwUnkeyable(
                  ~hint=` The value is at index ${index->Int.toString} of the _in array.`,
                )
              }
            },
          )
        }
      | _ =>
        switch expectedType {
        | Some(typeName) if !(fieldValue->matchesFieldType(~field)) =>
          throwUnexpectedType(~typeName, ~hint="")
        | _ => ()
        }
        if checkKeyable && !(fieldValue->isKeyable) {
          throwUnkeyable(~hint="")
        }
      }
    })
  })
}

// Values bound to the query's $N placeholders, in the order it binds them.
let getParams = (filter: t) => {
  let params = []
  filter->Utils.Dict.forEachWithKey((operators, _) =>
    operators->Utils.Dict.forEachWithKey((fieldValue, _) => params->Array.push(fieldValue)->ignore)
  )
  params
}

// The one shape a value can key an index or a merged query by: a single field
// under a single operator.
let asSingleOperator = (filter: t) =>
  switch filter->Dict.keysToArray {
  | [fieldName] =>
    let operators = filter->Dict.getUnsafe(fieldName)
    switch operators->Dict.keysToArray {
    | [operator] => Some((fieldName, operator, operators->Dict.getUnsafe(operator)))
    | _ => None
    }
  | _ => None
  }

// Collapses filters sharing an operation key into fewer storage queries:
// _eq and _in batches merge into a single _in on the field. The rest have no
// lossless single-query form without an Or operator, so they stay as is.
// Expects a homogeneous batch — filters with the same operation key.
// A mismatched filter throws: dropping it would leave its already
// registered index without the matching db rows, silently losing data.
let throwUnmergeable = (filter: t) =>
  JsError.throwWithMessage(
    `Unexpected ${switch filter->asSingleOperator {
      | Some((_, operator, _)) => operator
      | None => "composite"
      }} filter in a merged batch. Filters batched into a single query must use the same operator and field.`,
  )

let merge = (filters: array<t>) =>
  switch filters {
  | [] | [_] => filters
  | _ =>
    switch filters->Array.getUnsafe(0)->asSingleOperator {
    | Some((fieldName, ("_eq" | "_in") as operator, _)) =>
      let values = []
      filters->Array.forEach(filter =>
        switch filter->asSingleOperator {
        | Some((candidateField, candidateOperator, fieldValue))
          if candidateField === fieldName && candidateOperator === operator =>
          if operator === "_in" {
            fieldValue
            ->(Utils.magic: unknown => array<unknown>)
            ->Array.forEach(value => values->Array.push(value)->ignore)
          } else {
            values->Array.push(fieldValue)->ignore
          }
        | _ => throwUnmergeable(filter)
        }
      )
      [
        Dict.fromArray([
          (fieldName, dict{"_in": values->(Utils.magic: array<unknown> => unknown)}),
        ]),
      ]
    | _ => filters
    }
  }

// A predicate specialized to a single filter. The field's comparison is
// resolved once from the table config, so per-entity matching avoids both the
// operator dispatch and the polymorphic compare.
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
  // Projects a value onto something a Map can key by. Primitives key by
  // themselves; the object-shaped types have to collapse to a primitive or
  // equal values would miss each other on identity.
  key: unknown => unknown,
}

// `>`/`<` on `unknown` would compile to the polymorphic Primitive_object path; the raw
// operators give native JS comparison for primitive (string/number/bigint)
// fields. `===` is already physical equality.
let nativeEq = (a: unknown, b: unknown) => a === b
let nativeGt: (unknown, unknown) => bool = %raw(`(a, b) => a > b`)
let nativeLt: (unknown, unknown) => bool = %raw(`(a, b) => a < b`)
let identityKey = (v: unknown) => v
let native = {eq: nativeEq, gt: nativeGt, lt: nativeLt, key: identityKey}

// A nullable column holds null where a row has no value, and a comparison that
// calls a method on it would throw. Matching nothing is what SQL does, and
// saying so once here keeps every comparison below a plain two-value compare.
// The filter's own value needs no such guard — validation rejects a nullish one.
let nullSafe = (compare: valueCompare): valueCompare => {
  eq: (a, b) => !(a->nullish) && compare.eq(a, b),
  gt: (a, b) => !(a->nullish) && compare.gt(a, b),
  lt: (a, b) => !(a->nullish) && compare.lt(a, b),
  key: compare.key,
}

let asBigDecimal = (v: unknown) => v->(Utils.magic: unknown => BigDecimal.t)
let bigDecimal = nullSafe({
  eq: (a, b) => BigDecimal.equals(a->asBigDecimal, b->asBigDecimal),
  gt: (a, b) => BigDecimal.gt(a->asBigDecimal, b->asBigDecimal),
  lt: (a, b) => BigDecimal.lt(a->asBigDecimal, b->asBigDecimal),
  key: v => v->asBigDecimal->BigDecimal.toString->(Utils.magic: string => unknown),
})

let getTime = (v: unknown) => v->(Utils.magic: unknown => Date.t)->Date.getTime
let date = nullSafe({
  eq: (a, b) => getTime(a) === getTime(b),
  gt: (a, b) => getTime(a) > getTime(b),
  lt: (a, b) => getTime(a) < getTime(b),
  key: v => v->getTime->(Utils.magic: float => unknown),
})

// Json has no meaningful ordering, so reuse the structural compare for every
// operator. Polymorphic `==` is intentional here.
let json = nullSafe({
  eq: (a: unknown, b: unknown) => a == b,
  gt: (a, b) => a > b,
  lt: (a, b) => a < b,
  key: v => v->jsonStringify->(Utils.magic: string => unknown),
})

let asBytes = (v: unknown) => v->(Utils.magic: unknown => Uint8Array.t)
let bytes = nullSafe({
  eq: (a, b) => Utils.Bytes.compare(a->asBytes, b->asBytes) === 0.,
  gt: (a, b) => Utils.Bytes.compare(a->asBytes, b->asBytes) > 0.,
  lt: (a, b) => Utils.Bytes.compare(a->asBytes, b->asBytes) < 0.,
  key: v => v->asBytes->Utils.Bytes.toHex->(Utils.magic: string => unknown),
})

let scalarCompare = (fieldType: Table.fieldType): valueCompare =>
  switch fieldType {
  | BigDecimal(_) => bigDecimal
  | Date => date
  | Json => json
  | Bytea => bytes
  | String
  | Boolean
  | Uint32
  | UInt52
  | SmallInt
  | UInt64
  | Int32
  | ChainId
  | Number
  | BigInt(_)
  | Serial
  | BigSerial
  | Enum(_) => native
  }

let asArray = (v: unknown) => v->(Utils.magic: unknown => array<unknown>)

// Array-valued fields compare element-wise with the element type's comparator:
// equality is length + pairwise eq, ordering is lexicographic where the first
// differing element decides and a proper prefix is the smaller array. The key
// follows the same rule, concatenating each element's own key, so a Date[]
// keys by epoch millis and a Bytea[] by hex without inspecting a value.
let arrayCompare = (element: valueCompare): valueCompare => {
  let eq = (a, b) => {
    let a = a->asArray
    let b = b->asArray
    let len = a->Array.length
    len === b->Array.length && {
        let rec go = i =>
          i >= len || (element.eq(a->Array.getUnsafe(i), b->Array.getUnsafe(i)) && go(i + 1))
        go(0)
      }
  }
  let order = (~gt) =>
    (a, b) => {
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
          } else if gt {
            element.gt(x, y)
          } else {
            element.lt(x, y)
          }
        }
      go(0)
    }
  nullSafe({
    eq,
    gt: order(~gt=true),
    lt: order(~gt=false),
    key: v => {
      let key = ref("")
      v->asArray->Array.forEach(item => key := key.contents ++ encodeValueKey(element.key(item)))
      key.contents->(Utils.magic: string => unknown)
    },
  })
}

// Built once per table: an array field's comparator closes over its element's,
// so resolving it per lookup would allocate that chain on every getWhere.
let comparesByField: Table.table => dict<
  valueCompare,
> = Utils.WeakMap.memoize((table: Table.table) => {
  let compares = Dict.make()
  table.fields->Array.forEach(field =>
    switch field {
    | Field(field) =>
      let element = scalarCompare(field.fieldType)
      compares->Dict.set(
        field->Table.getApiFieldName,
        field.isArray ? arrayCompare(element) : element,
      )
    | DerivedFrom(_) => ()
    }
  )
  compares
})

let fieldCompare = (~table: Table.table, fieldName) =>
  switch table->comparesByField->Utils.Dict.dangerouslyGetNonOption(fieldName) {
  // Filters are validated against the table before reaching here, so a
  // missing or derived field is unexpected; compare structurally instead of
  // crashing.
  | None => json
  | Some(compare) => compare
  }

// Projects a field's values onto Map keys, so an index can be found by value
// instead of by a serialized filter.
let makeValueKey = (~table: Table.table, ~fieldName) => (fieldName->fieldCompare(~table)).key

// The cache key stands in for structural equality between filters. Values go
// through the same per-field projection the equality buckets key by, so the
// two agree on which values are distinct.
let toString = (filter: t, ~table: Table.table) => {
  let key = ref("")
  filter->Utils.Dict.forEachWithKey((operators, fieldName) => {
    let keyOf = makeValueKey(~table, ~fieldName)
    operators->Utils.Dict.forEachWithKey((fieldValue, operator) => {
      key := key.contents ++ fieldName ++ operator
      if operator === "_in" {
        fieldValue
        ->(Utils.magic: unknown => array<unknown>)
        ->Array.forEach(
          value => key := key.contents ++ encodeValueKey(keyOf(value)),
        )
      } else {
        key := key.contents ++ encodeValueKey(keyOf(fieldValue))
      }
    })
  })
  key.contents
}

// Values are replaced by placeholders so calls that differ only in what they
// filter for batch together.
let toOperationKey = (filter: t, ~entityName) => {
  let params = ref(0)
  let printed = ref("")
  filter->Utils.Dict.forEachWithKey((operators, fieldName) => {
    let ops = ref("")
    // An _eq on its own is written without the operator, the way the user does.
    let loneEq = ref(false)
    operators->Utils.Dict.forEachWithKey((_, operator) => {
      params := params.contents + 1
      let part = `${operator}: $${params.contents->Int.toString}`
      loneEq := ops.contents === "" && operator === "_eq"
      ops := (ops.contents === "" ? part : ops.contents ++ ", " ++ part)
    })
    let part = loneEq.contents
      ? `${fieldName}: $${params.contents->Int.toString}`
      : `${fieldName}: {${ops.contents}}`
    printed := (printed.contents === "" ? part : printed.contents ++ ", " ++ part)
  })
  `${entityName}.getWhere({${printed.contents}})`
}

let makeMatcher = (filter: t, ~table: Table.table): matcher => {
  let checks = []
  filter->Utils.Dict.forEachWithKey((operators, fieldName) => {
    let compare = fieldName->fieldCompare(~table)
    operators->Utils.Dict.forEachWithKey((fieldValue, operator) => {
      let check = switch operator {
      | "_eq" => entity => compare.eq(entity->getField(fieldName), fieldValue)
      | "_gt" => entity => compare.gt(entity->getField(fieldName), fieldValue)
      | "_lt" => entity => compare.lt(entity->getField(fieldName), fieldValue)
      | "_gte" =>
        entity => {
          let entityFieldValue = entity->getField(fieldName)
          compare.eq(entityFieldValue, fieldValue) || compare.gt(entityFieldValue, fieldValue)
        }
      | "_lte" =>
        entity => {
          let entityFieldValue = entity->getField(fieldName)
          compare.eq(entityFieldValue, fieldValue) || compare.lt(entityFieldValue, fieldValue)
        }
      | "_in" =>
        let fieldValues = fieldValue->(Utils.magic: unknown => array<unknown>)
        if compare.eq === nativeEq {
          let set = fieldValues->Utils.Set.fromArray
          entity => set->Utils.Set.has(entity->getField(fieldName))
        } else {
          entity => {
            let entityFieldValue = entity->getField(fieldName)
            fieldValues->Array.some(candidate => compare.eq(entityFieldValue, candidate))
          }
        }
      | _ =>
        JsError.throwWithMessage(
          `Invalid operator "${operator}" in a getWhere filter. Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
        )
      }
      checks->Array.push(check)->ignore
    })
  })
  switch checks {
  | [check] => check
  | _ => entity => checks->Array.every(check => check(entity))
  }
}
