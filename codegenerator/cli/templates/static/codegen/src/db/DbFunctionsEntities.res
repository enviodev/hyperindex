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

@module("./DbFunctionsImplementation.js")
external whereEqQuery: (
  ~table: Table.table,
  ~sql: Postgres.sql,
  ~fieldName: string,
  ~value: Js.Json.t,
) => promise<Js.Json.t> = "whereEqQuery"

@module("./DbFunctionsImplementation.js")
external whereGtQuery: (
  ~table: Table.table,
  ~sql: Postgres.sql,
  ~fieldName: string,
  ~value: Js.Json.t,
) => promise<Js.Json.t> = "whereGtQuery"

let makeWhereQuery = (sql: Postgres.sql) => async (
  ~operator: TableIndices.Operator.t,
  ~entityConfig: Internal.entityConfig,
  ~fieldName: string,
  ~fieldValue: 'fieldValue,
  ~fieldValueSchema: S.t<'fieldValue>,
  ~logger=Logging.getLogger(),
): array<Internal.entity> => {
  let queryType = switch operator {
  | Eq => "whereEq"
  | Gt => "whereGt"
  }

  let query = switch operator {
  | Eq => whereEqQuery
  | Gt => whereGtQuery
  }

  let logger = Logging.createChildFrom(
    ~logger,
    ~params={
      "queryType": queryType,
      "tableName": entityConfig.table.tableName,
      "fieldName": fieldName,
      "fieldValue": fieldValue,
    },
  )

  let value = switch fieldValue->S.reverseConvertToJsonOrThrow(fieldValueSchema) {
  | exception exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg=`Failed to serialize value`)
  | value => value
  }

  switch await query(~table=entityConfig.table, ~sql, ~fieldName, ~value) {
  | exception exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg=`Failed to execute query`)
  | res =>
    switch res->S.parseOrThrow(entityConfig.rowsSchema) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger,
        ~msg=`Failed to parse rows from database of entity ${entityConfig.table.tableName}`,
      )
    | entities => entities
    }
  }
}
