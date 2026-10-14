// The indexer's tables and rows as the ClickHouse store takes them. Rows read
// back keyed by their Postgres column names, so one set of row schemas parses
// what either store returns.

let logger = Logging.createChild(~params={"storage": "clickhouse"})

let fieldTypeName = (fieldType: Table.fieldType) =>
  switch fieldType {
  | String => "String"
  | Boolean => "Boolean"
  | Uint32 => "Uint32"
  | UInt52 => "UInt52"
  | SmallInt =>
    JsError.throwWithMessage("ClickHouse doesn't support the internal SmallInt column type")
  | Bytea => "Bytea"
  | UInt64 => "UInt64"
  | Int32 => "Int32"
  | ChainId => "ChainId"
  | Number => "Number"
  | Serial => "Serial"
  | BigSerial => "BigSerial"
  | Json => "Json"
  | Date => "Date"
  | BigInt(_) => "BigInt"
  | BigDecimal(_) => "BigDecimal"
  | Enum(_) => "Enum"
  }

let column = (
  ~name,
  ~rowName=?,
  ~fieldName=?,
  ~fieldType: Table.fieldType,
  ~isNullable=false,
  ~isArray=false,
): StorageClient.clickHouseColumn => {
  name,
  ?rowName,
  ?fieldName,
  fieldType: fieldType->fieldTypeName,
  isNullable,
  isArray,
  precision: ?switch fieldType {
  | BigInt({?precision}) => precision
  | BigDecimal({?config}) => config->Option.map(((precision, _)) => precision)
  | _ => None
  },
  scale: ?switch fieldType {
  | BigDecimal({?config}) => config->Option.map(((_, scale)) => scale)
  | _ => None
  },
  enumVariants: ?switch fieldType {
  | Enum({config}) =>
    Some(config.variants->Array.map(variant => variant->(Utils.magic: Table.enum => string)))
  | _ => None
  },
}

let fieldColumn = (field: Table.field) =>
  column(
    ~name=field->Table.getClickHouseDbFieldName,
    ~rowName=field->Table.getPgDbFieldName,
    ~fieldName=field.fieldName,
    ~fieldType=field.fieldType,
    ~isNullable=field.isNullable,
    ~isArray=field.isArray,
  )

let entityTable = (entityConfig: Internal.entityConfig): StorageClient.clickHouseTable => {
  let options = entityConfig.storage.clickhouseOptions
  {
    kind: Entity,
    name: entityConfig.name,
    historyTable: EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    ),
    columns: entityConfig.table.fields->Array.filterMap(field =>
      switch field {
      | Table.Field(f) => Some(fieldColumn(f))
      | DerivedFrom(_) => None
      }
    ),
    chainIdColumn: ?(
      entityConfig.table->Table.getChainIdField->Option.map(Table.getClickHouseDbFieldName)
    ),
    partitionBy: ?(options->Option.flatMap(options => options.partitionBy)),
    orderBy: ?(options->Option.flatMap(options => options.orderBy)),
    ttl: ?(options->Option.flatMap(options => options.ttl)),
    skippingIndexes: ?(
      options->Option.flatMap(options =>
        options.skippingIndexes->Option.map(indexes =>
          indexes->Array.map(
            (index): StorageClient.skippingIndex => {
              name: index.name,
              expr: index.expr,
              indexType: index.type_,
              granularity: ?index.granularity,
            },
          )
        )
      )
    ),
  }
}

// A table of the indexer's own: the columns a batch of its rows carries.
let ownTable = (
  ~kind: StorageClient.tableKind,
  ~name,
  ~fields: array<Table.field>,
): StorageClient.clickHouseTable => {
  kind,
  name,
  columns: fields->Array.map(fieldColumn),
}

// Visits every node on the way into JSON text. A bigint would make
// `JSON.stringify` throw and fail the whole batch, so it travels as its digits.
%%private(
  let jsonSafe = (~column) =>
    (_, value: JSON.t) =>
      switch value->typeof {
      | #bigint =>
        value->(Utils.magic: JSON.t => unknown)->Staging.stringOf->(Utils.magic: string => JSON.t)
      // A Uint8Array inside a list column travels as its byte values, which the
      // addon reads back into raw bytes.
      | #object =>
        switch value->(Utils.magic: JSON.t => unknown)->Utils.Bytes.asUint8Array {
        | Some(bytes) =>
          bytes
          ->(Utils.magic: Uint8Array.t => Array.arrayLike<int>)
          ->Array.fromArrayLike
          ->(Utils.magic: array<int> => JSON.t)
        | None => value
        }
      | #number =>
        let _ = value->(Utils.magic: JSON.t => float)->Staging.finiteOrThrow(~column)
        value
      | _ => value
      }
)

type cell = Change.t<Internal.entity> => unknown

