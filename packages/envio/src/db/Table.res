open Belt

type primitive
type derived

type enum
type enumConfig<'enum> = {
  name: string,
  variants: array<'enum>,
  schema: S.t<'enum>,
}
external fromGenericEnumConfig: enumConfig<'enum> => enumConfig<enum> = "%identity"

let makeEnumConfig = (~name, ~variants) => {
  name,
  variants,
  schema: S.enum(variants),
}

@tag("type")
type fieldType =
  | String
  | Boolean
  | Uint32
  | UInt52
  | UInt64
  | Int32
  | Number
  | BigInt({precision?: int})
  | BigDecimal({config?: (int, int)}) // (precision, scale)
  | Serial
  | BigSerial
  | Json
  | Date
  | Enum({config: enumConfig<enum>})
  | Entity({name: string})

type field = {
  fieldName: string,
  fieldType: fieldType,
  fieldSchema: S.t<unknown>,
  isArray: bool,
  isNullable: bool,
  isPrimaryKey: bool,
  isIndex: bool,
  linkedEntity: option<string>,
  defaultValue: option<string>,
}

type derivedFromField = {
  fieldName: string,
  derivedFromEntity: string,
  derivedFromField: string,
}

type fieldOrDerived = Field(field) | DerivedFrom(derivedFromField)

let mkField = (
  fieldName,
  fieldType,
  ~fieldSchema,
  ~default=?,
  ~isArray=false,
  ~isNullable=false,
  ~isPrimaryKey=false,
  ~isIndex=false,
  ~linkedEntity=?,
) =>
  {
    fieldName,
    fieldType,
    fieldSchema: fieldSchema->S.toUnknown,
    isArray,
    isNullable,
    isPrimaryKey,
    isIndex,
    linkedEntity,
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

let isLinkedEntityField = field => field.linkedEntity->Option.isSome

let getDbFieldName = field =>
  field->isLinkedEntityField ? field.fieldName ++ "_id" : field.fieldName

let getFieldName = fieldOrDerived =>
  switch fieldOrDerived {
  | Field(field) => field->getDbFieldName
  | DerivedFrom({fieldName}) => fieldName
  }

let idFieldName = "id"

let getPgFieldType = (
  ~fieldType: fieldType,
  ~pgSchema,
  ~isArray,
  ~isNumericArrayAsText,
  ~isNullable,
) => {
  let columnType = switch fieldType {
  | String => (Pg.Text :> string)
  | Boolean => (Pg.Boolean :> string)
  | Int32 => (Pg.Integer :> string)
  | Uint32 => (Pg.BigInt :> string)
  | UInt52 => (Pg.BigInt :> string)
  | UInt64 => (Pg.BigInt :> string)
  | Number => (Pg.DoublePrecision :> string)
  | BigInt({?precision}) =>
    (Pg.Numeric :> string) ++
    switch precision {
    | Some(precision) => `(${precision->Int.toString}, 0)` // scale is always 0 for BigInt
    | None => ""
    }

  | BigDecimal({?config}) =>
    (Pg.Numeric :> string) ++
    switch config {
    | Some((precision, scale)) => `(${precision->Int.toString}, ${scale->Int.toString})`
    | None => ""
    }

  | Serial => (Pg.Serial :> string)
  | BigSerial => (Pg.BigSerial :> string)
  | Json => (Pg.JsonB :> string)
  | Date =>
    (isNullable ? Pg.TimestampWithTimezoneNull : Pg.TimestampWithTimezone :> string)
  | Enum({config}) => `"${pgSchema}".${config.name}`
  | Entity(_) => (Pg.Text :> string) // FIXME: Will it work correctly if id is not a text column?
  }

  // Workaround for Hasura bug https://github.com/enviodev/hyperindex/issues/788
  let isNumericAsText = isArray && isNumericArrayAsText
  let columnType = if columnType == (Pg.Numeric :> string) && isNumericAsText {
    (Pg.Text :> string)
  } else {
    columnType
  }

  columnType ++ (isArray ? "[]" : "")
}

type indexFieldDirection = Asc | Desc

type compositeIndexField = {
  fieldName: string,
  direction: indexFieldDirection,
}

type table = {
  tableName: string,
  fields: array<fieldOrDerived>,
  compositeIndices: array<array<compositeIndexField>>,
}

let mkTable = (tableName, ~compositeIndices=[], ~fields) => {
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

let getFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | Field(field) => Some(field)
    | DerivedFrom(_) => None
    }
  )

let getFieldNames = table => {
  table->getFields->Array.map(getDbFieldName)
}

let getNonDefaultFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | Field(field) if field.defaultValue->Option.isNone => Some(field)
    | _ => None
    }
  )

let getLinkedEntityFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | Field({linkedEntity: Some(linkedEntityName)} as field) => Some((field, linkedEntityName))
    | Field({linkedEntity: None})
    | DerivedFrom(_) =>
      None
    }
  )

let getDerivedFromFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | DerivedFrom(field) => Some(field)
    | Field(_) => None
    }
  )

let getNonDefaultFieldNames = table => {
  table->getNonDefaultFields->Array.map(getDbFieldName)
}

let getFieldByName = (table, fieldName) =>
  table.fields->Js.Array2.find(field => field->getUserDefinedFieldName === fieldName)

let getFieldByDbName = (table, dbFieldName) =>
  table.fields->Js.Array2.find(field =>
    switch field {
    | Field(f) => f->getDbFieldName
    | DerivedFrom({fieldName}) => fieldName
    } === dbFieldName
  )

