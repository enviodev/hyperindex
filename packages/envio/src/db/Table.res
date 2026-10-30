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
  | SmallInt
  // Raw bytes: the `Bytes` scalar under `bytes_type: uint8array`, and the
  // internal column that stores an address in the binary form the Rust address
  // store keys on.
  | Bytea
  | UInt64
  | Int32
  // Resolved to Int32 or UInt64 storage from the config's `ChainId.mode`, so
  // the internal tables can stay module-level constants.
  | ChainId
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
  // The chain-id column appended to a per-chain entity's table. It's part of
  // the primary key but not of the entity schema the handlers see, so the
  // read paths skip it and the write path stamps it from the flush scope.
  isChainId: bool,
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
  ~isChainId=false,
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
    isChainId,
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

let maxPgTableNameLength = 63

// Postgres truncates identifiers past its limit on its own, which would collapse
// two long names onto one. Cutting the readable half and keeping `uniqueSuffix`
// whole makes every generated name distinct by construction, so the suffix has
// to be something already unique to the table it names.
let fitPgTableName = (fullName, ~uniqueSuffix) =>
  if fullName->String.length > maxPgTableNameLength {
    fullName->String.slice(~start=0, ~end=maxPgTableNameLength - uniqueSuffix->String.length) ++
      uniqueSuffix
  } else {
    fullName
  }

type indexFieldDirection = Asc | Desc

type compositeIndexField = {
  fieldName: string,
  direction: indexFieldDirection,
}

type table = {
  tableName: string,
  fields: array<fieldOrDerived>,
  compositeIndexes: array<array<compositeIndexField>>,
  description: option<string>,
}

let mkTable = (tableName, ~compositeIndexes=[], ~fields, ~description=?) => {
  tableName,
  fields,
  compositeIndexes,
  description,
}

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

// The chain-id column of a per-chain entity table. None for cross-chain
// entities and every internal table.
let getChainIdField = (table): option<field> =>
  table.fields->Array.findMap(field =>
    switch field {
    | Field({isChainId: true} as field) => Some(field)
    | _ => None
    }
  )

// None for a cross-chain entity, whose rows no single chain owns.
let getPgChainIdColumn = table => table->getChainIdField->Option.map(getPgDbFieldName)

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

// Resolved once per table, because a getWhere looks up every field it filters
// on and scanning the array made that cost grow with the entity's width.
let fieldsByApiName: table => dict<fieldOrDerived> = Utils.WeakMap.memoize(table => {
  let byApiName = Dict.make()
  table.fields->Array.forEach(field =>
    byApiName->Dict.set(
      switch field {
      | Field(f) => f->getApiFieldName
      | DerivedFrom({fieldName}) => fieldName
      },
      field,
    )
  )
  byApiName
})

let getFieldByApiName = (table, apiFieldName) =>
  table->fieldsByApiName->Utils.Dict.dangerouslyGetNonOption(apiFieldName)

type queryField = {
  fieldType: fieldType,
  isArray: bool,
  fieldSchema: S.t<unknown>,
  // The column a load filters on, which only differs from the API field name
  // keying this entry when column renaming is configured.
  pgDbFieldName: string,
  // The chain-id column a per-chain entity's table is partitioned by.
  isChainId: bool,
}
let queryFields: table => dict<queryField> = Utils.WeakMap.memoize(table => {
  let dict = Dict.make()
  table.fields->Array.forEach(field =>
    switch field {
    | Field(field) =>
      dict->Dict.set(
        field->getApiFieldName,
        {
          fieldType: field.fieldType,
          isArray: field.isArray,
          fieldSchema: field.fieldSchema,
          pgDbFieldName: field->getPgDbFieldName,
          isChainId: field.isChainId,
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
let makeRowsSchema = (table, ~rowFieldName, ~skipChainId=false) =>
  S.array(
    S.object(s => {
      let dict = Dict.make()
      table.fields->Array.forEach(field =>
        switch field {
        | Field({isChainId: true}) if skipChainId => ()
        | Field(field) =>
          dict->Dict.set(field->getApiFieldName, s.field(field->rowFieldName, field.fieldSchema))
        | DerivedFrom(_) => ()
        }
      )
      dict
    })->(Utils.magic: S.t<dict<unknown>> => S.t<unknown>),
  )

// Rows a store returns are keyed by the possibly renamed Postgres column names,
// ClickHouse's included: one schema then parses what either store holds.
let pgRowsSchema: table => S.t<array<unknown>> = Utils.WeakMap.memoize(table =>
  table->makeRowsSchema(~rowFieldName=getPgDbFieldName)
)

// Rows shaped like the entity the handlers see: the chain-id column is dropped,
// since the chain is already known from the scope the rows were loaded for.
let pgEntityRowsSchema: table => S.t<array<unknown>> = Utils.WeakMap.memoize(table =>
  table->makeRowsSchema(~rowFieldName=getPgDbFieldName, ~skipChainId=true)
)

exception NonExistingTableField(string)