type historyCells = {
  setCells: array<cell>,
  deleteCells: array<cell>,
}

type table = {
  handle: int,
  name: string,
  columns: array<Staging.column>,
  // An entity's history cells, by the scope whose chain id they stamp.
  historyCells: dict<historyCells>,
}

let makeTable = (~handle, ~name, {names, kinds, nullable}: StorageClient.clickHouseRegistered) => {
  handle,
  name,
  columns: names->Array.mapWithIndex((name, index): Staging.column => {
    name,
    kind: kinds->Array.getUnsafe(index)->Staging.kindOfOrdinal,
    isNullable: nullable->Array.getUnsafe(index),
    replacer: Replacer(jsonSafe(~column=name)),
  }),
  historyCells: Dict.make(),
}

// A Json column holds the document's text. Staging writes a string as is, so a
// document that is a string has to become its own JSON text here, or it would
// read back as something JSON can't parse. JSON `null` and an absent value are
// both stored as `null`: the column is never Nullable.
%%private(
  let documentText = (value: unknown) =>
    switch value->(Utils.magic: unknown => Nullable.t<JSON.t>) {
    | Value(document) => document->JSON.stringify->(Utils.magic: string => unknown)
    | Null | Undefined => "null"->(Utils.magic: string => unknown)
    }
)

// A nullable document's absence, which a document already rendered as its text
// keeps as null, stored as JSON `null` too.
%%private(
  let documentOrNullText = (value: unknown) =>
    switch value->(Utils.magic: unknown => Nullable.t<unknown>) {
    | Value(_) => value
    | Null | Undefined => "null"->(Utils.magic: string => unknown)
    }
)

%%private(
  let compileSerializer = schema =>
    S.compile(schema, ~input=Value, ~output=Json, ~typeValidation=false, ~mode=Sync)->(
      Utils.magic: (unknown => JSON.t) => unknown => unknown
    )
)

%%private(
  let documentsText = (f: Table.field): (unknown => unknown) =>
    if f.isArray {
      value =>
        switch value->(Utils.magic: unknown => Nullable.t<array<unknown>>) {
        | Value(documents) =>
          documents->Array.map(documentText)->(Utils.magic: array<unknown> => unknown)
        | Null | Undefined => value
        }
    } else {
      documentText
    }
)

// What an entity field's value is staged as.
%%private(
  let serializerOf = (f: Table.field): (unknown => unknown) => {
    let shaped = baseSchema =>
      if f.isNullable {
        Utils.Schema.nullTolerant(baseSchema)->S.toUnknown
      } else if f.isArray {
        S.array(baseSchema)->S.toUnknown
      } else {
        baseSchema
      }
    switch f.fieldType {
    | Json => documentsText(f)
    | Date => compileSerializer(shaped(Utils.Schema.clickHouseDate->S.toUnknown))
    | Bytea => compileSerializer(shaped(S.json(~validate=false)->S.toUnknown))
    | ChainId => compileSerializer(ChainId.schema->S.toUnknown)
    | _ => compileSerializer(f.fieldSchema)
    }
  }
)

@get external changeEntity: Change.t<Internal.entity> => dict<unknown> = "entity"

%%private(let absent: unknown = %raw(`undefined`))

%%private(
  let makeHistoryCells = (
    table,
    ~entityConfig: Internal.entityConfig,
    ~scope: Internal.chainScope,
  ): historyCells => {
    let sourceTable = entityConfig.table
    let chainIdTag = switch (
      sourceTable->Table.getChainIdField,
      scope->Internal.chainScopeChainId,
    ) {
    | (Some(field), Some(chainId)) =>
      Some((field->Table.getClickHouseDbFieldName, chainId->(Utils.magic: ChainId.t => unknown)))
    | _ => None
    }
    let fieldsByColumn = Dict.make()
    sourceTable.fields->Array.forEach(field =>
      switch field {
      | Table.Field(f) => fieldsByColumn->Dict.set(f->Table.getClickHouseDbFieldName, f)
      | DerivedFrom(_) => ()
      }
    )

    let setCells = []
    let deleteCells = []
    let registeredNames = table.columns->Array.map(column => column.name)->Utils.Set.fromArray
    table.columns->Array.forEach(({name}) => {
      let (set, delete) = if name === EntityHistory.checkpointIdFieldName {
        let cell = change => change->Change.getCheckpointId->(Utils.magic: bigint => unknown)
        (cell, cell)
      } else if name === EntityHistory.changeFieldName {
        (
          _ => (EntityHistory.RowAction.SET :> string)->(Utils.magic: string => unknown),
          _ => (EntityHistory.RowAction.DELETE :> string)->(Utils.magic: string => unknown),
        )
      } else {
        switch (chainIdTag, fieldsByColumn->Utils.Dict.dangerouslyGetNonOption(name)) {
        | (Some((column, chainId)), _) if column === name => (_ => chainId, _ => chainId)
        | (_, Some(f)) =>
          let serialize = serializerOf(f)
          let apiName = f->Table.getApiFieldName
          if apiName === Table.idFieldName {
            let cell = change =>
              serialize(change->Change.getEntityId->(Utils.magic: EntityId.t => unknown))
            (cell, cell)
          } else {
            (change => serialize(change->changeEntity->Dict.getUnsafe(apiName)), _ => absent)
          }
        | (_, None) =>
          JsError.throwWithMessage(
            `ClickHouse table "${table.name}" registered a column "${name}" that entity "${entityConfig.name}" has no value for`,
          )
        }
      }
      setCells->Array.push(set)
      deleteCells->Array.push(delete)
    })

    fieldsByColumn->Dict.forEachWithKey((f, column) =>
      if !(registeredNames->Utils.Set.has(column)) {
        JsError.throwWithMessage(
          `ClickHouse table "${table.name}" registered no column for field "${f.fieldName}" of entity "${entityConfig.name}"`,
        )
      }
    )

    {setCells, deleteCells}
  }
)

