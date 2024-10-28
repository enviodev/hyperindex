open Belt

type primitive
type derived
@unboxed
type fieldType =
  | @as("INTEGER") Integer
  | @as("BOOLEAN") Boolean
  | @as("NUMERIC") Numeric
  | @as("DOUBLE PRECISION") DoublePrecision
  | @as("TEXT") Text
  | @as("SERIAL") Serial
  | @as("JSONB") JsonB
  | @as("TIMESTAMP WITH TIME ZONE") Timestamp
  | @as("TIMESTAMP") TimestampWithoutTimezone
  | @as("TIMESTAMP WITH TIME ZONE NULL") TimestampWithNullTimezone
  | Custom(string)

type field = {
  fieldName: string,
  fieldType: fieldType,
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
  ~default=?,
  ~isArray=false,
  ~isNullable=false,
  ~isPrimaryKey=false,
  ~isIndex=false,
  ~linkedEntity=?,
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

let getFields = table =>
  table.fields->Array.keepMap(field =>
    switch field {
    | Field(field) => Some(field)
    | DerivedFrom(_) => None
    }
  )

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

let getFieldNames = table => {
  table->getFields->Array.map(getDbFieldName)
}

let getNonDefaultFieldNames = table => {
  table->getNonDefaultFields->Array.map(getDbFieldName)
}

let getFieldByName = (table, fieldNameSearch) =>
  table.fields->Js.Array2.find(field => field->getUserDefinedFieldName == fieldNameSearch)

exception NonExistingTableField(string)

/*
Gets all composite indicies (whether they are single indices or not)
And maps the fields defined to their actual db name (some have _id suffix)
*/
let getUnfilteredCompositeIndicesUnsafe = (table): array<array<string>> => {
  table.compositeIndices->Array.map(compositeIndex =>
    compositeIndex->Array.map(userDefinedFieldName =>
      switch table->getFieldByName(userDefinedFieldName) {
      | Some(field) => field->getFieldName
      | None => raise(NonExistingTableField(userDefinedFieldName)) //Unexpected should be validated in schema parser
      }
    )
  )
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
  ->Array.keep(cidx => cidx->Array.length == 1)
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
let getCompositeIndices = (table): array<array<string>> => {
  table
  ->getUnfilteredCompositeIndicesUnsafe
  ->Array.keep(ind => ind->Array.length > 1)
}

module PostgresInterop = {
  type pgFn<'payload, 'return> = (Postgres.sql, 'payload) => promise<'return>
  type batchSetFn<'a> = (Postgres.sql, array<'a>) => promise<unit>
  external eval: string => 'a = "eval"

  let makeBatchSetFnString = (table: table) => {
    let fieldNamesInQuotes =
      table->getNonDefaultFieldNames->Array.map(fieldName => `"${fieldName}"`)
    `(sql, rows) => {
      return sql\`
        INSERT INTO "public"."${table.tableName}"
        \${sql(rows, ${fieldNamesInQuotes->Js.Array2.joinWith(", ")})}
        ON CONFLICT(${table->getPrimaryKeyFieldNames->Js.Array2.joinWith(", ")}) DO UPDATE
        SET
        ${fieldNamesInQuotes
      ->Array.map(fieldNameInQuotes => `${fieldNameInQuotes} = EXCLUDED.${fieldNameInQuotes}`)
      ->Js.Array2.joinWith(", ")};\`
    }`
  }

  let chunkBatchQuery = async (
    sql,
    entityDataArray: array<'entity>,
    queryToExecute: pgFn<array<'entity>, 'return>,
    ~maxItemsPerQuery=500,
  ) => {
    let responses = []
    let i = ref(0)
    let shouldContinue = () => i.contents < entityDataArray->Array.length
    // Split entityDataArray into chunks of maxItemsPerQuery
    while shouldContinue() {
      let chunk =
        entityDataArray->Js.Array2.slice(~start=i.contents, ~end_=i.contents + maxItemsPerQuery)
      let response = await queryToExecute(sql, chunk)
      responses->Js.Array2.push(response)->ignore
      i := i.contents + maxItemsPerQuery
    }
    responses
  }

  let makeBatchSetFn = (~table, ~rowsSchema: S.t<array<'a>>): batchSetFn<'a> => {
    let batchSetFn: pgFn<array<Js.Json.t>, unit> = table->makeBatchSetFnString->eval
    async (sql, rows) => {
      let rowsJson =
        rows->S.serializeOrRaiseWith(rowsSchema)->(Utils.magic: Js.Json.t => array<Js.Json.t>)
      let _res = await chunkBatchQuery(sql, rowsJson, batchSetFn)
    }
  }
}
