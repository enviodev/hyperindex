type id = string

@module("./DbFunctionsImplementation.js")
external batchDeleteItemsInTable: (
  ~table: Table.table,
  ~sql: Postgres.sql,
  ~ids: array<id>,
) => promise<unit> = "batchDeleteItemsInTable"

let makeBatchDelete = (~table) => async (~logger=?, sql, ids) =>
  switch await batchDeleteItemsInTable(~table, ~sql, ~ids) {
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~logger?,
      ~msg=`Failed during batch delete of entity ${table.tableName}`,
    )
  | res => res
  }

let batchDelete = (~entityConfig: Internal.entityConfig) => {
  makeBatchDelete(~table=entityConfig.table)
}