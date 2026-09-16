// Reading a result set out of a Rust-owned arena.
//
// The mirror of `Staging.res`: there JavaScript writes into lent buffers and
// Rust reads them, here Rust has written and JavaScript reads. The ownership
// and phase rules are the same ones, written down at the top of
// `packages/cli/src/columnar/mod.rs` — the buffers stay valid only until they
// are handed back, and reading one after that is what detaching prevents.

// What a column becomes, which is more than the slot it travels in: a boolean,
// a timestamp and a float all ride in the same eight bytes.
type kind =
  | @as(0) Float
  | @as(1) Bool
  | @as(2) Timestamp
  | @as(3) Text
  | @as(4) Bytes
  | @as(5) List
  | @as(6) Json

let kindOfOrdinal = ordinal =>
  switch ordinal {
  | 0 => Float
  | 1 => Bool
  | 2 => Timestamp
  | 3 => Text
  | 4 => Bytes
  | 5 => List
  | 6 => Json
  | unknown => JsError.throwWithMessage(`Unknown result column kind ${unknown->Int.toString}`)
  }

// A variable-width column: the bytes of every row end to end, and where each
// row's own bytes stop. The row before says where they start.
type variable = {data: Uint8Array.t, ends: Uint32Array.t}

type rec reader =
  | Floats(Float64Array.t)
  | Booleans(Float64Array.t)
  | Timestamps(Float64Array.t)
  | Texts(variable)
  | Documents(variable)
  | Blobs(variable)
  // The elements read as a column of their own, and `rowEnds` cutting them into
  // rows.
  | Lists({elements: reader, elementNulls: Uint8Array.t, rowEnds: Uint32Array.t})

@get_index external floatAt: (Float64Array.t, int) => float = ""
@get_index external flagAt: (Uint8Array.t, int) => int = ""
@get_index external offsetAt: (Uint32Array.t, int) => int = ""

// Node decodes UTF-8 from a range of a buffer without being handed a view of
// that range, which is what makes a column's text one call per row and no
// allocation per row besides the string itself.
type nodeBuffer
@val @scope("Buffer")
external bufferOver: (ArrayBuffer.t, int, int) => nodeBuffer = "from"
@send external utf8Between: (nodeBuffer, @as("utf8") _, int, int) => string = "toString"

%%private(
  let textOf = (variable: variable) =>
    bufferOver(
      variable.data->TypedArray.buffer,
      variable.data->TypedArray.byteOffset,
      variable.data->TypedArray.byteLength,
    )
)

%%private(
  let boundsOf = (variable, index) => {
    let end = variable.ends->offsetAt(index)
    let start = index === 0 ? 0 : variable.ends->offsetAt(index - 1)
    (start, end)
  }
)

// Takes the buffers a column's kind lays out, in the order Rust lends them:
// the values, then a variable column's offsets, then the null flags — and for a
// list, its elements' own buffers first of all.
%%private(
  let rec takeReader = (buffers, cursor, ~kind, ~elementKind) => {
    let take = () => {
      let buffer = buffers->Array.getUnsafe(cursor.contents)
      cursor := cursor.contents + 1
      buffer
    }
    let takeVariable = () => {
      let data = Uint8Array.fromBuffer(take())
      let ends = Uint32Array.fromBuffer(take())
      {data, ends}
    }
    switch kind {
    | Float => Floats(Float64Array.fromBuffer(take()))
    | Bool => Booleans(Float64Array.fromBuffer(take()))
    | Timestamp => Timestamps(Float64Array.fromBuffer(take()))
    | Text => Texts(takeVariable())
    | Json => Documents(takeVariable())
    | Bytes => Blobs(takeVariable())
    | List =>
      let elements = takeReader(buffers, cursor, ~kind=elementKind, ~elementKind=Float)
      let elementNulls = Uint8Array.fromBuffer(take())
      let rowEnds = Uint32Array.fromBuffer(take())
      Lists({elements, elementNulls, rowEnds})
    }
  }
)

%%private(
  let readers = (~buffers, ~kinds, ~elementKinds) => {
    let cursor = ref(0)
    kinds->Array.mapWithIndex((ordinal, index) => {
      let elementKind = switch elementKinds->Array.getUnsafe(index) {
      | -1 => Float
      | ordinal => ordinal->kindOfOrdinal
      }
      let reader = takeReader(buffers, cursor, ~kind=ordinal->kindOfOrdinal, ~elementKind)
      let nulls = Uint8Array.fromBuffer(buffers->Array.getUnsafe(cursor.contents))
      cursor := cursor.contents + 1
      (reader, nulls)
    })
  }
)

