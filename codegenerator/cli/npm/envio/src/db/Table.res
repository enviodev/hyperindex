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
  | Int32
  | Number
  | BigInt({precision?: int})
  | BigDecimal({config?: (int, int)}) // (precision, scale)
  | Serial
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
    fieldSchema: fieldSchema->S.castToUnknown,
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
  | String => (Postgres.Text :> string)
  | Boolean => (Postgres.Boolean :> string)
  | Int32 => (Postgres.Integer :> string)
  | Uint32 => (Postgres.BigInt :> string)
  | Number => (Postgres.DoublePrecision :> string)
  | BigInt({?precision}) =>
    (Postgres.Numeric :> string) ++
    switch precision {
    | Some(precision) => `(${precision->Int.toString}, 0)` // scale is always 0 for BigInt
    | None => ""
    }

  | BigDecimal({?config}) =>
    (Postgres.Numeric :> string) ++
    switch config {
    | Some((precision, scale)) => `(${precision->Int.toString}, ${scale->Int.toString})`
    | None => ""
    }

  | Serial => (Postgres.Serial :> string)
  | Json => (Postgres.JsonB :> string)
  | Date =>
    (isNullable ? Postgres.TimestampWithTimezoneNull : Postgres.TimestampWithTimezone :> string)
  | Enum({config}) => `"${pgSchema}".${config.name}`
  | Entity(_) => (Postgres.Text :> string) // FIXME: Will it work correctly if id is not a text column?
  }

  // Workaround for Hasura bug https://github.com/enviodev/hyperindex/issues/788
  let isNumericAsText = isArray && isNumericArrayAsText
  let columnType = if columnType == (Postgres.Numeric :> string) && isNumericAsText {
    (Postgres.Text :> string)
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

// TODO: Test whether it should be passed via args and match the column type

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
      | None => throw(NonExistingTableField(indexField.fieldName)) //Unexpected should be validated in schema parser
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
}

let toSqlParams = (table: table, ~schema, ~pgSchema) => {
  let quotedFieldNames = []
  let quotedNonPrimaryFieldNames = []
  let arrayFieldTypes = []
  let hasArrayField = ref(false)

  let dbSchema: S.t<dict<unknown>> = S.schema(s =>
    switch schema->(Utils.magic: S.t<'a> => S.t<unknown>) {
    | Object({items}) =>
      let dict = Dict.make()
      items->Belt.Array.forEach(({location, schema}) => {
        let inlinedLocation = `"${location}"`
        let rec coerceSchema = (schema: S.t<unknown>) => {
          let tag = (schema->S.untag).tag
          switch tag {
          | BigInt => BigInt_.schema->S.castToUnknown
          | Union => {
              // Handle S.null(x) / S.option(x) wrappers
              let anyOf: array<S.t<unknown>> = (
                schema->S.untag->(Utils.magic: S.untagged => {..})
              )["anyOf"]
              let hasNullOrUndefined = anyOf->Array.some(
                s => {
                  let t = (s->S.untag).tag
                  t == Null || t == Undefined
                },
              )
              if hasNullOrUndefined {
                let child = anyOf->Js.Array2.find(
                  s => {
                    let t = (s->S.untag).tag
                    t != Null && t != Undefined
                  },
                )
                switch child {
                | Some(c) => S.null(c->coerceSchema)->S.castToUnknown
                | None => schema
                }
              } else {
                schema
              }
            }
          | Array => {
              hasArrayField := true
              let items: array<S.item> = (
                schema->S.untag->(Utils.magic: S.untagged => {..})
              )["items"]
              switch items->Array.get(0) {
              | Some({schema: child}) => S.array(child->coerceSchema)->S.castToUnknown
              | None => schema
              }
            }
          | Unknown => {
              // JSON schema (S.json) has Unknown tag
              hasArrayField := true
              schema
            }
          | Boolean =>
            // Workaround for https://github.com/porsager/postgres/issues/471
            S.union([
              S.literal(1)->S.shape(_ => true),
              S.literal(0)->S.shape(_ => false),
            ])->S.castToUnknown
          | _ => schema
          }
        }

        let field = switch table->getFieldByDbName(location) {
        | Some(field) => field
        | None => throw(NonExistingTableField(location))
        }

        quotedFieldNames
        ->Array.push(inlinedLocation)
        ->ignore
        switch field {
        | Field({isPrimaryKey: false}) =>
          quotedNonPrimaryFieldNames
          ->Array.push(inlinedLocation)
          ->ignore
        | _ => ()
        }

        arrayFieldTypes
        ->Array.push(
          switch field {
          | Field(f) =>
            let pgFieldType = getPgFieldType(
              ~fieldType=f.fieldType,
              ~pgSchema,
              ~isArray=true,
              ~isNullable=f.isNullable,
              ~isNumericArrayAsText=false,
            )
            switch f.fieldType {
            | Enum(_) => `${(Text: Postgres.columnType :> string)}[]::${pgFieldType}`
            | Boolean => `${(Integer: Postgres.columnType :> string)}[]::${pgFieldType}`
            | _ => pgFieldType
            }
          | DerivedFrom(_) => (Text: Postgres.columnType :> string) ++ "[]"
          },
        )
        ->ignore
        dict->Dict.set(location, s.matches(schema->coerceSchema))
      })
      dict
    | _ =>
      JsError.throwWithMessage("Failed creating db schema. Expected an object schema for table")
    }
  )

  {
    dbSchema: dbSchema->(Utils.magic: S.t<dict<unknown>> => S.t<'entity>),
    quotedFieldNames,
    quotedNonPrimaryFieldNames,
    arrayFieldTypes,
    hasArrayField: hasArrayField.contents,
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
