// What the ClickHouse sink is handed and what comes back out of it.
//
// The schema crosses to Rust as schema — field types, column names, table
// options — and Rust derives the ClickHouse types, renders the DDL and encodes
// the rows from that one derivation. Nothing here decides what a column's
// ClickHouse type is, so there is no second mapping to keep in step.
//
// What stays on this side is what only JS can do: reading entity values out of
// the isolate into the columnar builders a batch is staged from.

// Creates an entity schema from table definition, using clickHouseDate for Date fields.
// Serialized keys are the db column names, while the entity values are keyed
// by API field names (they only differ when column renaming is configured).
let makeClickHouseEntitySchema = (table: Table.table): S.t<Internal.entity> => {
  S.object(s => {
    let dict = Dict.make()
    table.fields->Array.forEach(field => {
      switch field {
      | Field(f) => {
          let fieldName = f->Table.getClickHouseDbFieldName
          let fieldSchema = switch f.fieldType {
          | Date => {
              let dateSchema = Utils.Schema.clickHouseDate->S.toUnknown
              if f.isNullable {
                S.null(dateSchema)->S.toUnknown
              } else if f.isArray {
                S.array(dateSchema)->S.toUnknown
              } else {
                dateSchema
              }
            }
          | ChainId => ChainId.schema->S.toUnknown
          | _ => f.fieldSchema
          }
          dict->Dict.set(f->Table.getApiFieldName, s.field(fieldName, fieldSchema))
        }
      | DerivedFrom(_) => () // Skip derived fields
      }
    })
    dict->(Utils.magic: dict<unknown> => Internal.entity)
  })
}

let logger = Logging.createChild(~params={"context": "ClickHouse"})

// Warnings reach the logger as they happen: a retry storm runs inside a single
// write, so anything handed back at the end would only be read once it is over.
let makeSink = (~host, ~username, ~password, ~database, ~chainIdMode) =>
  ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~chainIdMode, ~onWarning=msg =>
    logger->Logging.childWarn({"msg": msg})
  )

