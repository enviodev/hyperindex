open Belt

type primitive
type derived
@unboxed
type fieldType =
  | @as("INTEGER") Integer
  | @as("BOOLEAN") Boolean
  | @as("NUMERIC") Numeric
  | @as("TEXT") Text
  | @as("SERIAL") Serial
  | @as("JSON") Json
  | @as("TIMESTAMP") Timestamp
  | Enum(string)

type field = {
  fieldName: string,
  fieldType: fieldType,
  isArray: bool,
  isNullable: bool,
  isPrimaryKey: bool,
  isIndex: bool,
  isLinkedEntityField: bool,
  defaultValue: option<string>,
}

type derivedFromField = {
  fieldName: string,
  derivedFromEntity: string,
  derivedFromField: string,
}

type fieldOrDerived = Field(field) | DerivedFrom(derivedFromField)

let mkField = (
  ~default=?,
  ~isArray=false,
  ~isNullable=false,
  ~isPrimaryKey=false,
  ~isIndex=false,
  ~isLinkedEntityField=false,
  fieldName,
  fieldType,
) =>
  {
    fieldName,
    fieldType,
    isArray,
    isNullable,
    isPrimaryKey,
    isIndex,
    isLinkedEntityField,
    defaultValue: default,
  }->Field

let mkDerivedFromField = (fieldName, ~derivedFromEntity, ~derivedFromField) =>
  {
    fieldName,
    derivedFromField,
    derivedFromEntity,
  }->DerivedFrom

let getUserDefinedFieldName = fieldOrDerived =>
  switch fieldOrDerived {
  | Field({fieldName})
  | DerivedFrom({fieldName}) => fieldName
  }

let getDbFieldName = field => field.isLinkedEntityField ? field.fieldName ++ "_id" : field.fieldName

let getFieldName = fieldOrDerived =>
  switch fieldOrDerived {
  | Field(field) => field->getDbFieldName
  | DerivedFrom({fieldName}) => fieldName
  }

type table = {
  tableName: string,
  fields: array<fieldOrDerived>,
  compositeIndices: array<array<string>>,
}

let mkTable: 'b. (
  ~compositeIndices: array<array<string>>=?,
  ~fields: array<fieldOrDerived>,
  string,
) => 'c = (~compositeIndices=[], ~fields, tableName) => {
  tableName,
  fields,
  compositeIndices,
}

let getPrimaryKeyFieldNames = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | Field({isPrimaryKey: true, fieldName}) => Some(fieldName)
    | _ => None
    }
  )

let getSingleIndices = (table): array<string> => {
  let indexFields = table.fields->Array.keepMap(field =>
    switch field {
    | Field({isIndex: true, fieldName}) => Some(fieldName)
    | _ => None
    }
  )

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

let getFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | Field(field) => Some(field)
    | DerivedFrom(_) => None
    }
  )

let getDerivedFromFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | DerivedFrom(field) => Some(field)
    | Field(_) => None
    }
  )

let getFieldNames = table => {
  table->getFields->Array.map(getDbFieldName)
}

let getFieldByName = (table, fieldNameSearch) =>
  table.fields->Js.Array2.find(field => field->getUserDefinedFieldName == fieldNameSearch)