// A column's values as a plain array, decoded in one pass. The kind is
// switched on once for the whole column rather than once per cell, which is
// what lets each of these be a tight loop over one buffer.
//
// A row the statement returned NULL for keeps the `null` the array starts out
// holding.
%%private(
  let rec materialize = (reader, ~nulls, ~count): array<unknown> => {
    let values = Array.make(~length=count, %raw(`null`))
    let present = row => nulls->flagAt(row) === 0
    switch reader {
    | Floats(source) =>
      for row in 0 to count - 1 {
        if present(row) {
          values->Array.setUnsafe(row, source->floatAt(row)->(Utils.magic: float => unknown))
        }
      }
    | Booleans(source) =>
      for row in 0 to count - 1 {
        if present(row) {
          values->Array.setUnsafe(
            row,
            (source->floatAt(row) !== 0.)->(Utils.magic: bool => unknown),
          )
        }
      }
    | Timestamps(source) =>
      for row in 0 to count - 1 {
        if present(row) {
          values->Array.setUnsafe(
            row,
            source->floatAt(row)->Date.fromTime->(Utils.magic: Date.t => unknown),
          )
        }
      }
    | Texts(variable) =>
      let text = textOf(variable)
      for row in 0 to count - 1 {
        if present(row) {
          let (start, end) = boundsOf(variable, row)
          values->Array.setUnsafe(
            row,
            text->utf8Between(start, end)->(Utils.magic: string => unknown),
          )
        }
      }
    | Documents(variable) =>
      let text = textOf(variable)
      for row in 0 to count - 1 {
        if present(row) {
          let (start, end) = boundsOf(variable, row)
          values->Array.setUnsafe(
            row,
            text->utf8Between(start, end)->JSON.parseOrThrow->(Utils.magic: JSON.t => unknown),
          )
        }
      }
    | Blobs(variable) =>
      // The arena's memory is detached once the result is handed back, so the
      // bytes have to be copied out — but once for the column rather than once
      // per row, leaving each row a view over what the column already owns.
      let owned = variable.data->TypedArray.slice(~start=0, ~end=variable.data->TypedArray.length)
      for row in 0 to count - 1 {
        if present(row) {
          let (start, end) = boundsOf(variable, row)
          values->Array.setUnsafe(
            row,
            owned->TypedArray.subarray(~start, ~end)->(Utils.magic: Uint8Array.t => unknown),
          )
        }
      }
    | Lists({elements, elementNulls, rowEnds}) =>
      // The elements are a column of their own, so they decode the same way
      // once, and a row is the run of them `rowEnds` cuts out.
      let elementValues = materialize(
        elements,
        ~nulls=elementNulls,
        ~count=count === 0 ? 0 : rowEnds->offsetAt(count - 1),
      )
      for row in 0 to count - 1 {
        if present(row) {
          let end = rowEnds->offsetAt(row)
          let start = row === 0 ? 0 : rowEnds->offsetAt(row - 1)
          values->Array.setUnsafe(
            row,
            elementValues->Array.slice(~start, ~end)->(Utils.magic: array<unknown> => unknown),
          )
        }
      }
    }
    values
  }
)

// Builds the rows of one result shape. Compiled per set of column names so a
// row is one object literal with every field in place: adding them one at a
// time instead costs a hidden-class transition each, per row.
type builder = (array<array<unknown>>, int) => array<dict<unknown>>

%%private(
  let compile: array<string> => builder = %raw(`(names) => new Function(
    "columns",
    "rows",
    names.map((_, index) => "const c" + index + " = columns[" + index + "];").join("") +
      "const out = new Array(rows);" +
      "for (let row = 0; row < rows; row++) out[row] = {" +
      names.map((name, index) => JSON.stringify(name) + ": c" + index + "[row]").join(",") +
      "};" +
      "return out;",
  )`)
)

%%private(let builders: Map.t<string, builder> = Map.make())

%%private(
  let builderFor = names => {
    let key = names->(Utils.magic: array<string> => JSON.t)->JSON.stringify
    switch builders->Map.get(key) {
    | Some(builder) => builder
    | None =>
      let builder = compile(names)
      builders->Map.set(key, builder)
      builder
    }
  }
)

// The result as the objects the entity schemas parse.
let rows = (~buffers, ~names, ~kinds, ~elementKinds, ~rows as count) =>
  builderFor(names)(
    readers(~buffers, ~kinds, ~elementKinds)->Array.map(((reader, nulls)) =>
      materialize(reader, ~nulls, ~count)
    ),
    count,
  )
