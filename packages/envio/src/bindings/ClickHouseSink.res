// Binding to the Rust `ClickHouseSink` napi class, plus the columnar builders
// that feed it.
//
// Rust owns everything ClickHouse-shaped: it derives each column's type from
// the schema field the column stores, renders the DDL from that same
// derivation, and encodes RowBinary against it. What crosses from here is the
// schema — field types, names, table options — never a ClickHouse type, so
// there is nothing for the two sides to disagree about.
//
// A table is registered once, before any batch, and Rust hands back a handle. A
// batch then crosses as that handle plus one payload per column — a typed array
// for numeric columns, an array of strings for text-ish ones — instead of a JS
// object per row, and without re-sending the shape.

type t

// The column and table names envio's history format fixes. They cross once, at
// construction, so Rust reads them rather than defining a second copy.
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
  // Every column the table declares, in the order a batch must send them —
  // Rust's list, not one rebuilt here: a history table carries two columns
  // beyond the entity's own.
  names: array<string>,
  kinds: array<int>,
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

// Creates the database, the history tables and the views over them.
@send external initialize: (t, initializeInput) => promise<unit> = "initialize"

// Drops everything written past the checkpoint Postgres committed.
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

@send external exec: (t, string) => promise<unit> = "exec"
@send external query: (t, string) => promise<string> = "query"

let make = (~url, ~username, ~password, ~database, ~chainIdMode: ChainId.mode, ~onWarning) =>
  Core.getAddon().clickHouseSink->classNew(
    {
      url,
      username,
      password,
      database,
      chainIdMode: switch chainIdMode {
      | Int32 => "Int32"
      | Int64 => "Int64"
      },
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

// How a column's values travel. Derived by Rust from the column's ClickHouse
// type rather than mapped from `Table.fieldType` a second time: a JS copy of
// that mapping could only ever be found wrong at runtime, as a rejected insert
// against a live table.
type kind =
  | @as(0) F64
  | @as(1) U64
  | @as(2) I64
  | @as(3) Text

external kindOfOrdinal: int => kind = "%identity"

// A registered table: the handle its batches quote, and its columns with the
// wire kind Rust resolved for each.
type column = {name: string, kind: kind}
type table = {handle: int, name: string, columns: array<column>}

let makeTable = (~name, {handle, names, kinds}: registeredTable) => {
  handle,
  name,
  columns: names->Array.mapWithIndex((name, index) => {
    name,
    kind: kinds->Array.getUnsafe(index)->kindOfOrdinal,
  }),
}

%%private(let isString: unknown => bool = %raw(`(v) => typeof v === "string"`))
%%private(let isBigInt: unknown => bool = %raw(`(v) => typeof v === "bigint"`))
external asString: unknown => string = "%identity"
@val external toNumber: unknown => float = "Number"
@val external toBigInt: unknown => bigint = "BigInt"
@val external stringOf: unknown => string = "String"

// A JSON-ready value straight out of the entity's ClickHouse schema. Anything
// that isn't already a string — a `Json` field's object, an array column's
// elements — becomes its JSON text, which is what the target column stores.
// A native bigint is rendered directly: `JSON.stringify` throws on one, which
// would fail the whole batch before it reached `stage`.
let toText = (value: unknown) =>
  if value->isString {
    value->asString
  } else if value->isBigInt {
    value->stringOf
  } else {
    value
    ->(Utils.magic: unknown => JSON.t)
    ->JSON.stringify(
      ~replacer=Replacer(
        (_, value) => {
          let value = value->(Utils.magic: JSON.t => unknown)
          value->isBigInt
            ? value->stringOf->(Utils.magic: string => JSON.t)
            : value->(Utils.magic: unknown => JSON.t)
        },
      ),
    )
  }

// One column's storage for one batch, sized to the batch's row count so the
// typed arrays reach Rust without a copy. A builder belongs to a single write:
// `stage` copies it into Rust memory, and nothing reads it afterwards.
type builder = {
  name: string,
  kind: kind,
  floats: Float64Array.t,
  unsigned: BigUint64Array.t,
  signed: BigInt64Array.t,
  texts: array<string>,
  // Allocated on the first null; a column with none sends no mask at all.
  mutable nulls: option<Uint8Array.t>,
  rows: int,
}

// Only the storage the column's kind uses is allocated; the rest stay empty.
let makeBuilder = ({name, kind}: column, ~rows) => {
  let empty = 0
  {
    name,
    kind,
    floats: Float64Array.fromLength(kind === F64 ? rows : empty),
    unsigned: BigUint64Array.fromLength(kind === U64 ? rows : empty),
    signed: BigInt64Array.fromLength(kind === I64 ? rows : empty),
    texts: kind === Text ? Array.make(~length=rows, "") : [],
    nulls: None,
    rows,
  }
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

// Writes one value into the column. `undefined`/`null` marks the row's null bit;
// the slot keeps its zero value, which is what a column omitted from a
// JSONEachRow row used to resolve to.
let writeValue = (builder, ~row, value: unknown) =>
  if value === %raw(`undefined`) || value === %raw(`null`) {
    builder->markNull(~row)
  } else {
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
    | Text => builder.texts->Array.setUnsafe(row, value->toText)
    }
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
