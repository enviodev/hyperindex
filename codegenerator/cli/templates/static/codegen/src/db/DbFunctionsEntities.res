open Belt

type id = string

@module("./DbFunctionsImplementation.js")
external batchReadItemsInTable: (
  ~table: Table.table,
  ~sql: Postgres.sql,
  ~ids: array<id>,
) => promise<array<Js.Json.t>> = "batchReadItemsInTable"

let makeReadEntities = (~table: Table.table, ~rowsSchema: S.t<array<'entityRow>>) => async (
  ~logger=?,
  sql: Postgres.sql,
  ids: array<id>,
): array<'entityRow> => {
  switch await batchReadItemsInTable(~table, ~sql, ~ids) {
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~logger?,
      ~msg=`Failed during batch read of entity ${table.tableName}`,
    )
  | res =>
    switch res->S.parseAnyOrRaiseWith(rowsSchema) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger?,
        ~msg=`Failed to parse rows from database of entity ${table.tableName}`,
      )
    | entitys => entitys
    }
  }
}

@module("./DbFunctionsImplementation.js")
external batchSetItemsInTable: (
  ~table: Table.table,
  ~sql: Postgres.sql,
  ~jsonRows: Js.Json.t,
) => promise<unit> = "batchSetItemsInTable"

let makeBatchSet = (~table: Table.table, ~rowsSchema: S.schema<array<'entityRow>>) => async (
  sql: Postgres.sql,
  entities: array<'entityRow>,
  ~logger=?,
) => {
  switch entities->S.serializeOrRaiseWith(rowsSchema) {
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(
      ~logger?,
      ~msg=`Failed during batch serialization of entity ${table.tableName}`,
    )
  | jsonRows =>
    switch await batchSetItemsInTable(~table, ~sql, ~jsonRows) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger?,
        ~msg=`Failed during batch read of entity ${table.tableName}`,
      )
    | res => res
    }
  }
}

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

@module("./DbFunctionsImplementation.js")
external whereEqQuery: (
  ~table: Table.table,
  ~sql: Postgres.sql,
  ~fieldName: string,
  ~value: Js.Json.t,
) => promise<Js.Json.t> = "whereEqQuery"

let makeWhereEq = (
  ~table: Table.table,
  ~rowsSchema: S.t<array<'entityRow>>,
  ~fieldValueSchema: S.t<'fieldValue>,
  ~fieldName: string,
  ~fieldValue: 'fieldValue,
  ~logger=?,
  sql: Postgres.sql,
) => {
  async (): array<'entityRow> => {
    let logger =
      logger
      ->Option.getWithDefault(Logging.logger)
      ->Logging.createChildFrom(
        ~logger=_,
        ~params={
          "queryType": "whereEq",
          "tableName": table.tableName,
          "fieldName": fieldName,
          "fieldValue": fieldValue,
        },
      )

    let value = switch fieldValue->S.serializeOrRaiseWith(fieldValueSchema) {
    | exception exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg=`Failed to serialize value`)
    | value => value
    }

    switch await whereEqQuery(~table, ~sql, ~fieldName, ~value) {
    | exception exn => exn->ErrorHandling.mkLogAndRaise(~logger, ~msg=`Failed to execute query`)
    | res =>
      switch res->S.parseAnyOrRaiseWith(rowsSchema) {
      | exception exn =>
        exn->ErrorHandling.mkLogAndRaise(
          ~logger,
          ~msg=`Failed to parse rows from database of entity ${table.tableName}`,
        )
      | entitys => entitys
      }
    }
  }
}
