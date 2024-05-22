open Belt
@unboxed
type fieldType =
  | @as("INTEGER") Integer
  | @as("BOOL") Bool
  | @as("NUMERIC") Numeric
  | @as("TEXT") Text
  | @as("SERIAL") Serial
  | @as("JSON") Json
  | @as("TIMESTAMP") Timestamp
  | Enum(string)

type derivedFromField = {
  entity: string,
  field: string,
}

type field = {
  fieldName: string,
  fieldType: fieldType,
  isNullable: bool,
  isPrimaryKey: bool,
  isIndex: bool,
  isLinkedEntityField: bool,
  derivedFrom: option<derivedFromField>,
  defaultValue: option<string>,
}

let mkField = (
  ~default=?,
  ~derivedFrom=?,
  ~isNullable=false,
  ~isPrimaryKey=false,
  ~isIndex=false,
  ~isLinkedEntityField=false,
  fieldName,
  fieldType,
) => {
  fieldName,
  fieldType,
  isNullable,
  isPrimaryKey,
  isIndex,
  isLinkedEntityField,
  defaultValue: default,
  derivedFrom,
}

let getFieldName = field => field.isLinkedEntityField ? field.fieldName ++ "_id" : field.fieldName

type table = {
  tableName: string,
  fields: array<field>,
  compositeIndices: array<array<string>>,
}

let mkTable = (~compositeIndices=[], ~fields, tableName) => {
  tableName,
  fields,
  compositeIndices,
}

let getPrimaryKeyFieldNames = table =>
  table.fields->Array.keepMap(field => field.isPrimaryKey ? Some(field.fieldName) : None)

let getSingleIndices = (table): array<string> => {
  let indexFields =
    table.fields->Array.keepMap(field => field.isIndex ? Some(field.fieldName) : None)

  table.compositeIndices
  ->Array.keep(ind => ind->Array.length == 1)
  ->Array.concat([indexFields])
  ->Array.concatMany
  ->Set.String.fromArray
  ->Set.String.toArray
  ->Js.Array2.sortInPlace
}

let getCompositeIndices = (table): array<array<string>> => {
  table.compositeIndices->Array.keep(ind => ind->Array.length > 1)
}

let getFields = table => table.fields->Array.keep(field => field.derivedFrom->Option.isNone)

let getDerivedFromFields = table =>
  table.fields->Array.keep(field => field.derivedFrom->Option.isSome)

let getFieldNames = table => {
  table->getFields->Array.map(getFieldName)
}
