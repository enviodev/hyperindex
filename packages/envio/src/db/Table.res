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
  description: option<string>,
  // Override the column name per storage backend (eg when `column_name_format:
  // snake_case` is configured), while the API keeps using fieldName. The
  // backends can be configured with different formats, so each gets its own override.
  postgresDbName: option<string>,
  clickhouseDbName: option<string>,
}

type derivedFromField = {
  fieldName: string,
  derivedFromEntity: string,
  derivedFromField: string,
  description: option<string>,
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
  ~description=?,
  ~postgresDbName=?,
  ~clickhouseDbName=?,
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
    description,
    postgresDbName,
    clickhouseDbName,
  }->Field

let mkDerivedFromField = (fieldName, ~derivedFromEntity, ~derivedFromField, ~description=?) =>
  {
    fieldName,
    derivedFromField,
    derivedFromEntity,
    description,
  }->DerivedFrom

let getUserDefinedFieldName = fieldOrDerived =>
  switch fieldOrDerived {
  | Field({fieldName})
  | DerivedFrom({fieldName}) => fieldName
  }

let isLinkedEntityField = field => field.linkedEntity->Option.isSome

// The field name exposed to the user-facing APIs (entity records, getWhere,
// Hasura GraphQL). Entity references get an `_id` suffix since the column
// stores the referenced entity id.
let getApiFieldName = field =>
  field->isLinkedEntityField ? field.fieldName ++ "_id" : field.fieldName

// The actual column name in the storage. Matches the API field name unless
// the storage is configured with a different column naming.
let getPgDbFieldName = field =>
  switch field.postgresDbName {
  | Some(dbName) => dbName
  | None => field->getApiFieldName
  }

let getClickHouseDbFieldName = field =>
  switch field.clickhouseDbName {
  | Some(dbName) => dbName
  | None => field->getApiFieldName
  }

let getPgFieldName = fieldOrDerived =>
  switch fieldOrDerived {
  | Field(field) => field->getPgDbFieldName
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
  | UInt52 => (Postgres.BigInt :> string)
  | UInt64 => (Postgres.BigInt :> string)
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
  | BigSerial => (Postgres.BigSerial :> string)
  | Json => (Postgres.JsonB :> string)
  | Date =>
    (isNullable ? Postgres.TimestampWithTimezoneNull : Postgres.TimestampWithTimezone :> string)
  | Enum({config}) => `"${pgSchema}".${config.name}`
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
  description: option<string>,
}

let mkTable = (tableName, ~compositeIndices=[], ~fields, ~description=?) => {
  tableName,
  fields,
  compositeIndices,
  description,
}

let getPgPrimaryKeyFieldNames = table =>
  table.fields->Array.filterMap(field =>
    switch field {
    | Field({isPrimaryKey: true} as field) => Some(field->getPgDbFieldName)
    | _ => None
    }
  )

let getFields = table =>
  table.fields->Array.filterMap(field =>
    switch field {
    | Field(field) => Some(field)
    | DerivedFrom(_) => None
    }
  )

let getNonDefaultFields = table =>
  table.fields->Array.filterMap(field =>
    switch field {
    | Field(field) if field.defaultValue->Option.isNone => Some(field)
    | _ => None
    }
  )

let getLinkedEntityFields = table =>
  table.fields->Array.filterMap(field =>
    switch field {
    | Field({linkedEntity: Some(linkedEntityName)} as field) => Some((field, linkedEntityName))
    | Field({linkedEntity: None})
    | DerivedFrom(_) =>
      None
    }
  )

let getDerivedFromFields = table =>
  table.fields->Array.filterMap(field =>
    switch field {
    | DerivedFrom(field) => Some(field)
    | Field(_) => None
    }
  )

let getFieldByName = (table, fieldName) =>
  table.fields->Array.find(field => field->getUserDefinedFieldName === fieldName)

exception NoIdField(string)

// The `id` primary-key field. Its type drives both the id column and every
// foreign key that references the entity, so id-typed SQL (delete-by-id,
// history backfill) reads the column type and value schema from here.
let getIdFieldOrThrow = (table): field =>
  switch table->getFieldByName(idFieldName) {
  | Some(Field(field)) => field
  | _ => throw(NoIdField(table.tableName))
  }

let getIdPgFieldType = (table, ~pgSchema) =>
  getPgFieldType(
    ~fieldType=(table->getIdFieldOrThrow).fieldType,
    ~pgSchema,
    ~isArray=false,
    ~isNumericArrayAsText=false,
    ~isNullable=false,
  )

// Schema for a single id value, typed opaquely so id-generic code can serialize
// ids regardless of the underlying scalar.
let getIdSchema = (table): S.t<EntityId.t> =>
  (table->getIdFieldOrThrow).fieldSchema->(Utils.magic: S.t<unknown> => S.t<EntityId.t>)

// Serializes an array of ids to the JSON form the SQL layer binds. The array
// schema is memoized per table so its serializer compiles once, not on every
// (high-frequency) delete/history write.
let idsArraySchema: table => S.t<array<EntityId.t>> = Utils.WeakMap.memoize(table =>
  S.array(table->getIdSchema)
)
let encodeIdsToJson = (table, ids: array<EntityId.t>): JSON.t =>
  ids->S.reverseConvertToJsonOrThrow(table->idsArraySchema)