%%private(
  let stageOrThrow = (arena, table, ~rows, ~fill) => {
    let stage = arena->Staging.begin(~table=table.handle, ~rows, ~columns=table.columns)
    try {
      fill(stage)
      stage->Staging.commit
    } catch {
    | exn =>
      stage->Staging.abort
      throw(
        Persistence.StorageError({
          message: `Failed to convert items for ClickHouse table "${table.name}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
)

// Every change as a row of the entity's history: a deletion keeps only the
// columns that say which entity it removed.
let stageChangesOrThrow = (
  arena,
  table,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~changes: array<Change.t<Internal.entity>>,
) =>
  arena->stageOrThrow(table, ~rows=changes->Array.length, ~fill=stage => {
    let cacheKey = scope->Internal.chainScopeToString
    let cells = switch table.historyCells->Utils.Dict.dangerouslyGetNonOption(cacheKey) {
    | Some(cached) => cached
    | None =>
      let cells = table->makeHistoryCells(~entityConfig, ~scope)
      table.historyCells->Dict.set(cacheKey, cells)
      cells
    }
    let columns = stage->Staging.columnCount
    changes->Array.forEachWithIndex((change, row) => {
      let (cells, write) = switch change {
      | Change.Set(_) => (cells.setCells, Staging.writeValue)
      | Delete(_) => (cells.deleteCells, Staging.writeDeletedValue)
      }
      for column in 0 to columns - 1 {
        stage->write(~column, ~row, (cells->Array.getUnsafe(column))(change))
      }
    })
  })

// Rows of one of the indexer's own tables, a column of values per field in the
// order the table was registered with, as the item schema serialized them —
// documents already their text.
let stageColumnsOrThrow = (
  arena,
  table,
  ~fields: array<Table.field>,
  ~values: array<array<unknown>>,
  ~rows,
) =>
  arena->stageOrThrow(table, ~rows, ~fill=stage =>
    values->Array.forEachWithIndex((column, index) => {
      let isDocument = (fields->Array.getUnsafe(index)).fieldType === Json
      for row in 0 to rows - 1 {
        let value = column->Array.getUnsafe(row)
        stage->Staging.writeValue(
          ~column=index,
          ~row,
          isDocument ? value->documentOrNullText : value,
        )
      }
    })
  )

// Every connection setting has to be there: an unset one would otherwise reach
// the server as an empty value and fail there, for a reason naming neither.
let optionsFromEnvOrThrow = (): StorageClient.clickHouseOptions => {
  let missing = []
  let required = (value, name) =>
    switch value {
    | Some(value) => value
    | None =>
      missing->Array.push(name)
      ""
    }
  let url = Env.ClickHouse.host()->required("ENVIO_CLICKHOUSE_HOST")
  let username = Env.ClickHouse.username()->required("ENVIO_CLICKHOUSE_USERNAME")
  let password = Env.ClickHouse.password()->required("ENVIO_CLICKHOUSE_PASSWORD")
  let database = Env.ClickHouse.database()->required("ENVIO_CLICKHOUSE_DATABASE")
  if missing->Utils.Array.notEmpty {
    JsError.throwWithMessage(
      `ClickHouse storage is enabled but required env vars are not set: ${missing->Array.joinUnsafe(
          ", ",
        )}. Please set them, disable clickhouse in the \`storage\` config, or run \`envio dev\` for a pre-configured local ClickHouse.`,
    )
  }
  {
    url,
    username,
    password,
    database,
    replicated: Env.ClickHouse.replicated(),
    databaseEngine: ?Env.ClickHouse.databaseEngine(),
  }
}
