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

// The warning callback is how a degradation reaches the indexer's logger while
// it is still happening: retries run inside a single `flush`, so anything handed
// back at the end would only be read once the episode is over.
@send external classNew: (Core.clickHouseSinkCtor, options, string => unit) => t = "new"

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
@send external flush: (t, int) => promise<unit> = "flush"
@send external invalidateSchema: (t, string) => unit = "invalidateSchema"

let make = (~url, ~username, ~password, ~database, ~onWarning) =>
  Core.getAddon().clickHouseSink->classNew({url, username, password, database}, onWarning)

// How a column's values travel. Read back from the column's ClickHouse type
// rather than mapped from `Table.fieldType` a second time: Rust already derives
// the kind from that type to decide how to encode, so a JS copy of the mapping
// could only ever be found wrong at runtime, as a rejected insert against a live
// table.
type kind =
  | @as(0) F64
  | @as(1) U64
  | @as(2) I64
  | @as(3) Text

external kindOfOrdinal: int => kind = "%identity"

let kindOfClickHouseType = clickHouseType =>
  Core.getAddon().clickhouseColumnKind(clickHouseType)->kindOfOrdinal

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
  lengths: Uint32Array.t,
  // Allocated on the first null; a column with none sends no mask at all.
  mutable nulls: option<Uint8Array.t>,
  rows: int,
}

// Only the storage the column's kind uses is allocated; the rest stay empty.
let makeBuilder = (~name, ~kind, ~rows) => {
  let empty = 0
  {
    name,
    kind,
    floats: Float64Array.fromLength(kind === F64 ? rows : empty),
    unsigned: BigUint64Array.fromLength(kind === U64 ? rows : empty),
    signed: BigInt64Array.fromLength(kind === I64 ? rows : empty),
    texts: kind === Text ? Array.make(~length=rows, "") : [],
    lengths: Uint32Array.fromLength(kind === Text ? rows : empty),
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
