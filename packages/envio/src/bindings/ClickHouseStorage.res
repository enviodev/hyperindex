// Builds Rust-side ClickHouse FieldSpec from the in-memory Table definition,
// then dispatches writes to the napi addon (RowBinary over HTTP). Mirrors the
// CH type mapping in ClickHouse.res:getClickHouseFieldType.

type endpoint = Core.clickHouseEndpoint
type fieldSpec = Core.clickHouseFieldSpec

exception UnsupportedFieldType(string)

let fieldSpecOfTableField = (field: Table.field): fieldSpec => {
  let name = field->Table.getDbFieldName

  let (ty, enumVariants) = switch field.fieldType {
  | Int32 | Serial => ("Int32", Null.null)
  | Uint32 => ("UInt32", Null.null)
  | UInt52 | UInt64 => ("UInt64", Null.null)
  | BigSerial =>
    throw(
      UnsupportedFieldType(
        `field "${name}": BigSerial is not supported by the Rust ClickHouse storage`,
      ),
    )
  // Unbounded BigInt/BigDecimal are stored as String in ClickHouse (see
  // ClickHouse.res:getClickHouseFieldType). Bounded variants would need a
  // Decimal128 wire encoder, which the Rust side does not implement yet.
  | BigInt({?precision}) =>
    switch precision {
    | None => ("Str", Null.null)
    | Some(p) if p > 38 => ("Str", Null.null)
    | Some(_) =>
      throw(
        UnsupportedFieldType(
          `field "${name}": bounded BigInt (Decimal) is not supported by the Rust ClickHouse storage`,
        ),
      )
    }
  | BigDecimal({?config}) =>
    switch config {
    | None => ("Str", Null.null)
    | Some((p, s)) if p > 38 || s > p => ("Str", Null.null)
    | Some(_) =>
      throw(
        UnsupportedFieldType(
          `field "${name}": bounded BigDecimal (Decimal) is not supported by the Rust ClickHouse storage`,
        ),
      )
    }
  | Boolean => ("Bool", Null.null)
  | Number => ("Float64", Null.null)
  | String => ("Str", Null.null)
  | Json => ("Str", Null.null)
  | Date => ("DateTimeMs", Null.null)
  | Enum({config}) => {
      let variants = config.variants->Belt.Array.map(v => v->(Utils.magic: Table.enum => string))
      ("Enum", Null.make(variants))
    }
  | Entity(_) => ("Str", Null.null)
  }

  {
    name,
    ty,
    nullable: field.isNullable,
    isArray: field.isArray,
    enumVariants,
  }
}

// Cached per entity: building the spec walks every field, and entity
// schemas don't change at runtime.
let schemaCache: Utils.WeakMap.t<Internal.entityConfig, array<fieldSpec>> = Utils.WeakMap.make()

let getEntityHistorySchema = (entityConfig: Internal.entityConfig): array<fieldSpec> => {
  switch schemaCache->Utils.WeakMap.get(entityConfig) {
  | Some(specs) => specs
  | None => {
      let specs = entityConfig.table.fields->Belt.Array.keepMap(field => {
        switch field {
        | Field(f) => Some(fieldSpecOfTableField(f))
        | DerivedFrom(_) => None
        }
      })

      // Trailing fields appended to every entity history table; see
      // ClickHouse.res:makeCreateHistoryTableQuery.
      specs
      ->Array.push({
        name: EntityHistory.checkpointIdFieldName,
        ty: "UInt64",
        nullable: false,
        isArray: false,
        enumVariants: Null.null,
      })
      ->ignore
      specs
      ->Array.push({
        name: EntityHistory.changeFieldName,
        ty: "Enum",
        nullable: false,
        isArray: false,
        enumVariants: Null.make(
          EntityHistory.RowAction.variants->Belt.Array.map(v =>
            v->(Utils.magic: EntityHistory.RowAction.t => string)
          ),
        ),
      })
      ->ignore

      schemaCache->Utils.WeakMap.set(entityConfig, specs)->ignore
      specs
    }
  }
}

let setCheckpointsOrThrow = async (~endpoint: endpoint, ~batch: Batch.t) => {
  let n = batch.checkpointIds->Array.length
  if n === 0 {
    ()
  } else {
    let ids = batch.checkpointIds->Array.map(b => b->BigInt.toString)
    try {
      await Core.clickhouseInsertCheckpoints(
        ~endpoint,
        ~table=InternalTable.Checkpoints.table.tableName,
        ~ids,
        ~chainIds=batch.checkpointChainIds,
        ~blockNumbers=batch.checkpointBlockNumbers,
        ~blockHashes=batch.checkpointBlockHashes,
        ~eventsProcessed=batch.checkpointEventsProcessed,
      )
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to insert checkpoints into ClickHouse table "${InternalTable.Checkpoints.table.tableName}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}

type setUpdatesCache = {
  table: string,
  schema: array<fieldSpec>,
  convertOrThrow: Change.t<Internal.entity> => JSON.t,
}

let updatesCache: Utils.WeakMap.t<Internal.entityConfig, setUpdatesCache> = Utils.WeakMap.make()

let setUpdatesOrThrow = async (
  ~endpoint: endpoint,
  ~updates: array<Internal.inMemoryStoreEntityUpdate<Internal.entity>>,
  ~entityConfig: Internal.entityConfig,
) => {
  if updates->Array.length === 0 {
    ()
  } else {
    let cached = switch updatesCache->Utils.WeakMap.get(entityConfig) {
    | Some(cached) => cached
    | None =>
      let cached: setUpdatesCache = {
        table: EntityHistory.historyTableName(
          ~entityName=entityConfig.name,
          ~entityIndex=entityConfig.index,
        ),
        schema: getEntityHistorySchema(entityConfig),
        convertOrThrow: S.compile(
          S.union([
            EntityHistory.makeSetUpdateSchema(
              ClickHouse.makeClickHouseEntitySchema(entityConfig.table),
            ),
            S.object(s => {
              s.tag(EntityHistory.changeFieldName, EntityHistory.RowAction.DELETE)
              Change.Delete({
                entityId: s.field(Table.idFieldName, S.string),
                checkpointId: s.field(
                  EntityHistory.checkpointIdFieldName,
                  EntityHistory.unsafeCheckpointIdSchema,
                ),
              })
            }),
          ]),
          ~input=Value,
          ~output=Json,
          ~typeValidation=false,
          ~mode=Sync,
        ),
      }
      updatesCache->Utils.WeakMap.set(entityConfig, cached)->ignore
      cached
    }

    let rows = updates->Array.map(update => update.latestChange->cached.convertOrThrow)

    try {
      await Core.clickhouseInsertRows(~endpoint, ~table=cached.table, ~schema=cached.schema, ~rows)
    } catch {
    | exn =>
      throw(
        Persistence.StorageError({
          message: `Failed to insert items into ClickHouse table "${cached.table}"`,
          reason: exn->Utils.prettifyExn,
        }),
      )
    }
  }
}
