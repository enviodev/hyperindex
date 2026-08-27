// SQL for the resolver `db` handle's typed entity loaders.
//
// Written against the entity table definitions rather than raw rows, so the
// resolver path reads entities the way the indexer writes them: column names
// come from the table's own field mapping, filter values are serialized with
// each field's schema, and rows are decoded with `Table.pgRowsSchema`. A
// `db.find` therefore hands back what a handler's `context.<Entity>.get` does,
// BigInt and enum values included.
//
// The operator vocabulary is `getWhere`'s, so one filter syntax spans handlers
// and resolvers. The translation is deliberately not shared with
// `EntityFilter.parseGetWhereOrThrow`: that expands `_in` and `_gte` into a
// disjunction for the load layer to memoize per value, which here would turn
// one indexed query into several.

type orderBy = {field: string, direction: string}

type findOptions = {
  entityConfig: Internal.entityConfig,
  pgSchema: string,
  where?: dict<unknown>,
  orderBy?: array<orderBy>,
  limit?: int,
  offset?: int,
}

type query = {text: string, params: array<JSON.t>}

let quoted = (~pgSchema, ~tableName) => `"${pgSchema}"."${tableName}"`

let getQueryFieldOrThrow = (~table: Table.table, ~entityName, ~apiFieldName, ~where) =>
  switch table->Table.queryFields->Dict.get(apiFieldName) {
  | Some(queryField) => queryField
  | None =>
    JsError.throwWithMessage(
      `Invalid field "${apiFieldName}" in db.find("${entityName}", { ${where}: ... }). The entity has no such field.`,
    )
  }

let bindOrThrow = (
  ~queryField: Table.queryField,
  ~entityName,
  ~apiFieldName,
  ~operator,
  ~value: unknown,
  ~isArray,
  ~params: array<JSON.t>,
) => {
  let json = try value->S.reverseConvertToJsonOrThrow(
    isArray ? queryField.arrayFieldSchema : queryField.fieldSchema,
  ) catch {
  | exn =>
    let reason = switch exn {
    | JsExn(e) => e->JsExn.message->Option.getOr("it isn't the field's type")
    | _ => "it isn't the field's type"
    }
    JsError.throwWithMessage(
      `Invalid value for db.find("${entityName}", { where: { ${apiFieldName}: { ${operator}: ... } } }): ${reason}`,
    )
  }
  params->Array.push(json)->ignore
  `$${params->Array.length->Int.toString}`
}

