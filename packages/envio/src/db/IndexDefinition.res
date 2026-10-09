// What the indexer wants an index to be: a table, its ordered key columns with
// their directions, and an access method. The addon names it, matches it
// against what PostgreSQL holds and builds it.

type column = {
  name: string,
  direction: Table.indexFieldDirection,
}

type t = {
  tableName: string,
  columns: array<column>,
  method: string,
}

let make = (~tableName, ~columns) => {tableName, columns, method: "btree"}

let single = (~tableName, ~column) =>
  make(~tableName, ~columns=[{name: column, direction: Table.Asc}])

let fromIndexFields = (~tableName, ~indexFields: array<Table.compositeIndexField>) =>
  make(
    ~tableName,
    ~columns=indexFields->Array.map(({fieldName, direction}) => {name: fieldName, direction}),
  )

let toInput = ({tableName, columns, method}: t): Core.pgIndexInput => {
  tableName,
  columns: columns->Array.map(({name, direction}): Core.pgIndexColumnInput => {
    name,
    direction: switch direction {
    | Table.Asc => "Asc"
    | Desc => "Desc"
    },
  }),
  method,
}

let describe = (definition: t) =>
  `${definition.tableName}(${definition.columns
    ->Array.map(({name, direction}) =>
      switch direction {
      | Asc => name
      | Desc => `${name} DESC`
      }
    )
    ->Array.joinUnsafe(", ")}) using ${definition.method}`
