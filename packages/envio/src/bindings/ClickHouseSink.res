type t

type historySchema = {
  idColumn: string,
  checkpointIdColumn: string,
  changeColumn: string,
  changeVariants: array<string>,
  setVariant: string,
  checkpointsTable: string,
  checkpointChainIdColumn: string,
  checkpointBlockNumberColumn: string,
  chainsTable: string,
  chainsCheckpointIdColumn: string,
}

type chainProgressInput = {
  chainId: string,
  progressBlockNumber: int,
  // Where the chain's own sequence stands, as Postgres has it committed.
  committedCheckpointId: string,
}

type options = {
  url: string,
  username: string,
  password: string,
  database: string,
  chainIdMode: string,
  history: historySchema,
}

@send external classNew: (Core.clickHouseSinkCtor, options, string => unit) => t = "new"

type columnSpec = {
  name: string,
  // Omitted when it matches `name`. Set when a column rename is configured, so
  // `@storage(clickhouse: {...})` expressions can still name the schema field.
  fieldName?: string,
  fieldType: string,
  isNullable?: bool,
  isArray?: bool,
  precision?: int,
  scale?: int,
  enumVariants?: array<string>,
}

type skippingIndexSpec = {
  name: string,
  expr: string,
  indexType: string,
  granularity?: int,
}

type entitySpec = {
  name: string,
  historyTable: string,
  columns: array<columnSpec>,
  chainIdColumn?: string,
  partitionBy?: string,
  orderBy?: array<string>,
  ttl?: string,
  skippingIndexes?: array<skippingIndexSpec>,
}

type initializeInput = {
  entities: array<entitySpec>,
  checkpointColumns: array<columnSpec>,
  replicated: bool,
  databaseEngine?: string,
}

// A history table and the column naming the chain its rows belong to. Absent
// only for a cross-chain entity, which no per-chain sequence can produce.
type historyTableInput = {name: string, chainIdColumn?: string}

type resumeInput = {
  perChain: bool,
  chainProgress: array<chainProgressInput>,
  historyTables: array<historyTableInput>,
}

type registeredTable = {
  handle: int,
  names: array<string>,
  kinds: array<int>,
  nullable: array<bool>,
}

@send
external registerEntityTable: (t, entitySpec) => registeredTable = "registerEntityTable"

@send
external registerCheckpointsTable: (t, array<columnSpec>) => registeredTable =
  "registerCheckpointsTable"

@send external initialize: (t, initializeInput) => promise<unit> = "initialize"

@send
external resume: (t, resumeInput) => promise<unit> = "resume"

@send
external beginStage: (t, ~table: int, ~rows: int) => Staging.begun = "beginStage"

@send
external growStage: (
  t,
  ~handle: int,
  ~column: int,
  ~needed: int,
  ~stale: ArrayBuffer.t,
) => ArrayBuffer.t = "growStage"

@send
external commitStage: (t, ~handle: int, ~buffers: array<ArrayBuffer.t>) => unit = "commitStage"

@send
external abortStage: (t, ~handle: int, ~buffers: array<ArrayBuffer.t>) => unit = "abortStage"

let arena = (sink): Staging.arena => {
  beginStage: (~table, ~rows) => sink->beginStage(~table, ~rows),
  growStage: (~handle, ~column, ~needed, ~stale) =>
    sink->growStage(~handle, ~column, ~needed, ~stale),
  commitStage: (~handle, ~buffers) => sink->commitStage(~handle, ~buffers),
  abortStage: (~handle, ~buffers) => sink->abortStage(~handle, ~buffers),
}

@send
external writeBatch: (t, ~entities: array<int>, ~checkpoints: Null.t<int>) => promise<unit> =
  "writeBatch"

@send external discard: (t, array<int>) => unit = "discard"

let historySchema = (): historySchema => {
  idColumn: Table.idFieldName,
  checkpointIdColumn: EntityHistory.checkpointIdFieldName,
  changeColumn: EntityHistory.changeFieldName,
  changeVariants: EntityHistory.RowAction.variants->Array.map(variant => (variant :> string)),
  setVariant: (EntityHistory.RowAction.SET :> string),
  checkpointsTable: InternalTable.Checkpoints.table.tableName,
  checkpointChainIdColumn: (#chain_id: InternalTable.Checkpoints.field :> string),
  checkpointBlockNumberColumn: (#block_number: InternalTable.Checkpoints.field :> string),
  chainsTable: InternalTable.Chains.table.tableName,
  chainsCheckpointIdColumn: (#checkpoint_id: InternalTable.Chains.field :> string),
}

let make = (~url, ~username, ~password, ~database, ~chainIdMode: ChainId.mode, ~onWarning) =>
  Core.getAddon().clickHouseSink->classNew(
    {
      url,
      username,
      password,
      database,
      chainIdMode: (chainIdMode :> string),
      history: historySchema(),
    },
    onWarning,
  )

// Visits every node on the way into JSON text. A bigint would make
// `JSON.stringify` throw and fail the whole batch, so it travels as its digits.
%%private(
  let jsonSafe = (~column) =>
    (_, value: JSON.t) =>
      switch value->typeof {
      | #bigint =>
        value->(Utils.magic: JSON.t => unknown)->Staging.stringOf->(Utils.magic: string => JSON.t)
      // A Uint8Array inside a list column travels as its byte values, which the
      // sink reads back into raw bytes.
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

type table = {handle: int, name: string, columns: array<Staging.column>}

let makeTable = (~name, {handle, names, kinds, nullable}: registeredTable) => {
  handle,
  name,
  columns: names->Array.mapWithIndex((name, index): Staging.column => {
    name,
    kind: kinds->Array.getUnsafe(index)->Staging.kindOfOrdinal,
    isNullable: nullable->Array.getUnsafe(index),
    replacer: Replacer(jsonSafe(~column=name)),
  }),
}
