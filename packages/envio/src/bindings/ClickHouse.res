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
                Utils.Schema.nullTolerant(dateSchema)->S.toUnknown
              } else if f.isArray {
                S.array(dateSchema)->S.toUnknown
              } else {
                dateSchema
              }
            }
          | ChainId => ChainId.schema->S.toUnknown
          // Not wrapped in `S.null` even when the field is nullable: the column
          // is a String either way, and both ways of saying nothing travel as
          // the text of JSON null.
          | Json if !f.isArray => Utils.Schema.clickHouseJson->S.toUnknown
          | _ => f.fieldSchema
          }
          dict->Dict.set(f->Table.getApiFieldName, s.field(fieldName, fieldSchema))
        }
      | Field(_) => ()
      | DerivedFrom(_) => ()
      }
    })
    dict->(Utils.magic: dict<unknown> => Internal.entity)
  })
}

let logger = Logging.createChild(~params={"context": "ClickHouse"})

let makeSink = (~host, ~username, ~password, ~database, ~chainIdMode) =>
  ClickHouseSink.make(~url=host, ~username, ~password, ~database, ~chainIdMode, ~onWarning=msg =>
    logger->Logging.childWarn({"msg": msg})
  )

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
  | SmallInt
  | Bytea =>
    JsError.throwWithMessage(
      "ClickHouse doesn't support the internal SmallInt and Bytea column types",
    )
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
  spec: ClickHouseSink.columnSpec,
  valuesOf: Batch.t => array<unknown>,
}

// Registration and staging both read this one list, so the column a batch's
// values are written to is the column that was registered in its place.
let checkpointColumns = InternalTable.Checkpoints.columns->Array.filterMap(({
  field,
  clickHouseFieldType,
  valuesOf,
}) =>
  switch field {
  | Table.Field({fieldName, isNullable}) =>
    Some({
      spec: makeColumnSpec(~name=fieldName, ~fieldType=clickHouseFieldType, ~isNullable),
      valuesOf,
    })
  | DerivedFrom(_) => None
  }
)

let checkpointColumnSpecs = checkpointColumns->Array.map(({spec}) => spec)

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

type converters = {
  convertSetOrThrow: Change.t<Internal.entity> => dict<unknown>,
  convertDeleteOrThrow: Change.t<Internal.entity> => dict<unknown>,
}

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
      ->ClickHouseSink.registerCheckpointsTable(checkpointColumnSpecs)
      ->ClickHouseSink.makeTable(~name=InternalTable.Checkpoints.table.tableName)
    registry.checkpoints = Some(table)
    table
  }

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
    try {
      // The table was registered from `checkpointColumns`, in this order.
      let builders = table.columns->Array.map(ClickHouseSink.makeBuilder(_, ~rows))
      builders->Array.forEachWithIndex((builder, index) => {
        let columnValues = (checkpointColumns->Array.getUnsafe(index)).valuesOf(batch)
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

// Tables are not registered here: an indexer that finds an existing storage
// never runs this, so the write path registers them on first use either way.
let initialize = async (sink, ~entities: array<Internal.entityConfig>) => {
  try {
    await sink->ClickHouseSink.initialize({
      entities: entities->Array.map(entityConfig => entitySpec(~entityConfig)),
      checkpointColumns: checkpointColumnSpecs,
      replicated: Env.ClickHouse.replicated(),
      databaseEngine: ?Env.ClickHouse.databaseEngine(),
    })

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

let resume = async (
  sink,
  ~checkpointId: Internal.checkpointId,
  ~chains: array<Persistence.initialChainState>,
) => {
  let chainProgress = chains->Array.map(chain => {
    ClickHouseSink.chainId: chain.id->ChainId.toString,
    progressBlockNumber: chain.progressBlockNumber,
  })
  try await sink->ClickHouseSink.resume(checkpointId->BigInt.toString, chainProgress) catch {
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