let makeWhereCondition = (~table, ~entityName, ~where: dict<unknown>, ~params) => {
  let apiFieldNames = where->Dict.keysToArray
  if apiFieldNames->Array.length === 0 {
    JsError.throwWithMessage(
      `Empty where passed to db.find("${entityName}"). Drop it, or filter like { fieldName: { _eq: value } }.`,
    )
  }
  apiFieldNames
  ->Array.flatMap(apiFieldName => {
    let queryField = getQueryFieldOrThrow(~table, ~entityName, ~apiFieldName, ~where="where")
    let operators = where->Dict.getUnsafe(apiFieldName)
    if operators->typeof !== #object || operators->Array.isArray || operators === %raw(`null`) {
      JsError.throwWithMessage(
        `Invalid value in db.find("${entityName}", { where: { ${apiFieldName}: ... } }). Provide an operator like { _eq: value }.`,
      )
    }
    let operators = operators->(Utils.magic: unknown => dict<unknown>)
    let operatorKeys = operators->Dict.keysToArray
    if operatorKeys->Array.length === 0 {
      JsError.throwWithMessage(
        `Empty operator in db.find("${entityName}", { where: { ${apiFieldName}: {} } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
      )
    }
    operatorKeys->Array.map(operator => {
      let value = operators->Dict.getUnsafe(operator)
      let bind = (~isArray=false) =>
        bindOrThrow(~queryField, ~entityName, ~apiFieldName, ~operator, ~value, ~isArray, ~params)
      let column = `"${queryField.pgDbFieldName}"`
      switch operator {
      | "_eq" => `${column} = ${bind()}`
      | "_gt" => `${column} > ${bind()}`
      | "_lt" => `${column} < ${bind()}`
      | "_gte" => `${column} >= ${bind()}`
      | "_lte" => `${column} <= ${bind()}`
      | "_in" =>
        if !(value->Array.isArray) {
          JsError.throwWithMessage(
            `Invalid value in db.find("${entityName}", { where: { ${apiFieldName}: { _in: ... } } }). _in takes an array.`,
          )
        }
        `${column} = ANY(${bind(~isArray=true)})`
      | _ =>
        JsError.throwWithMessage(
          `Invalid operator "${operator}" in db.find("${entityName}", { where: { ${apiFieldName}: { ${operator}: ... } } }). Valid operators are _eq, _gt, _lt, _gte, _lte, _in.`,
        )
      }
    })
  })
  ->Array.join(" AND ")
}

let makeOrderByClause = (~table, ~entityName, ~orderBy: array<orderBy>) =>
  switch orderBy {
  | [] => ""
  | orderBy =>
    " ORDER BY " ++
    orderBy
    ->Array.map(({field, direction}) => {
      let queryField = getQueryFieldOrThrow(
        ~table,
        ~entityName,
        ~apiFieldName=field,
        ~where="orderBy",
      )
      let direction = switch direction->String.toLowerCase {
      | "asc" => "ASC"
      | "desc" => "DESC"
      | other =>
        JsError.throwWithMessage(
          `Invalid direction "${other}" in db.find("${entityName}", { orderBy: [{ field: "${field}" }] }). Use "asc" or "desc".`,
        )
      }
      `"${queryField.pgDbFieldName}" ${direction}`
    })
    ->Array.join(", ")
  }

// Bound rather than spliced: a count reaching SQL as a parameter can't widen
// the statement no matter where the resolver got it from.
let makeBoundCount = (~keyword, ~entityName, ~count, ~params: array<JSON.t>) => {
  if count < 0 || count->Int.toFloat->Math.trunc !== count->Int.toFloat {
    JsError.throwWithMessage(
      `Invalid ${keyword->String.toLowerCase} ${count->Int.toString} in db.find("${entityName}"). It must be a non-negative whole number.`,
    )
  }
  params->Array.push(JSON.Encode.int(count))->ignore
  ` ${keyword} $${params->Array.length->Int.toString}`
}

let makeFindQuery = (options: findOptions): query => {
  let {entityConfig, pgSchema} = options
  let table = entityConfig.table
  let entityName = entityConfig.name
  let params = []

  let whereClause = switch options.where {
  | None => ""
  | Some(where) => " WHERE " ++ makeWhereCondition(~table, ~entityName, ~where, ~params)
  }
  let orderByClause = switch options.orderBy {
  | None => ""
  | Some(orderBy) => makeOrderByClause(~table, ~entityName, ~orderBy)
  }
  let limitClause = switch options.limit {
  | None => ""
  | Some(count) => makeBoundCount(~keyword="LIMIT", ~entityName, ~count, ~params)
  }
  let offsetClause = switch options.offset {
  | None => ""
  | Some(count) => makeBoundCount(~keyword="OFFSET", ~entityName, ~count, ~params)
  }

  {
    text: `SELECT * FROM ${quoted(
        ~pgSchema,
        ~tableName=table.tableName,
      )}${whereClause}${orderByClause}${limitClause}${offsetClause};`,
    params,
  }
}

// `id` alone identifies a row only on a cross-chain entity: a per-chain table
// is keyed by (id, chain id), so a bare `get` there would answer with whichever
// chain's row Postgres reached first.
let makeGetQuery = (
  entityConfig: Internal.entityConfig,
  pgSchema: string,
  id: unknown,
): query => {
  let table = entityConfig.table
  let entityName = entityConfig.name
  switch table->Table.getChainIdField {
  | Some(_) =>
    JsError.throwWithMessage(
      `db.get("${entityName}", id) is ambiguous: the entity is per-chain, so the same id can exist on every chain. Use db.find("${entityName}", { where: { id: { _eq: id }, ${Config.chainIdFieldName}: { _eq: chainId } } }).`,
    )
  | None => ()
  }
  // Bound through the id field's own schema, like every other value: the
  // loaders must not be the one place a value reaches SQL unconverted.
  let params = []
  let queryField = getQueryFieldOrThrow(
    ~table,
    ~entityName,
    ~apiFieldName=Table.idFieldName,
    ~where="where",
  )
  let placeholder = bindOrThrow(
    ~queryField,
    ~entityName,
    ~apiFieldName=Table.idFieldName,
    ~operator="_eq",
    ~value=id,
    ~isArray=false,
    ~params,
  )
  {
    text: `SELECT * FROM ${quoted(
        ~pgSchema,
        ~tableName=table.tableName,
      )} WHERE "${queryField.pgDbFieldName}" = ${placeholder} LIMIT 1;`,
    params,
  }
}

let decodeRows = (entityConfig: Internal.entityConfig, rows: array<unknown>): array<unknown> =>
  rows->S.parseOrThrow(entityConfig.table->Table.pgRowsSchema)

type chainHeight = {
  chainId: ChainId.t,
  ecosystem: string,
  startBlock: int,
  endBlock: Null.t<int>,
  sourceBlock: int,
  bufferBlock: int,
  progressBlock: int,
  readyAt: Null.t<Date.t>,
  isReady: bool,
}

// `envio_chains` is read by column rather than with `Table.pgRowsSchema`: the
// table's BIGINT columns come back from the driver as strings, which is why
// every other raw read of it casts on the way out. Only the watermark columns
// are selected, so none of those are in the result at all.
let chainColumns: array<InternalTable.Chains.field> = [
  #id,
  #ecosystem,
  #start_block,
  #end_block,
  #source_block,
  #buffer_block,
  #progress_block,
  #ready_at,
]

type chainRow = {
  id: unknown,
  ecosystem: string,
  startBlock: int,
  endBlock: option<int>,
  sourceBlock: int,
  bufferBlock: int,
  progressBlock: int,
  readyAt: option<Date.t>,
}

let chainRowsSchema = S.array(
  S.object((s): chainRow => {
    id: s.field((#id: InternalTable.Chains.field :> string), S.unknown),
    ecosystem: s.field((#ecosystem: InternalTable.Chains.field :> string), S.string),
    startBlock: s.field((#start_block: InternalTable.Chains.field :> string), S.int),
    endBlock: s.field((#end_block: InternalTable.Chains.field :> string), S.null(S.int)),
    sourceBlock: s.field((#source_block: InternalTable.Chains.field :> string), S.int),
    bufferBlock: s.field((#buffer_block: InternalTable.Chains.field :> string), S.int),
    progressBlock: s.field((#progress_block: InternalTable.Chains.field :> string), S.int),
    readyAt: s.field(
      (#ready_at: InternalTable.Chains.field :> string),
      S.null(Utils.Schema.dbDate),
    ),
  }),
)

let makeChainHeightsQuery = (pgSchema: string): query => {
  text: `SELECT ${chainColumns
    ->Array.map(column => `"${(column :> string)}"`)
    ->Array.join(", ")} FROM ${quoted(
      ~pgSchema,
      ~tableName=InternalTable.Chains.table.tableName,
    )};`,
  params: [],
}

let decodeChainHeights = (rows: array<unknown>): dict<chainHeight> => {
  let heights = Dict.make()
  rows
  ->S.parseOrThrow(chainRowsSchema)
  ->Array.forEach(row => {
    let chainId = row.id->ChainId.normalizeOrThrow
    heights->Dict.set(
      chainId->ChainId.toString,
      {
        chainId,
        ecosystem: row.ecosystem,
        startBlock: row.startBlock,
        endBlock: row.endBlock->Null.fromOption,
        sourceBlock: row.sourceBlock,
        bufferBlock: row.bufferBlock,
        progressBlock: row.progressBlock,
        readyAt: row.readyAt->Null.fromOption,
        isReady: row.readyAt->Option.isSome,
      },
    )
  })
  heights
}