exception NonExistingTableField(string)

/*
Gets all composite indicies (whether they are single indices or not)
And maps the fields defined to their actual db name (some have _id suffix)
*/
let getUnfilteredCompositeIndicesUnsafe = (table): array<array<compositeIndexField>> => {
  table.compositeIndices->Array.map(compositeIndex =>
    compositeIndex->Array.map(indexField => {
      let dbFieldName = switch table->getFieldByName(indexField.fieldName) {
      | Some(field) => field->getFieldName
      | None => raise(NonExistingTableField(indexField.fieldName)) //Unexpected should be validated in schema parser
      }
      {fieldName: dbFieldName, direction: indexField.direction}
    })
  )
}

type sqlParams<'entity> = {
  dbSchema: S.t<'entity>,
  quotedFieldNames: array<string>,
  quotedNonPrimaryFieldNames: array<string>,
  arrayFieldTypes: array<string>,
  hasArrayField: bool,
  jsonFieldIndices: array<int>,
}

let toSqlParams = (table: table, ~schema, ~pgSchema) => {
  let quotedFieldNames = []
  let quotedNonPrimaryFieldNames = []
  let arrayFieldTypes = []
  let hasArrayField = ref(false)
  let jsonFieldIndices = []
  let fieldIndex = ref(0)

  let dbSchema: S.t<Js.Dict.t<unknown>> = S.schema(s =>
    switch schema->S.classify {
    | Object({items}) =>
      let dict = Js.Dict.empty()
      items->Belt.Array.forEach(({location, inlinedLocation, schema}) => {
        let rec coerceSchema = schema =>
          switch schema->S.classify {
          | BigInt => BigInt.schema->S.toUnknown
          | Option(child)
          | Null(child) =>
            S.null(child->coerceSchema)->S.toUnknown
          | Array(child) => {
              hasArrayField := true
              S.array(child->coerceSchema)->S.toUnknown
            }
          | JSON(_) => schema
          | _ => schema
          }

        let field = switch table->getFieldByDbName(location) {
        | Some(field) => field
        | None => raise(NonExistingTableField(location))
        }

        // pg driver doesn't auto-serialize JSONB values like postgres.js did.
        // Check the table field type rather than the schema classification,
        // since the schema may be a typed schema (e.g., effect cache output)
        // that doesn't classify as JSON even though the column is JSONB.
        let coercedSchema = switch field {
        | Field({fieldType: Json}) => {
            jsonFieldIndices->Js.Array2.push(fieldIndex.contents)->ignore
            schema->coerceSchema->S.preprocess(_ => {
              serializer: value =>
                Js.Json.stringify(value->(Utils.magic: unknown => Js.Json.t))->(
                  Utils.magic: string => unknown
                ),
            })
          }
        | _ => schema->coerceSchema
        }
        fieldIndex := fieldIndex.contents + 1

        quotedFieldNames
        ->Js.Array2.push(inlinedLocation)
        ->ignore
        switch field {
        | Field({isPrimaryKey: false}) =>
          quotedNonPrimaryFieldNames
          ->Js.Array2.push(inlinedLocation)
          ->ignore
        | _ => ()
        }

        arrayFieldTypes
        ->Js.Array2.push(
          switch field {
          | Field(f) =>
            let pgFieldType = getPgFieldType(
              ~fieldType=f.fieldType,
              ~pgSchema,
              ~isArray=true,
              ~isNullable=f.isNullable,
              ~isNumericArrayAsText=false, // TODO: Test whether it should be passed via args and match the column type
            )
            switch f.fieldType {
            | Enum(_) => `${(Text: Pg.columnType :> string)}[]::${pgFieldType}`
            | Boolean => `${(Integer: Pg.columnType :> string)}[]::${pgFieldType}`
            | _ => pgFieldType
            }
          | DerivedFrom(_) => (Text: Pg.columnType :> string) ++ "[]"
          },
        )
        ->ignore
        dict->Js.Dict.set(location, s.matches(coercedSchema))
      })
      dict
    | _ => Js.Exn.raiseError("Failed creating db schema. Expected an object schema for table")
    }
  )

  {
    dbSchema: dbSchema->(Utils.magic: S.t<dict<unknown>> => S.t<'entity>),
    quotedFieldNames,
    quotedNonPrimaryFieldNames,
    arrayFieldTypes,
    hasArrayField: hasArrayField.contents,
    jsonFieldIndices,
  }
}

/*
Gets all single indicies
And maps the fields defined to their actual db name (some have _id suffix)
*/
let getSingleIndices = (table): array<string> => {
  let indexFields = table.fields->Array.keepMap(field =>
    switch field {
    | Field(field) if field.isIndex => Some(field->getDbFieldName)
    | _ => None
    }
  )

  table
  ->getUnfilteredCompositeIndicesUnsafe
  //get all composite indices with only 1 field defined
  //this is still a single index
  ->Array.keepMap(cidx =>
    switch cidx {
    | [{fieldName}] => Some([fieldName])
    | _ => None
    }
  )
  ->Array.concat([indexFields])
  ->Array.concatMany
  ->Set.String.fromArray
  ->Set.String.toArray
  ->Js.Array2.sortInPlace
}

/*
Gets all composite indicies
And maps the fields defined to their actual db name (some have _id suffix)
*/
let getCompositeIndices = (table): array<array<compositeIndexField>> => {
  table
  ->getUnfilteredCompositeIndicesUnsafe
  ->Array.keep(ind => ind->Array.length > 1)
}