// TODO: Test whether it should be passed via args and match the column type

let getFieldByApiName = (table, apiFieldName) =>
  table.fields->Array.find(field =>
    switch field {
    | Field(f) => f->getApiFieldName
    | DerivedFrom({fieldName}) => fieldName
    } === apiFieldName
  )

// Both schema instances are created once per field: rescript-schema compiles
// and caches operations on the schema instance, so building S.array(fieldSchema)
// per query would recompile the serializer on every call.
type queryField = {
  fieldSchema: S.t<unknown>,
  // Serializes the values array of an "in" filter
  arrayFieldSchema: S.t<unknown>,
  // The Postgres column referenced in load SQL, which only differs from the
  // API field name keying this entry when column renaming is configured.
  // Loads are served by Postgres only (ClickHouse is a write-only sink), so
  // no ClickHouse counterpart is needed here.
  pgDbFieldName: string,
}
let queryFields: table => dict<queryField> = Utils.WeakMap.memoize(table => {
  let dict = Dict.make()
  table.fields->Array.forEach(field =>
    switch field {
    | Field(field) =>
      dict->Dict.set(
        field->getApiFieldName,
        {
          fieldSchema: field.fieldSchema,
          arrayFieldSchema: S.array(field.fieldSchema)->S.toUnknown,
          pgDbFieldName: field->getPgDbFieldName,
        },
      )
    | DerivedFrom(_) => ()
    }
  )
  dict
})

// Parses rows into entity objects keyed by API field names (the camelCase
// record field names are type-level only), reading each value from the
// row key produced by ~rowFieldName.
let makeRowsSchema = (table, ~rowFieldName) =>
  S.array(
    S.object(s => {
      let dict = Dict.make()
      table.fields->Array.forEach(field =>
        switch field {
        | Field(field) =>
          dict->Dict.set(field->getApiFieldName, s.field(field->rowFieldName, field.fieldSchema))
        | DerivedFrom(_) => ()
        }
      )
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<unknown>),
  )

let rowsSchema: table => S.t<array<unknown>> = Utils.WeakMap.memoize(table =>
  table->makeRowsSchema(~rowFieldName=getApiFieldName)
)

// Rows loaded from Postgres are keyed by the possibly renamed column names.
// Lives here rather than in PgStorage because InMemoryStore also parses
// Postgres rollback rows and can't depend on PgStorage without a module
// cycle.
let pgRowsSchema: table => S.t<array<unknown>> = Utils.WeakMap.memoize(table =>
  table->makeRowsSchema(~rowFieldName=getPgDbFieldName)
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
      | Some(field) => field->getPgFieldName
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
    switch schema->S.classify {
    | Object({items}) =>
      let dict = Dict.make()
      items->Array.forEach(({location, schema}) => {
        let rec coerceSchema = schema =>
          switch schema->S.classify {
          | BigInt => Utils.BigInt.schema->S.toUnknown
          | Option(child)
          | Null(child) =>
            S.null(child->coerceSchema)->S.toUnknown
          | Array(child) => {
              hasArrayField := true
              S.array(child->coerceSchema)->S.toUnknown
            }
          | JSON(_) => {
              hasArrayField := true
              schema
            }
          | Bool =>
            // Workaround for https://github.com/porsager/postgres/issues/471
            S.union([
              S.literal(1)->S.shape(_ => true),
              S.literal(0)->S.shape(_ => false),
            ])->S.toUnknown
          | _ => schema
          }

        let field = switch table->getFieldByApiName(location) {
        | Some(field) => field
        | None => throw(NonExistingTableField(location))
        }

        // Schema locations use API field names, while the SQL references
        // columns by their possibly renamed db names.
        let quotedDbName = `"${field->getPgFieldName}"`
        quotedFieldNames
        ->Array.push(quotedDbName)
        ->ignore
        switch field {
        | Field({isPrimaryKey: false}) =>
          quotedNonPrimaryFieldNames
          ->Array.push(quotedDbName)
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
  let indexFields = table.fields->Array.filterMap(field =>
    switch field {
    | Field(field) if field.isIndex => Some(field->getPgDbFieldName)
    | _ => None
    }
  )

  table
  ->getUnfilteredCompositeIndicesUnsafe
  //get all composite indices with only 1 field defined
  //this is still a single index
  ->Array.filterMap(cidx =>
    switch cidx {
    | [{fieldName}] => Some([fieldName])
    | _ => None
    }
  )
  ->Array.concat([indexFields])
  ->Array.flat
  ->Set.fromArray
  ->Set.toArray
  ->Array.toSorted(String.compare)
}

/*
Gets all composite indicies
And maps the fields defined to their actual db name (some have _id suffix)
*/
let getCompositeIndices = (table): array<array<compositeIndexField>> => {
  table
  ->getUnfilteredCompositeIndicesUnsafe
  ->Array.filter(ind => ind->Array.length > 1)
}
