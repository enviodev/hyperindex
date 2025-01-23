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

let getFieldType = (field: field) => {
  (field.fieldType :> string) ++ (field.isArray ? "[]" : "")
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

type sqlParams<'entity> = {
  dbSchema: S.t<'entity>,
  quotedFieldNames: array<string>,
  quotedNonPrimaryFieldNames: array<string>,
  arrayFieldTypes: array<string>,
  hasArrayField: bool,
}

let toSqlParams = (table: table, ~schema) => {
  let quotedFieldNames = []
  let quotedNonPrimaryFieldNames = []
  let arrayFieldTypes = []
  let hasArrayField = ref(false)

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
          | JSON(_) => {
              hasArrayField := true
              schema
            }
          | Bool =>
            // Workaround for https://github.com/porsager/postgres/issues/471
            S.union([
              S.literal("t")->S.to(_ => true),
              S.literal("f")->S.to(_ => false),
            ])->S.toUnknown
          | _ => schema
          }

        let field = switch table->getFieldByDbName(location) {
        | Some(field) => field
        | None => raise(NonExistingTableField(location))
        }

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
            switch f.fieldType {
            | Custom(fieldType) => `${(Text :> string)}[]::${(fieldType :> string)}`
            | fieldType => (fieldType :> string)
            }
          | DerivedFrom(_) => (Text :> string)
          } ++ "[]",
        )
        ->ignore
        dict->Js.Dict.set(location, s.matches(schema->coerceSchema))
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

  let chunkBatchQuery = (
    sql,
    entityDataArray: array<'entity>,
    queryToExecute: pgFn<array<'entity>, 'return>,
    ~maxItemsPerQuery=500,
  ): promise<array<'return>> => {
    let responses = []
    let i = ref(0)
    let shouldContinue = () => i.contents < entityDataArray->Array.length
    // Split entityDataArray into chunks of maxItemsPerQuery
    while shouldContinue() {
      let chunk =
        entityDataArray->Js.Array2.slice(~start=i.contents, ~end_=i.contents + maxItemsPerQuery)
      let response = queryToExecute(sql, chunk)
      responses->Js.Array2.push(response)->ignore
      i := i.contents + maxItemsPerQuery
    }
    Promise.all(responses)
  }

  let makeBatchSetFn = (~table, ~schema: S.t<'a>): batchSetFn<'a> => {
    let batchSetFn: pgFn<array<Js.Json.t>, unit> = table->makeBatchSetFnString->eval
    let parseOrThrow = S.compile(
      S.array(schema),
      ~input=Value,
      ~output=Json,
      ~mode=Sync,
      ~typeValidation=true,
    )
    async (sql, rows) => {
      let rowsJson = rows->parseOrThrow->(Utils.magic: Js.Json.t => array<Js.Json.t>)
      let _res = await chunkBatchQuery(sql, rowsJson, batchSetFn)
    }
  }
}
