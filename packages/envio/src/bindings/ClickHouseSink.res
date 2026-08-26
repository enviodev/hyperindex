// Binding to the Rust `ClickHouseSink` napi class, plus the columnar builders
// that feed it.
//
// A table is registered once, before any batch, and Rust hands back a handle. A
// batch then crosses as that handle plus one payload per column — a typed array
// for numeric columns, an array of strings for text-ish ones — instead of a JS
// object per row, and without re-sending the shape.

type t

// The column and table names envio's history format fixes.
type historySchema = {
  idColumn: string,
  checkpointIdColumn: string,
  changeColumn: string,
  changeVariants: array<string>,
  setVariant: string,
  checkpointsTable: string,
  historyTablePrefix: string,
}

type options = {
  url: string,
  username: string,
  password: string,
  database: string,
  chainIdMode: string,
  history: historySchema,
}

// The warning callback is how a degradation reaches the indexer's logger while
// it is still happening: retries run inside a single write, so anything handed
// back at the end would only be read once the episode is over.
@send external classNew: (Core.clickHouseSinkCtor, options, string => unit) => t = "new"

// A column as the Rust `ColumnSpecInput` object expects it: the schema field it
// stores, not the ClickHouse type it lands in.
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

// One entity as Rust needs it: the table its history goes to, the columns it
// declares, and the layout options its `@storage` directive asked for.
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

// What registration hands back: the handle every batch quotes, and the wire
// kind each column must be sent as.
type registeredTable = {
  handle: int,
  // Every column the table declares, in the order a batch must send them. A
  // history table carries two columns beyond the entity's own.
  names: array<string>,
  kinds: array<int>,
  // Whether each column accepts NULL, which decides whether a row with no value
  // for it is stored as absent or refused.
  nullable: array<bool>,
}

// Column payload as the Rust `ColumnValuesInput` object expects it: exactly one
// of the value fields is set.
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

@send external resume: (t, string) => promise<unit> = "resume"

@send
external stage: (t, ~table: int, ~rows: int, ~columns: array<columnValuesInput>) => int = "stage"

// Entity batches go in together and the checkpoints that cover them go last —
// the ordering the current-state views depend on, enforced where the inserts
// happen rather than by the caller.
@send
external writeBatch: (t, ~entities: array<int>, ~checkpoints: Null.t<int>) => promise<unit> =
  "writeBatch"

// Frees handles a failed write never reached, so they don't sit staged for the
// life of the process.
@send external discard: (t, array<int>) => unit = "discard"

let make = (~url, ~username, ~password, ~database, ~chainIdMode: ChainId.mode, ~onWarning) =>
  Core.getAddon().clickHouseSink->classNew(
    {
      url,
      username,
      password,
      database,
      // Sent in the form it is already serialized in, which is the one Rust
      // reads it back from.
      chainIdMode: (chainIdMode :> string),
      history: {
        idColumn: Table.idFieldName,
        checkpointIdColumn: EntityHistory.checkpointIdFieldName,
        changeColumn: EntityHistory.changeFieldName,
        changeVariants: EntityHistory.RowAction.variants->Array.map(variant => (variant :> string)),
        setVariant: (EntityHistory.RowAction.SET :> string),
        checkpointsTable: InternalTable.Checkpoints.table.tableName,
        historyTablePrefix: EntityHistory.historyTablePrefix,
      },
    },
    onWarning,
  )

// How a column's values travel, resolved by Rust from the column's type.
type kind =
  | @as(0) F64
  | @as(1) U64
  | @as(2) I64
  | @as(3) Text

// The ordinals cross as bare integers, so a kind Rust added is a kind this side
// has never heard of — and reading it as one of these would allocate the wrong
// typed array and store the column's values as something else. Runs once per
// column of a registered table.
let kindOfOrdinal = ordinal =>
  switch ordinal {
  | 0 => F64
  | 1 => U64
  | 2 => I64
  | 3 => Text
  | unknown => JsError.throwWithMessage(`Unknown ClickHouse column kind ${unknown->Int.toString}`)
  }

// A registered table: the handle its batches quote, and its columns with the
// wire kind Rust resolved for each.
type column = {name: string, kind: kind, isNullable: bool}
type table = {handle: int, name: string, columns: array<column>}

let makeTable = (~name, {handle, names, kinds, nullable}: registeredTable) => {
  handle,
  name,
  columns: names->Array.mapWithIndex((name, index) => {
    name,
    kind: kinds->Array.getUnsafe(index)->kindOfOrdinal,
    isNullable: nullable->Array.getUnsafe(index),
  }),
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
  let jsonSafe = (~column) => (_, value: JSON.t) =>
    switch value->typeof {
    | #bigint => value->(Utils.magic: JSON.t => unknown)->stringOf->(Utils.magic: string => JSON.t)
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

// A JSON-ready value straight out of the entity's ClickHouse schema. Anything
// that isn't already a string — a `Json` field's object, an array column's
// elements — becomes its JSON text, which is what the target column stores.
let toText = (value: unknown, ~replacer) =>
  switch value->typeof {
  | #string => value->asString
  | #bigint => value->stringOf
  | _ => value->(Utils.magic: unknown => JSON.t)->JSON.stringify(~replacer)
  }

// One column's storage for one batch, sized to the batch's row count so the
// typed arrays reach Rust without a copy. A builder belongs to a single write:
// `stage` copies it into Rust memory, and nothing reads it afterwards.
type builder = {
  name: string,
  kind: kind,
  isNullable: bool,
  floats: Float64Array.t,
  unsigned: BigUint64Array.t,
  signed: BigInt64Array.t,
  texts: array<string>,
  // Built with the builder rather than per cell: the closure closes over the
  // column name, which is fixed for the whole batch.
  replacer: JSON.replacer,
  // Allocated on the first null; a column with none sends no mask at all.
  mutable nulls: option<Uint8Array.t>,
  rows: int,
}

%%private(let noFloats = Float64Array.fromLength(0))
%%private(let noUnsigned = BigUint64Array.fromLength(0))
%%private(let noSigned = BigInt64Array.fromLength(0))

// Only the storage the column's kind uses is allocated; the rest share one
// empty array, since nothing ever reads or writes them.
let makeBuilder = ({name, kind, isNullable}: column, ~rows) => {
  name,
  kind,
  isNullable,
  floats: kind === F64 ? Float64Array.fromLength(rows) : noFloats,
  unsigned: kind === U64 ? BigUint64Array.fromLength(rows) : noUnsigned,
  signed: kind === I64 ? BigInt64Array.fromLength(rows) : noSigned,
  texts: kind === Text ? Array.make(~length=rows, "") : [],
  replacer: Replacer(jsonSafe(~column=name)),
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

// Writes one value of a row the handler set. `undefined`/`null` marks the row's
// null bit, which a column that accepts NULL stores as such — and which one that
// does not has no way to store: RowBinary carries no "absent", so the row would
// land holding the type's zero, a value the handler never chose and that nothing
// downstream could tell from one it did.
// What both writers below read as "the row has no value here", kept in one place
// so a SET row and a DELETE row cannot start disagreeing about it.
%%private(let isAbsent = (value: unknown) => value === %raw(`undefined`) || value === %raw(`null`))

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

// Writes one value of a DELETE row, which carries only the columns identifying
// what was deleted. The rest are deliberately absent and take the column's
// default, so an unset one is not the mistake it would be on a row that set it.
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
