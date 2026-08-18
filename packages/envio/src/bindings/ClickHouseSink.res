// Binding to the Rust `ClickHouseSink` napi class, plus the columnar builders
// that feed it.
//
// A table is registered once, before any batch: Rust parses its column types
// and hands back a handle. A batch then crosses the boundary as that handle
// plus one payload per column — a typed array for numeric columns, one
// concatenated string plus per-row lengths for text-ish ones — instead of a JS
// object per row, and without re-sending the shape. Rust encodes RowBinary and
// sends it from a tokio task, so neither the encode nor the HTTP round trip
// runs on the Node main thread.

type t

type options = {
  url: string,
  username: string,
  password: string,
  database: string,
}

// The warning callback is how a degradation reaches the indexer's logger while
// it is still happening: retries run inside a single write, so anything handed
// back at the end would only be read once the episode is over.
@send external classNew: (Core.clickHouseSinkCtor, options, string => unit) => t = "new"

// A column as the Rust `ColumnSpec` object expects it.
type columnSpec = {
  name: string,
  @as("chType")
  chType: string,
}

// What registration hands back: the handle every batch quotes, and the wire
// kind each column must be sent as.
type registeredTable = {
  handle: int,
  kinds: array<int>,
}

// Column payload as the Rust `ColumnValuesInput` object expects it: exactly one
// of the value fields is set.
type columnValuesInput = {
  numbers?: Float64Array.t,
  unsigned64?: BigUint64Array.t,
  signed64?: BigInt64Array.t,
  text?: string,
  lengths?: Uint32Array.t,
  nulls?: Uint8Array.t,
}

@send
external registerTable: (t, ~table: string, ~columns: array<columnSpec>) => registeredTable =
  "registerTable"

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

let make = (~url, ~username, ~password, ~database, ~onWarning) =>
  Core.getAddon().clickHouseSink->classNew({url, username, password, database}, onWarning)

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
type column = {name: string, chType: string, kind: kind}
type table = {handle: int, name: string, columns: array<column>}

// Registering parses every column type once and rejects one this encoder cannot
// hold, so a table envio cannot write is refused at startup rather than by the
// first batch that reaches the column.
let registerTableOrThrow = (sink, ~table, ~columns: array<columnSpec>) => {
  let {handle, kinds} = sink->registerTable(~table, ~columns)
  {
    handle,
    name: table,
    columns: columns->Array.mapWithIndex(({name, chType}, index) => {
      name,
      chType,
      kind: kinds->Array.getUnsafe(index)->kindOfOrdinal,
    }),
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

// One column's storage for one batch, sized to the batch's row count so the
// typed arrays reach Rust without a copy. A builder belongs to a single write:
// `stage` copies it into Rust memory, and nothing reads it afterwards.
type builder = {
  name: string,
  // Kept for the range messages below; the registered table is what tells Rust
  // how to encode, so this never crosses the boundary.
  chType: string,
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
let makeBuilder = ({name, chType, kind}: column, ~rows) => {
  let empty = 0
  {
    name,
    chType,
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

%%private(let isHighSurrogate = unit => unit >= 0xD800 && unit <= 0xDBFF)
%%private(let isLowSurrogate = unit => unit >= 0xDC00 && unit <= 0xDFFF)
let replacementCharacter = "\u{FFFD}"

// A lone surrogate is not a character, and napi already substitutes U+FFFD for
// one on the way to UTF-8 — which costs the value nothing, since both are a
// single UTF-16 unit. What no value survives on its own is the concatenation:
// a value ending in a high surrogate followed by one starting with a low
// surrogate spells a real pair across the seam, which napi then encodes as one
// 4-byte character where the two lengths each claim a unit, and the span scan
// rejects the whole column. Only a first or last unit can have its other half in
// a neighbouring value, so substituting at the two ends is the whole fix.
let withoutBoundarySurrogates = text => {
  let last = text->String.length - 1
  if last < 0 {
    text
  } else {
    let leading = text->String.charCodeAtUnsafe(0)->isLowSurrogate
    let trailing = text->String.charCodeAtUnsafe(last)->isHighSurrogate
    switch (leading, trailing) {
    | (false, false) => text
    | _ if last === 0 => replacementCharacter
    | _ =>
      (leading ? replacementCharacter : text->String.charAt(0)) ++
      text->String.slice(~start=1, ~end=last) ++ (
        trailing ? replacementCharacter : text->String.charAt(last)
      )
    }
  }
}

// RowBinary carries the raw integer, so a value the column cannot hold is not
// rejected anywhere downstream — and a typed array reduces it modulo 2^64 on
// the way in rather than refusing it, which would leave no trace at all.
%%private(
  let checkedBigInt = (value: unknown, ~builder, ~min, ~max) => {
    let value = value->toBigInt
    if value < min || value > max {
      JsError.throwWithMessage(
        `${value->BigInt.toString} is out of range for a ${builder.chType} column`,
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
    | Text =>
      let text = value->toText->withoutBoundarySurrogates
      builder.texts->Array.setUnsafe(row, text)
      builder.lengths->TypedArray.set(row, text->String.length)
    }
  }

let builderPayload = (builder): columnValuesInput => {
  let base = {nulls: ?builder.nulls}
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
