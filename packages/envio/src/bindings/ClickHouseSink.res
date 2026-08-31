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
  historyTablePrefix: string,
}

type chainProgressInput = {chainId: string, progressBlockNumber: int}

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

type registeredTable = {
  handle: int,
  names: array<string>,
  kinds: array<int>,
  nullable: array<bool>,
}

type columnValuesInput = {
  numbers?: Float64Array.t,
  unsigned64?: BigUint64Array.t,
  signed64?: BigInt64Array.t,
  texts?: array<string>,
  nulls?: Uint8Array.t,
}

@send
external registerEntityTable: (t, entitySpec) => registeredTable = "registerEntityTable"

@send
external registerCheckpointsTable: (t, array<columnSpec>) => registeredTable =
  "registerCheckpointsTable"

@send external initialize: (t, initializeInput) => promise<unit> = "initialize"

@send
external resume: (t, string, array<chainProgressInput>) => promise<unit> = "resume"

@send
external stage: (t, ~table: int, ~rows: int, ~columns: array<columnValuesInput>) => int = "stage"

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
  historyTablePrefix: EntityHistory.historyTablePrefix,
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

type kind =
  | @as(0) F64
  | @as(1) U64
  | @as(2) I64
  | @as(3) Text

let kindOfOrdinal = ordinal =>
  switch ordinal {
  | 0 => F64
  | 1 => U64
  | 2 => I64
  | 3 => Text
  | unknown => JsError.throwWithMessage(`Unknown ClickHouse column kind ${unknown->Int.toString}`)
  }

external asString: unknown => string = "%identity"
@val external toNumber: unknown => float = "Number"
@val external toBigInt: unknown => bigint = "BigInt"
@val external stringOf: unknown => string = "String"

// Visits every node on the way into JSON text, which is the one place the two
// values JSON cannot carry are still themselves. A bigint would make
// `JSON.stringify` throw and fail the whole batch; a non-finite number is
// quieter and worse — it renders as `null`, which the column then refuses for a
// reason naming `null` rather than the NaN the handler actually wrote.
%%private(
  let jsonSafe = (~column) =>
    (_, value: JSON.t) =>
      switch value->typeof {
      | #bigint =>
        value->(Utils.magic: JSON.t => unknown)->stringOf->(Utils.magic: string => JSON.t)
      | #number =>
        let number = value->(Utils.magic: JSON.t => float)
        if number->Float.isFinite {
          value
        } else {
          JsError.throwWithMessage(
            `${number->Float.toString} has no JSON form, so it cannot be stored in the \`${column}\` column. Store a finite number, or keep it out of the entity.`,
          )
        }
      | _ => value
      }
)

// The replacer closes over nothing but the column's name, so it is built once
// with the column rather than once per column per batch.
type column = {name: string, kind: kind, isNullable: bool, replacer: JSON.replacer}
type table = {handle: int, name: string, columns: array<column>}

let makeTable = (~name, {handle, names, kinds, nullable}: registeredTable) => {
  handle,
  name,
  columns: names->Array.mapWithIndex((name, index) => {
    name,
    kind: kinds->Array.getUnsafe(index)->kindOfOrdinal,
    isNullable: nullable->Array.getUnsafe(index),
    replacer: Replacer(jsonSafe(~column=name)),
  }),
}

let toText = (value: unknown, ~replacer) =>
  switch value->typeof {
  | #string => value->asString
  | #bigint => value->stringOf
  | _ => value->(Utils.magic: unknown => JSON.t)->JSON.stringify(~replacer)
  }

type builder = {
  name: string,
  kind: kind,
  isNullable: bool,
  floats: Float64Array.t,
  unsigned: BigUint64Array.t,
  signed: BigInt64Array.t,
  texts: array<string>,
  replacer: JSON.replacer,
  mutable nulls: option<Uint8Array.t>,
  rows: int,
}

%%private(let noFloats = Float64Array.fromLength(0))
%%private(let noUnsigned = BigUint64Array.fromLength(0))
%%private(let noSigned = BigInt64Array.fromLength(0))

let makeBuilder = ({name, kind, isNullable, replacer}: column, ~rows) => {
  name,
  kind,
  isNullable,
  floats: kind === F64 ? Float64Array.fromLength(rows) : noFloats,
  unsigned: kind === U64 ? BigUint64Array.fromLength(rows) : noUnsigned,
  signed: kind === I64 ? BigInt64Array.fromLength(rows) : noSigned,
  texts: kind === Text ? Array.make(~length=rows, "") : [],
  replacer,
  nulls: None,
  rows,
}

let markNull = (builder, ~row) => {
  let nulls = switch builder.nulls {
  | Some(nulls) => nulls
  | None =>
    let nulls = Uint8Array.fromLength(builder.rows)
    builder.nulls = Some(nulls)
    nulls
  }
  nulls->TypedArray.set(row, 1)
}

// RowBinary carries the raw integer, so a value the column cannot hold is not
// rejected anywhere downstream — and a typed array reduces it modulo 2^64 on
// the way in rather than refusing it, which would leave no trace at all.
%%private(
  let checkedBigInt = (value: unknown, ~builder, ~min, ~max) => {
    let value = value->toBigInt
    if value < min || value > max {
      JsError.throwWithMessage(
        `${value->BigInt.toString} is out of range for the \`${builder.name}\` column`,
      )
    }
    value
  }
)

%%private(
  let writePresent = (builder, ~row, value: unknown) =>
    switch builder.kind {
    | F64 => builder.floats->TypedArray.set(row, value->toNumber)
    | U64 =>
      builder.unsigned->TypedArray.set(
        row,
        value->checkedBigInt(~builder, ~min=0n, ~max=18446744073709551615n),
      )
    | I64 =>
      builder.signed->TypedArray.set(
        row,
        value->checkedBigInt(~builder, ~min=-9223372036854775808n, ~max=9223372036854775807n),
      )
    | Text => builder.texts->Array.setUnsafe(row, value->toText(~replacer=builder.replacer))
    }
)

%%private(let isAbsent = (value: unknown) => value === %raw(`undefined`) || value === %raw(`null`))

// Writes one value of a row the handler set. `undefined`/`null` marks the row's
// null bit, which a column that accepts NULL stores as such — and which one that
// does not has no way to store: RowBinary carries no "absent", so the row would
// land holding the type's zero, a value the handler never chose and that nothing
// downstream could tell from one it did.
let writeValue = (builder, ~row, value: unknown) =>
  if value->isAbsent {
    if builder.isNullable {
      builder->markNull(~row)
    } else {
      JsError.throwWithMessage(
        `No value for the \`${builder.name}\` column, which is not nullable. Set the field before saving the entity, or make it optional in the schema.`,
      )
    }
  } else {
    builder->writePresent(~row, value)
  }

let writeDeletedValue = (builder, ~row, value: unknown) =>
  if value->isAbsent {
    builder->markNull(~row)
  } else {
    builder->writePresent(~row, value)
  }

let builderPayload = (builder): columnValuesInput => {
  let base = {nulls: ?builder.nulls}
  switch builder.kind {
  | F64 => {...base, numbers: builder.floats}
  | U64 => {...base, unsigned64: builder.unsigned}
  | I64 => {...base, signed64: builder.signed}
  | Text => {...base, texts: builder.texts}
  }
}
