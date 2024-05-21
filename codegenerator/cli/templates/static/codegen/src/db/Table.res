open Belt
@unboxed
type fieldType =
  | @as("INTEGER") Integer
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
