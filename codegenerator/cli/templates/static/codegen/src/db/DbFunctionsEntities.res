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
    switch res->S.parseOrThrow(rowsSchema) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger?,
        ~msg=`Failed to parse rows from database of entity ${table.tableName}`,
      )
    | entities => entities
    }
  }
}

let makeBatchSet = (~table: Table.table, ~schema: S.t<'entity>) => {
  let query = DbFunctions.makeTableBatchSet(table, schema)
  async (sql: Postgres.sql, entities: array<'entity>, ~logger=?) => {
    switch await query(sql, entities) {
    | exception (S.Raised(_) as exn) =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger?,
        ~msg=`Failed during batch serialization of entity ${table.tableName}`,
      )
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~logger?,
        ~msg=`Failed during batch set of entity ${table.tableName}`,
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

let batchRead = (~entityConfig: Internal.entityConfig) => {
  let {table, rowsSchema} = entityConfig
  makeReadEntities(~table, ~rowsSchema)
}

type batchSet<'entity> = (Postgres.sql, array<'entity>, ~logger: Pino.t=?) => promise<unit>
let batchSetCache: Utils.WeakMap.t<
  Internal.entityConfig,
  batchSet<Internal.entity>,
> = Utils.WeakMap.make()
let batchSet = (~entityConfig: Internal.entityConfig): batchSet<Internal.entity> => {
  switch Utils.WeakMap.get(batchSetCache, entityConfig) {
  | None =>
    let query = makeBatchSet(~table=entityConfig.table, ~schema=entityConfig.schema)
    Utils.WeakMap.set(batchSetCache, entityConfig, query)->ignore
    query
  | Some(query) => query
  }
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
