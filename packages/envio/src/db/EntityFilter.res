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

// LoadManager group key and Prometheus operation label. Filters which may
// be batched into a single storage query must produce the same key,
// so concrete values are replaced with $N placeholders.
// Computed on every loadByFilter call, so flat filters are built with
// a single concatenation and only And pays for the param counter.
let toOperationKey = (filter: t, ~entityName) =>
  switch filter {
  | Eq({fieldName}) => `${entityName}.getWhere({${fieldName}: $1})`
  | Gt({fieldName}) => `${entityName}.getWhere({${fieldName}: {_gt: $1}})`
  | Lt({fieldName}) => `${entityName}.getWhere({${fieldName}: {_lt: $1}})`
  | In({fieldName}) => `${entityName}.getWhere({${fieldName}: {_in: $1}})`
  | And(_) => `${entityName}.getWhere({${filter->printOperationFilter(~paramsCount=ref(0))}})`
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

// Canonical declaration of Persistence.StorageError, which re-exports it.
// Declared here so filter helpers can throw it without a dependency cycle:
// Persistence depends on EntityFilter for the storage interface.
exception StorageError({message: string, reason: exn})

// Appends the filter's serialized field values to params (mutated in place)
// and returns the matching SQL condition referencing them by index.
// Field names are spliced as quoted identifiers only after the queryFields
// lookup proves they exist on the table (and they originate from
// codegen-validated schemas), so the interpolation can't be abused.
let rec toSqlCondition = (filter: t, ~table: Table.table, ~params: array<JSON.t>) => {
  let serializeParamOrThrow = (~fieldName, ~fieldValue: unknown, ~isArray) => {
    let queryField = switch table->Table.queryFields->Dict.get(fieldName) {
    | Some(queryField) => queryField
    | None =>
      throw(
        StorageError({
          message: `Failed loading "${table.tableName}" from storage. The table doesn't have the field "${fieldName}".`,
          reason: Table.NonExistingTableField(fieldName),
        }),
      )
    }
    let param = try fieldValue->S.reverseConvertToJsonOrThrow(
      isArray ? queryField.arrayFieldSchema : queryField.fieldSchema,
    ) catch {
    | exn =>
      throw(
        StorageError({
          message: `Failed loading "${table.tableName}" from storage by field "${fieldName}". Couldn't serialize provided value.`,
          reason: exn,
        }),
      )
    }
    params->Array.push(param)->ignore
    `$${params->Array.length->Int.toString}`
  }
  let scalarCondition = (~fieldName, ~fieldValue, ~op) =>
    `"${fieldName}" ${op} ${serializeParamOrThrow(~fieldName, ~fieldValue, ~isArray=false)}`
  switch filter {
  | Eq({fieldName, fieldValue}) => scalarCondition(~fieldName, ~fieldValue, ~op="=")
  | Gt({fieldName, fieldValue}) => scalarCondition(~fieldName, ~fieldValue, ~op=">")
  | Lt({fieldName, fieldValue}) => scalarCondition(~fieldName, ~fieldValue, ~op="<")
  | In({fieldName, fieldValue}) =>
    `"${fieldName}" = ANY(${serializeParamOrThrow(
        ~fieldName,
        ~fieldValue=fieldValue->(Utils.magic: array<unknown> => unknown),
        ~isArray=true,
      )})`
  | And({filters: []}) =>
    throw(
      StorageError({
        message: `Failed loading "${table.tableName}" from storage. The "and" filter must contain at least one nested filter.`,
        reason: Utils.Error.make(`Empty "and" filter`),
      }),
    )
  | And({filters}) =>
    `(${filters
      ->Array.map(filter => filter->toSqlCondition(~table, ~params))
      ->Array.join(" AND ")})`
  }
}

// In values are mapped as one array (isArray=true), so storages can
// serialize them with the table's cached array schema in a single pass.
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