// The schema field a column stores, in the shape the sink reads it. The
// ClickHouse type is Rust's to derive; this only says which field it is.
let makeColumnSpec = (
  ~name,
  ~fieldName=name,
  ~fieldType: Table.fieldType,
  ~isNullable=false,
  ~isArray=false,
): ClickHouseSink.columnSpec => {
  name,
  fieldName,
  fieldType: switch fieldType {
  | String => "String"
  | Boolean => "Boolean"
  | Uint32 => "Uint32"
  | UInt52 => "UInt52"
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
  },
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

// The checkpoints table as ClickHouse holds it, in column order. The DDL, the
// insert's column list and the values it sends all come from this one list, so a
// column cannot be declared in one and forgotten in another — nor, worse, end up
// paired with a different column's values, which nothing downstream could catch:
// every array reaches the builders as `unknown`.
// `events_processed` is widened here rather than taken from
// `InternalTable.Checkpoints.table`, whose Int32 is what Postgres stores.
type checkpointColumn = {
  name: string,
  fieldType: Table.fieldType,
  isNullable: bool,
  valuesOf: Batch.t => array<unknown>,
}

// The checkpoints table as ClickHouse holds it. The field types and order come
// from the internal table itself, so a column added there cannot be silently
// missing here; only the value accessor and the one type that differs are
// stated. `events_processed` is widened because ClickHouse counts them in a
// UInt64 where Postgres stores an Int32.
let checkpointColumns: array<checkpointColumn> = {
  let valuesOf: dict<Batch.t => array<unknown>> = Dict.fromArray([
    (
      (#id: InternalTable.Checkpoints.field :> string),
      (batch: Batch.t) => batch.checkpointIds->(Utils.magic: array<bigint> => array<unknown>),
    ),
    (
      (#chain_id: InternalTable.Checkpoints.field :> string),
      (batch: Batch.t) => batch.checkpointChainIds->(Utils.magic: array<ChainId.t> => array<unknown>),
    ),
    (
      (#block_number: InternalTable.Checkpoints.field :> string),
      (batch: Batch.t) => batch.checkpointBlockNumbers->(Utils.magic: array<int> => array<unknown>),
    ),
    (
      (#block_hash: InternalTable.Checkpoints.field :> string),
      (batch: Batch.t) => batch.checkpointBlockHashes->(Utils.magic: array<Null.t<string>> => array<unknown>),
    ),
    (
      (#events_processed: InternalTable.Checkpoints.field :> string),
      (batch: Batch.t) => batch.checkpointEventsProcessed->(Utils.magic: array<int> => array<unknown>),
    ),
  ])
  InternalTable.Checkpoints.table.fields->Array.filterMap(field =>
    switch field {
    | Table.Field(f) =>
      let name = f.fieldName
      Some({
        name,
        fieldType: switch name {
        | "events_processed" => Table.UInt64
        | _ => f.fieldType
        },
        isNullable: f.isNullable,
        valuesOf: switch valuesOf->Dict.get(name) {
        | Some(valuesOf) => valuesOf
        | None =>
          JsError.throwWithMessage(
            `The ClickHouse checkpoints table has no values for the "${name}" column`,
          )
        },
      })
    | DerivedFrom(_) => None
    }
  )
}

let checkpointColumnSpecs = () =>
  checkpointColumns->Array.map(({name, fieldType, isNullable}) =>
    makeColumnSpec(~name, ~fieldType, ~isNullable)
  )

// One entity as the sink needs it: the history table it writes, the columns it
// declares, and the layout its `@storage(clickhouse: {...})` directive asked
// for. Rust turns this into both the `CREATE TABLE` and the encoder's schema.
let entitySpec = (~entityConfig: Internal.entityConfig): ClickHouseSink.entitySpec => {
  let options = entityConfig.storage.clickhouseOptions
  {
    name: entityConfig.name,
    historyTable: EntityHistory.historyTableName(
      ~entityName=entityConfig.name,
      ~entityIndex=entityConfig.index,
    ),
    columns: entityConfig.table.fields->Array.filterMap(field =>
      switch field {
      | Table.Field(f) =>
        Some(
          makeColumnSpec(
            ~name=f->Table.getClickHouseDbFieldName,
            ~fieldName=f.fieldName,
            ~fieldType=f.fieldType,
            ~isNullable=f.isNullable,
            ~isArray=f.isArray,
          ),
        )
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
            (index): ClickHouseSink.skippingIndexSpec => {
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

// The compiled serializers for one entity and chain scope. Only these vary with
// the scope; the column set does not, so the registered table is shared.
type converters = {
  convertSetOrThrow: Change.t<Internal.entity> => dict<unknown>,
  convertDeleteOrThrow: Change.t<Internal.entity> => dict<unknown>,
}

// What a sink needs to write: the tables it has registered, and the serializers
// it has compiled.
type registry = {
  entities: dict<ClickHouseSink.table>,
  mutable checkpoints: option<ClickHouseSink.table>,
  converters: dict<converters>,
}

let makeRegistry = () => {
  entities: Dict.make(),
  checkpoints: None,
  converters: Dict.make(),
}

let compileToColumnValues = schema =>
  S.compile(schema, ~input=Value, ~output=Json, ~typeValidation=false, ~mode=Sync)->(
    Utils.magic: (Change.t<Internal.entity> => JSON.t) => Change.t<Internal.entity> => dict<unknown>
  )

let makeConverters = (
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
): converters => {
  let chainIdField = entityConfig.table->Table.getChainIdField
  let scopeChainId = scope->Internal.chainScopeChainId
  let idSchema = entityConfig.table->Table.getIdSchema

  {
    convertSetOrThrow: compileToColumnValues(
      EntityHistory.makeSetUpdateSchema(~idSchema, makeClickHouseEntitySchema(entityConfig.table)),
    ),
    // A delete row carries no entity to stamp, so the chain id is baked into
    // the schema instead — which is why these are cached per scope. Every
    // other column is absent and takes its ClickHouse default.
    convertDeleteOrThrow: compileToColumnValues(
      S.object(s => {
        s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
        switch (chainIdField, scopeChainId) {
        | (Some(field), Some(chainId)) => s.tag(field->Table.getClickHouseDbFieldName, chainId)
        | _ => ()
        }
        Change.Delete({
          entityId: s.field(Table.idFieldName, idSchema),
          checkpointId: s.field(
            EntityHistory.checkpointIdFieldName,
            EntityHistory.unsafeCheckpointIdSchema,
          ),
        })
      }),
    ),
  }
}

// Registering derives the column types, which is where a field this encoder
// cannot hold is refused. `initialize` warms every table so that lands at
// startup, but an indexer resuming an existing storage never runs it — so the
// write path registers on demand rather than depending on that.
let entityTable = (sink, ~registry, ~entityConfig: Internal.entityConfig) =>
  switch registry.entities->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) {
  | Some(table) => table
  | None =>
    let spec = entitySpec(~entityConfig)
    let table =
      sink
      ->ClickHouseSink.registerEntityTable(spec)
      ->ClickHouseSink.makeTable(~name=spec.historyTable)
    registry.entities->Dict.set(entityConfig.name, table)
    table
  }

let checkpointsTable = (sink, ~registry) =>
  switch registry.checkpoints {
  | Some(table) => table
  | None =>
    let table =
      sink
      ->ClickHouseSink.registerCheckpointsTable(checkpointColumnSpecs())
      ->ClickHouseSink.makeTable(~name=InternalTable.Checkpoints.table.tableName)
    registry.checkpoints = Some(table)
    table
  }

// Copies the batch into the sink and returns the handle to write. Splitting
// staging from the write is what lets the values be read on the JS thread while
// the encode and the round trip happen off it.
let stageBuilders = (sink, ~table: ClickHouseSink.table, ~builders, ~rows) =>
  sink->ClickHouseSink.stage(
    ~table=table.handle,
    ~rows,
    ~columns=builders->Array.map(ClickHouseSink.builderPayload),
  )

let stageCheckpointsOrThrow = (sink, ~registry, ~batch: Batch.t) => {
  let rows = batch.checkpointIds->Array.length
  if rows === 0 {
    Null.null
  } else {
    let table = sink->checkpointsTable(~registry)
    // Keyed by name rather than by position: the registered list is the sink's,
    // and a column it adds of its own would otherwise pair every column after it
    // with its neighbour's values — which nothing downstream could catch, since
    // every array reaches the builders as `unknown`.
    let values = Dict.make()
    checkpointColumns->Array.forEach(({name, valuesOf}) => values->Dict.set(name, valuesOf(batch)))
    try {
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
      // A checkpoint id past what UInt64 holds is refused here rather than being
      // reduced to a different id by the typed array it would land in.
      builders->Array.forEach(builder => {
        let columnValues = switch values->Dict.get(builder.name) {
        | Some(columnValues) => columnValues
        | None =>
          JsError.throwWithMessage(
            `The ClickHouse checkpoints table has no values for the "${builder.name}" column`,
          )
        }
        for row in 0 to rows - 1 {
          builder->ClickHouseSink.writeValue(~row, columnValues->Array.getUnsafe(row))
        }
      })
      Null.make(sink->stageBuilders(~table, ~builders, ~rows))
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to convert checkpoints for ClickHouse table "${table.name}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

let stageUpdatesOrThrow = (
  sink,
  ~registry,
  ~changes: array<Change.t<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
) => {
  let rows = changes->Array.length
  if rows === 0 {
    None
  } else {
    let table = sink->entityTable(~registry, ~entityConfig)
    let tableName = table.name
    let cacheKey = `${entityConfig.name}|${scope->Internal.chainScopeToString}`
    let {
      convertSetOrThrow,
      convertDeleteOrThrow,
    } = switch registry.converters->Utils.Dict.dangerouslyGetNonOption(cacheKey) {
    | Some(cached) => cached
    | None =>
      let cached = makeConverters(~entityConfig, ~scope)
      registry.converters->Dict.set(cacheKey, cached)
      cached
    }

    let stampFieldName = switch (
      entityConfig.table->Table.getChainIdField,
      scope->Internal.chainScopeChainId,
    ) {
    | (Some(field), Some(chainId)) => Some((field.fieldName, chainId))
    | _ => None
    }

    try {
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
      let columns = builders->Array.length
      for row in 0 to rows - 1 {
        let change = changes->Array.getUnsafe(row)
        // The entity history table is the source of truth for ClickHouse, so
        // every intermediate change must be persisted, not only the current value.
        let values = switch change {
        | Change.Set(set) =>
          let change = switch stampFieldName {
          | Some((fieldName, chainId)) =>
            Change.Set({
              ...set,
              entity: set.entity->Internal.stampChainId(~fieldName, ~chainId),
            })
          | None => change
          }
          convertSetOrThrow(change)
        | Delete(_) => convertDeleteOrThrow(change)
        }
        for column in 0 to columns - 1 {
          let builder = builders->Array.getUnsafe(column)
          builder->ClickHouseSink.writeValue(~row, values->Dict.getUnsafe(builder.name))
        }
      }
      Some(sink->stageBuilders(~table, ~builders, ~rows))
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to convert items for ClickHouse table "${tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Sends every staged batch, then the checkpoints that cover them. The ordering
// is Rust's to keep: the current-state views read up to `max(id)` of the
// checkpoints table, so a checkpoint visible before its rows would expose a
// partial batch.
let writeStagedOrThrow = async (sink, ~entities, ~checkpoints) =>
  try await sink->ClickHouseSink.writeBatch(~entities, ~checkpoints) catch {
  | exn =>
    throw(
      Persistence.StorageError({
        message: "Failed to write a batch to ClickHouse",
        reason: exn->Utils.prettifyExn,
      }),
    )
  }

// Creates the database, the history tables and the views. Rust renders every
// statement from the specs below and runs them in the order the views depend on.
let initialize = async (sink, ~registry, ~entities: array<Internal.entityConfig>) => {
  try {
    await sink->ClickHouseSink.initialize({
      entities: entities->Array.map(entityConfig => entitySpec(~entityConfig)),
      checkpointColumns: checkpointColumnSpecs(),
      replicated: Env.ClickHouse.replicated(),
      databaseEngine: ?Env.ClickHouse.databaseEngine(),
    })

    // Registered here rather than on first use, so a column this encoder cannot
    // hold stops the indexer at startup, with nothing written.
    let _ = sink->checkpointsTable(~registry)
    entities->Array.forEach(entityConfig => ignore(sink->entityTable(~registry, ~entityConfig)))

    Logging.trace("ClickHouse storage initialization completed successfully")
  } catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to initialize ClickHouse storage")
      JsError.throwWithMessage("ClickHouse initialization failed")
    }
  }
}

// Rewinds ClickHouse to the checkpoint Postgres committed, dropping the history
// rows and checkpoints written past it.
let resume = async (sink, ~checkpointId: Internal.checkpointId) => {
  try await sink->ClickHouseSink.resume(checkpointId->BigInt.toString) catch {
  | Persistence.StorageError(_) as exn => throw(exn)
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume ClickHouse storage")
      JsError.throwWithMessage("ClickHouse resume failed")
    }
  }
}
