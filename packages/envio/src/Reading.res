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

type column = {name: string, reader: reader, nulls: Uint8Array.t}

@get_index external floatAt: (Float64Array.t, int) => float = ""
@get_index external flagAt: (Uint8Array.t, int) => int = ""
@get_index external offsetAt: (Uint32Array.t, int) => int = ""

type textDecoder
@new external makeTextDecoder: unit => textDecoder = "TextDecoder"
@send external decode: (textDecoder, Uint8Array.t) => string = "decode"

@val @scope("Buffer") external bufferFrom: Uint8Array.t => Uint8Array.t = "from"

%%private(let decoder = makeTextDecoder())

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

let columns = (~buffers, ~names, ~kinds, ~elementKinds) => {
  let cursor = ref(0)
  names->Array.mapWithIndex((name, index) => {
    let kind = kinds->Array.getUnsafe(index)->kindOfOrdinal
    let elementKind = switch elementKinds->Array.getUnsafe(index) {
    | -1 => Float
    | ordinal => ordinal->kindOfOrdinal
    }
    let reader = takeReader(buffers, cursor, ~kind, ~elementKind)
    let nulls = Uint8Array.fromBuffer(buffers->Array.getUnsafe(cursor.contents))
    cursor := cursor.contents + 1
    {name, reader, nulls}
  })
}

// One value, as the driver this replaces would have produced it. A `numeric` and
// an `int8` are text because that is what it gave; a timestamp arrives as the
// milliseconds a `Date` is built from.
%%private(
  let rec valueAt = (reader, index) =>
    switch reader {
    | Floats(values) => values->floatAt(index)->(Utils.magic: float => unknown)
    | Booleans(values) => (values->floatAt(index) !== 0.)->(Utils.magic: bool => unknown)
    | Timestamps(values) => values->floatAt(index)->Date.fromTime->(Utils.magic: Date.t => unknown)
    | Texts(variable) =>
      let (start, end) = boundsOf(variable, index)
      decoder
      ->decode(variable.data->TypedArray.subarray(~start, ~end))
      ->(Utils.magic: string => unknown)
    | Documents(variable) =>
      let (start, end) = boundsOf(variable, index)
      decoder
      ->decode(variable.data->TypedArray.subarray(~start, ~end))
      ->JSON.parseOrThrow
      ->(Utils.magic: JSON.t => unknown)
    | Blobs(variable) =>
      let (start, end) = boundsOf(variable, index)
      // A `Buffer`, and a copy of the bytes rather than a view over them: the
      // driver this replaces handed back a `Buffer`, and the arena's memory is
      // detached once the result is returned.
      bufferFrom(variable.data->TypedArray.subarray(~start, ~end))->(
        Utils.magic: Uint8Array.t => unknown
      )
    | Lists({elements, elementNulls, rowEnds}) =>
      let end = rowEnds->offsetAt(index)
      let start = index === 0 ? 0 : rowEnds->offsetAt(index - 1)
      let items = []
      for element in start to end - 1 {
        items
        ->Array.push(
          elementNulls->flagAt(element) === 0 ? elements->valueAt(element) : %raw(`null`),
        )
        ->ignore
      }
      items->(Utils.magic: array<unknown> => unknown)
    }
)

// The rows as objects, which is the shape the entity schemas parse. Every row
// is built the same way in the same order, so they share one hidden class
// rather than one per row.
let rows = (columns: array<column>, ~rows as rowCount) => {
  let result = []
  for row in 0 to rowCount - 1 {
    let object = Dict.make()
    columns->Array.forEach(({name, reader, nulls}) => {
      object->Dict.set(name, nulls->flagAt(row) === 0 ? reader->valueAt(row) : %raw(`null`))
    })
    result->Array.push(object)->ignore
  }
  result
}
