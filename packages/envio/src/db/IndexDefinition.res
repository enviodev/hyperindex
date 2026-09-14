// What the indexer wants an index to be: a table, its ordered key columns with
// their directions, and an access method. That tuple is the index's identity;
// the name is derived from it rather than being part of it, so the catalog can
// always be matched on what an index actually covers.
//
// The identity, the generated name and the DDL are all built by the addon. An
// index has to keep the name it was created under in every schema already
// deployed, so there is one implementation of it rather than two.

let btree = "btree"

type column = {
  name: string,
  direction: Table.indexFieldDirection,
}

type t = {
  tableName: string,
  columns: array<column>,
  method: string,
}

let make = (~tableName, ~columns, ~method=btree) => {tableName, columns, method}

let single = (~tableName, ~column) =>
  make(~tableName, ~columns=[{name: column, direction: Table.Asc}])

let fromIndexFields = (~tableName, ~indexFields: array<Table.compositeIndexField>) =>
  make(
    ~tableName,
    ~columns=indexFields->Array.map(({fieldName, direction}) => {name: fieldName, direction}),
  )

%%private(
  let toColumnInput = ({name, direction}: column): Core.pgIndexColumnInput => {
    name,
    direction: switch direction {
    | Table.Asc => "Asc"
    | Desc => "Desc"
    },
  }
)

%%private(
  let toInput = ({tableName, columns, method}: t): Core.pgIndexInput => {
    tableName,
    columns: columns->Array.map(toColumnInput),
    method,
  }
)

let columnKey = (column: column) => Core.pgIndexColumnKey(~column=column->toColumnInput)

let key = (definition: t) => Core.pgIndexKey(~definition=definition->toInput)

let describe = (definition: t) =>
  `${definition.tableName}(${definition.columns
    ->Array.map(columnKey)
    ->Array.joinUnsafe(", ")}) using ${definition.method}`

let readablePrefix = (definition: t) => Core.pgIndexReadablePrefix(~definition=definition->toInput)

let name = (definition: t) => Core.pgIndexName(~definition=definition->toInput)

let makeCreateQuery = (definition: t, ~pgSchema) =>
  Core.pgIndexCreateQuery(~definition=definition->toInput, ~pgSchema)

let makeDropQuery = (~pgSchema, ~indexName) => Core.pgIndexDropQuery(~pgSchema, ~indexName)
