// What the ClickHouse sink is handed and what comes back out of it. The schema
// crosses to Rust as schema; what stays here is what only JS can do — reading
// entity values out of the isolate into the columnar builders a batch is
// staged from.

// Serialized keys are the db column names, while the entity values are keyed
// by API field names (they only differ when column renaming is configured).
// `skipColumn` names a column the row carries as a constant instead — the chain
// id of a per-chain entity, which the scope knows and the entity never holds.
let makeClickHouseEntitySchema = (table: Table.table, ~skipColumn: option<string>=?): S.t<
  Internal.entity,
> => {
  S.object(s => {
    let dict = Dict.make()
    table.fields->Array.forEach(field => {
      switch field {
      | Field(f) if Some(f->Table.getClickHouseDbFieldName) != skipColumn => {
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
      | Field(_) => () // Tagged by the caller
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

// The schema field a column stores, in the shape the sink reads it.
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
//
// Keyed by name and not by a switch on `Checkpoints.field`: `mkField` takes a
// plain string, so nothing forces a new column through the variant, and
// ReScript compiles a closed-variant match to an if/else chain whose last arm
// is the bare `else` — a name the variant does not know would take the last
// branch and be written from the wrong batch array rather than being refused.
%%private(let checkpointColumnsCache: ref<option<array<checkpointColumn>>> = ref(None))

// Built on first use rather than at module load: it throws when a column has no
// value accessor, which at load time would take down an indexer that never
// writes to ClickHouse at all.
let checkpointColumns = () =>
  switch checkpointColumnsCache.contents {
  | Some(columns) => columns
  | None =>
    let columns = {
      let valuesOf: dict<Batch.t => array<unknown>> = Dict.fromArray([
        (
          (#id: InternalTable.Checkpoints.field :> string),
          (batch: Batch.t) => batch.checkpointIds->(Utils.magic: array<bigint> => array<unknown>),
        ),
        (
          (#chain_id: InternalTable.Checkpoints.field :> string),
          (batch: Batch.t) =>
            batch.checkpointChainIds->(Utils.magic: array<ChainId.t> => array<unknown>),
        ),
        (
          (#block_number: InternalTable.Checkpoints.field :> string),
          (batch: Batch.t) =>
            batch.checkpointBlockNumbers->(Utils.magic: array<int> => array<unknown>),
        ),
        (
          (#block_hash: InternalTable.Checkpoints.field :> string),
          (batch: Batch.t) =>
            batch.checkpointBlockHashes->(Utils.magic: array<Null.t<string>> => array<unknown>),
        ),
        (
          (#events_processed: InternalTable.Checkpoints.field :> string),
          (batch: Batch.t) =>
            batch.checkpointEventsProcessed->(Utils.magic: array<int> => array<unknown>),
        ),
      ])
      InternalTable.Checkpoints.table.fields->Array.filterMap(field =>
        switch field {
        | Table.Field(f) =>
          let name = f.fieldName
          Some({
            name,
            fieldType: name === (#events_processed: InternalTable.Checkpoints.field :> string)
              ? Table.UInt64
              : f.fieldType,
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
    checkpointColumnsCache := Some(columns)
    columns
  }

let checkpointColumnSpecs = () =>
  checkpointColumns()->Array.map(({name, fieldType, isNullable}) =>
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
  let idSchema = entityConfig.table->Table.getIdSchema
  // Every row a converter writes belongs to one chain, so the column is a
  // constant of the schema rather than a value read off each row — which is why
  // these are cached per scope. A cross-chain entity has no such column.
  let chainIdTag = switch (
    entityConfig.table->Table.getChainIdField,
    scope->Internal.chainScopeChainId,
  ) {
  | (Some(field), Some(chainId)) => Some((field->Table.getClickHouseDbFieldName, chainId))
  | _ => None
  }

  {
    convertSetOrThrow: compileToColumnValues(
      EntityHistory.makeSetUpdateSchema(
        ~idSchema,
        ~chainIdTag?,
        makeClickHouseEntitySchema(
          entityConfig.table,
          ~skipColumn=?chainIdTag->Option.map(((column, _)) => column),
        ),
      ),
    ),
    // A delete row carries only what identifies it; every other column is
    // absent and takes its ClickHouse default.
    convertDeleteOrThrow: compileToColumnValues(
      S.object(s => {
        s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
        switch chainIdTag {
        | Some((column, chainId)) => s.tag(column, chainId)
        | None => ()
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
    // Keyed by name rather than by position. The registered columns come from
    // this same list, so the orders do match today; what the name buys is that
    // a future divergence fails to find a column instead of pairing one with its
    // neighbour's values, which nothing downstream could catch — every array
    // reaches the builders as `unknown`.
    let values = Dict.make()
    checkpointColumns()->Array.forEach(({name, valuesOf}) =>
      values->Dict.set(name, valuesOf(batch))
    )
    try {
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
      // A checkpoint id past what UInt64 holds is refused here rather than being
      // reduced to a different id by the typed array it would land in.
      builders->Array.forEach(builder => {
        let columnValues = values->Dict.getUnsafe(builder.name)
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

    try {
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
      let columns = builders->Array.length
      for row in 0 to rows - 1 {
        let change = changes->Array.getUnsafe(row)
        // The entity history table is the source of truth for ClickHouse, so
        // every intermediate change must be persisted, not only the current value.
        // A DELETE row carries only what identifies it, so the columns it
        // leaves out are absent on purpose; on a SET row the same gap is a
        // field the handler never set, which the writer refuses.
        let (values, write) = switch change {
        | Change.Set(_) => (convertSetOrThrow(change), ClickHouseSink.writeValue)
        | Delete(_) => (convertDeleteOrThrow(change), ClickHouseSink.writeDeletedValue)
        }
        for column in 0 to columns - 1 {
          let builder = builders->Array.getUnsafe(column)
          builder->write(~row, values->Dict.getUnsafe(builder.name))
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
      throw(
        Persistence.StorageError({
          message: "Failed to initialize ClickHouse storage",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

// Rewinds ClickHouse to the checkpoint Postgres committed, dropping the history
// rows and checkpoints written past it.
let resume = async (sink, ~checkpointId: Internal.checkpointId) => {
  try await sink->ClickHouseSink.resume(checkpointId->BigInt.toString) catch {
  | exn => {
      Logging.errorWithExn(exn, "Failed to resume ClickHouse storage")
      throw(
        Persistence.StorageError({
          message: "Failed to resume ClickHouse storage",
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}
