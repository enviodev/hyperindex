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
  // An `Address` the handler holds as `0x` and lowercase hex, kept as its
  // `length` raw bytes. One kept as text is a `String`.
  | Address({length: int})

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
  // The string an id keys a dict or Set by, picked from the id column's type
  // so a string id, the common case, is its own key.
  entityIdToKey: EntityId.t => string,
}

let stringEntityIdToKey = (Utils.magic: EntityId.t => string)
// Always a string, never the raw number: a Set tells 7 from "7".
let numericEntityIdToKey = (String.make: EntityId.t => string)
// Hex rather than `String`, which decodes a Buffer as UTF-8 and so collides
// distinct byte sequences.
let bytesEntityIdToKey =
  Utils.Bytes.toHex->(Utils.magic: (Uint8Array.t => string) => EntityId.t => string)

let entityIdToKeyFor = (fields: array<fieldOrDerived>) =>
  switch fields->Array.findMap(field =>
    switch field {
    | Field({fieldName, fieldType}) if fieldName === idFieldName => Some(fieldType)
    | _ => None
    }
  ) {
  | Some(Bytea) => bytesEntityIdToKey
  | Some(String) | Some(Address(_)) | None => stringEntityIdToKey
  | Some(_) => numericEntityIdToKey
  }

let mkTable = (tableName, ~compositeIndexes=[], ~fields, ~description=?) => {
  tableName,
  fields,
  compositeIndexes,
  description,
  entityIdToKey: entityIdToKeyFor(fields),
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

// Bytes keep no case, so an address kept as them takes only the spelling they
// read back as. Any other would be one entity in memory and another, or a
// write failure, in storage: a lookup in it would match the stored row, whose
// bytea hex input ignores case, and miss the entity in memory.
let addressPatterns: dict<RegExp.t> = Dict.make()
let isStoredAddress = (value: unknown, ~length) => {
  let key = length->Int.toString
  let pattern = switch addressPatterns->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(pattern) => pattern
  | None =>
    let pattern = RegExp.fromString(`^0x[0-9a-f]{${(length * 2)->Int.toString}}$`)
    addressPatterns->Dict.set(key, pattern)
    pattern
  }
  typeof(value) === #string && pattern->RegExp.test(value->(Utils.magic: unknown => string))
}

let storedAddressRequirement = (~length) =>
  `0x followed by ${(length * 2)->Int.toString} lowercase hex characters`

%%private(
  let throwInvalidAddress = (value, ~usage, ~length) =>
    JsError.throwWithMessage(
      `Invalid Address "${String.make(
          value,
        )}" ${usage}. An Address is kept here as its ${length->Int.toString} bytes, so it must be ${storedAddressRequirement(
          ~length,
        )}.`,
    )
)

type addressField = {apiFieldName: string, length: int, isArray: bool}

let addressFields: table => array<addressField> = Utils.WeakMap.memoize(table =>
  table.fields->Array.filterMap(field =>
    switch field {
    | Field({fieldType: Address({length}), isArray} as field) =>
      Some({apiFieldName: field->getApiFieldName, length, isArray})
    | _ => None
    }
  )
)

let validateAddressesOrThrow = (table, entity: dict<unknown>, ~entityName) =>
  table
  ->addressFields
  ->Array.forEach(({apiFieldName, length, isArray}) => {
    let check = value =>
      switch value->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.toOption {
      | Some(value) if !(value->isStoredAddress(~length)) =>
        throwInvalidAddress(value, ~usage=`set on ${entityName}.${apiFieldName}`, ~length)
      | _ => ()
      }
    let value = entity->Dict.getUnsafe(apiFieldName)
    if isArray && value->Array.isArray {
      value->(Utils.magic: unknown => array<unknown>)->Array.forEach(check)
    } else {
      check(value)
    }
  })

let validateAddressIdOrThrow = (table, entityId: unknown, ~entityName, ~method) =>
  switch table->addressFields->Array.find(({apiFieldName}) => apiFieldName === idFieldName) {
  | Some({length}) if !(entityId->isStoredAddress(~length)) =>
    throwInvalidAddress(entityId, ~usage=`passed to context.${entityName}.${method}`, ~length)
  | _ => ()
  }

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
