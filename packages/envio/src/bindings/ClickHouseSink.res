// Binding to the Rust `ClickHouseSink` napi class, plus the columnar builders
// that feed it.
//
// A batch crosses the boundary one column at a time — a typed array for numeric
// columns, one concatenated string plus per-row lengths for text-ish ones —
// instead of a JS object per row. Rust then encodes RowBinary and sends it from a
// tokio task, so neither the encode nor the HTTP round trip runs on the Node main
// thread.

type t

type options = {
  url: string,
  username: string,
  password: string,
  database: string,
}

@send external classNew: (Core.clickHouseSinkCtor, options) => t = "new"

// Column payload as the Rust `ColumnInput` object expects it: exactly one of the
// value fields is set.
type columnInput = {
  name: string,
  numbers?: Float64Array.t,
  unsigned64?: BigUint64Array.t,
  signed64?: BigInt64Array.t,
  text?: string,
  lengths?: Uint32Array.t,
  nulls?: Uint8Array.t,
}

@send
external stage: (t, ~table: string, ~rows: int, ~columns: array<columnInput>) => int = "stage"
@send external flush: (t, int) => promise<array<string>> = "flush"
@send external invalidateSchema: (t, string) => unit = "invalidateSchema"

let make = (~url, ~username, ~password, ~database) =>
  Core.getAddon().clickHouseSink->classNew({url, username, password, database})

// How a column's values travel. Derived from the same `Table.fieldType` the DDL
// is generated from, and pinned against the type ClickHouse reports for the
// column by `ClickHouseColumnKind_test`.
type kind =
  | @as(0) F64
  | @as(1) U64
  | @as(2) I64
  | @as(3) Text

let kindOfField = (~fieldType: Table.fieldType, ~isArray, ~chainIdMode: ChainId.mode) =>
  if isArray {
    // An array is sent as the JSON of its elements.
    Text
  } else {
    switch fieldType {
    | Int32
    | Uint32
    | Serial
    | Boolean
    | Number
    | Date => F64
    | ChainId =>
      switch chainIdMode {
      | Int32 => F64
      | Int64 => U64
      }
    | UInt52
    | UInt64 => U64
    | BigSerial => I64
    | BigInt(_)
    | BigDecimal(_)
    | String
    | Json
    | Enum(_) => Text
    }
  }

%%private(let isString: unknown => bool = %raw(`(v) => typeof v === "string"`))
external asString: unknown => string = "%identity"
@val external toNumber: unknown => float = "Number"
@val external toBigInt: unknown => bigint = "BigInt"

// A JSON-ready value straight out of the entity's ClickHouse schema. Anything
// that isn't already a string — a `Json` field's object, an array column's
// elements — becomes its JSON text, which is what the target column stores.
let toText = (value: unknown) =>
  if value->isString {
    value->asString
  } else {
    value->(Utils.magic: unknown => JSON.t)->JSON.stringify
  }

// One column's storage for a batch. Allocated per write at the batch's row count
// so the typed arrays reach Rust without a copy.
type builder = {
  name: string,
  kind: kind,
  mutable floats: Float64Array.t,
  mutable unsigned: BigUint64Array.t,
  mutable signed: BigInt64Array.t,
  mutable texts: array<string>,
  mutable lengths: Uint32Array.t,
  // Allocated on the first null; a column with none sends no mask at all.
  mutable nulls: option<Uint8Array.t>,
  mutable rows: int,
}

let makeBuilder = (~name, ~kind) => {
  name,
  kind,
  floats: Float64Array.fromLength(0),
  unsigned: BigUint64Array.fromLength(0),
  signed: BigInt64Array.fromLength(0),
  texts: [],
  lengths: Uint32Array.fromLength(0),
  nulls: None,
  rows: 0,
}

let allocBuilder = (builder, ~rows) => {
  builder.rows = rows
  builder.nulls = None
  switch builder.kind {
  | F64 => builder.floats = Float64Array.fromLength(rows)
  | U64 => builder.unsigned = BigUint64Array.fromLength(rows)
  | I64 => builder.signed = BigInt64Array.fromLength(rows)
  | Text =>
    builder.texts = Array.make(~length=rows, "")
    builder.lengths = Uint32Array.fromLength(rows)
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

// Writes one value into the column. `undefined`/`null` marks the row's null bit;
// the slot keeps its zero value, which is what a column omitted from a
// JSONEachRow row used to resolve to.
let writeValue = (builder, ~row, value: unknown) =>
  if value === %raw(`undefined`) || value === %raw(`null`) {
    builder->markNull(~row)
  } else {
    switch builder.kind {
    | F64 => builder.floats->TypedArray.set(row, value->toNumber)
    | U64 => builder.unsigned->TypedArray.set(row, value->toBigInt)
    | I64 => builder.signed->TypedArray.set(row, value->toBigInt)
    | Text =>
      let text = value->toText
      builder.texts->Array.setUnsafe(row, text)
      builder.lengths->TypedArray.set(row, text->String.length)
    }
  }

let builderPayload = (builder): columnInput => {
  let base = {name: builder.name, nulls: ?builder.nulls}
  switch builder.kind {
  | F64 => {...base, numbers: builder.floats}
  | U64 => {...base, unsigned64: builder.unsigned}
  | I64 => {...base, signed64: builder.signed}
  | Text => {
      ...base,
      // One concatenated string keeps the crossing to a single napi read; Rust
      // splits it with the UTF-16 lengths a JS string reports for free.
      text: builder.texts->Array.joinUnsafe(""),
      lengths: builder.lengths,
    }
  }
}
