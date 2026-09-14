// Filling a batch into a Rust-owned arena. The buffers below are lent by the
// addon and must be written only between `begin` and `commit`/`abort` — the
// rules, and why breaking them corrupts memory rather than failing a test, are
// written down at the top of `packages/cli/src/columnar/mod.rs`.

type kind =
  | @as(0) F64
  | @as(1) U64
  | @as(2) I64
  | @as(3) Text
  | @as(4) Bytes

let kindOfOrdinal = ordinal =>
  switch ordinal {
  | 0 => F64
  | 1 => U64
  | 2 => I64
  | 3 => Text
  | 4 => Bytes
  | unknown => JsError.throwWithMessage(`Unknown staged column kind ${unknown->Int.toString}`)
  }

// The replacer closes over nothing but the column's name, so it is built once
// with the column rather than once per column per batch.
type column = {name: string, kind: kind, isNullable: bool, replacer: JSON.replacer}

type begun = {handle: int, buffers: array<ArrayBuffer.t>}

// What the addon exposes, so this module stays free of any one sink's API.
type arena = {
  beginStage: (~table: int, ~rows: int) => begun,
  growStage: (~handle: int, ~column: int, ~needed: int, ~stale: ArrayBuffer.t) => ArrayBuffer.t,
  commitStage: (~handle: int, ~buffers: array<ArrayBuffer.t>) => unit,
  abortStage: (~handle: int, ~buffers: array<ArrayBuffer.t>) => unit,
}

type encodeResult = {read: int, written: int}
type textEncoder
@new external makeTextEncoder: unit => textEncoder = "TextEncoder"
@send external encodeInto: (textEncoder, string, Uint8Array.t) => encodeResult = "encodeInto"

%%private(let encoder = makeTextEncoder())

@send external setFrom: (Uint8Array.t, Uint8Array.t, int) => unit = "set"

// A variable-width column's payload and the offsets that cut it into rows.
// `cursor` is where the next value starts — a row's bytes run from the previous
// row's end to its own, so every row sets `ends`, the null ones included.
// `slot` is which of the lent buffers carries `data`, since `grow` replaces it
// and the commit has to detach what is live rather than what was handed out.
type variable = {
  mutable data: Uint8Array.t,
  ends: Uint32Array.t,
  slot: int,
  mutable cursor: int,
}

// One per column kind, holding only the view that kind writes through.
type storage =
  | Floats(Float64Array.t)
  | Unsigned(BigUint64Array.t)
  | Signed(BigInt64Array.t)
  | Text(variable)
  | Bytes(variable)

type builder = {
  name: string,
  isNullable: bool,
  replacer: JSON.replacer,
  index: int,
  storage: storage,
  nulls: Uint8Array.t,
}

type t = {
  arena: arena,
  handle: int,
  buffers: array<ArrayBuffer.t>,
  builders: array<builder>,
}

let begin = (arena, ~table, ~rows, ~columns: array<column>) => {
  let {handle, buffers} = arena.beginStage(~table, ~rows)
  let slot = ref(0)
  let take = () => {
    let buffer = buffers->Array.getUnsafe(slot.contents)
    slot := slot.contents + 1
    buffer
  }
  // Buffer order is the arena's: the values, then a variable column's offsets,
  // then the null flags.
  let takeVariable = () => {
    let slot = slot.contents
    let data = Uint8Array.fromBuffer(take())
    let ends = Uint32Array.fromBuffer(take())
    {data, ends, slot, cursor: 0}
  }
  let builders = columns->Array.mapWithIndex(({name, kind, isNullable, replacer}, index) => {
    let storage = switch kind {
    | F64 => Floats(Float64Array.fromBuffer(take()))
    | U64 => Unsigned(BigUint64Array.fromBuffer(take()))
    | I64 => Signed(BigInt64Array.fromBuffer(take()))
    | Text => Text(takeVariable())
    | Bytes => Bytes(takeVariable())
    }
    {name, isNullable, replacer, index, storage, nulls: Uint8Array.fromBuffer(take())}
  })
  {arena, handle, buffers, builders}
}

%%private(
  let ensure = (stage, builder, variable, ~needed) =>
    if needed > variable.data->TypedArray.length {
      let fresh = stage.arena.growStage(
        ~handle=stage.handle,
        ~column=builder.index,
        ~needed,
        ~stale=variable.data->TypedArray.buffer,
      )
      stage.buffers->Array.setUnsafe(variable.slot, fresh)
      variable.data = Uint8Array.fromBuffer(fresh)
    }
)

external asString: unknown => string = "%identity"
@val external toNumber: unknown => float = "Number"
@val external toBigInt: unknown => bigint = "BigInt"
@val external stringOf: unknown => string = "String"

// No column holds NaN or Infinity, but nothing downstream refuses them well: a
// list renders one as `null` on the way into JSON text, which the column then
// refuses for a reason naming `null` rather than what the handler wrote, and a
// scalar Float64 takes the raw bytes and stores a value no reader can render.
// Refused here instead, where the value is still itself, with one message for
// both shapes.
let finiteOrThrow = (number: float, ~column) =>
  if number->Float.isFinite {
    number
  } else {
    JsError.throwWithMessage(
      `${number->Float.toString} is not a finite number, so it cannot be stored in the \`${column}\` column. Store a finite number, or keep it out of the entity.`,
    )
  }

let toText = (value: unknown, ~replacer) =>
  switch value->typeof {
  | #string => value->asString
  | #bigint => value->stringOf
  | _ => value->(Utils.magic: unknown => JSON.t)->JSON.stringify(~replacer)
  }

// Copies `text` in as one byte per character, or returns -1 at the first
// character that needs more than one. An id, a hash, a decimal and an enum
// variant are all ASCII, which is most of what a text column ever holds, and
// this spares them the `subarray` that `encodeInto` needs to be given an
// offset — one short-lived object per cell is what the batch pays otherwise.
%%private(
  let writeAscii: (Uint8Array.t, string, int) => int = %raw(`(data, text, offset) => {
    const length = text.length;
    for (let index = 0; index < length; index++) {
      const code = text.charCodeAt(index);
      if (code > 0x7f) {
        return -1;
      }
      data[offset + index] = code;
    }
    return length;
  }`)
)

%%private(
  let writeText = (stage, builder, variable, ~row, text) => {
    // One byte per UTF-16 unit is what ASCII needs, so the room for the fast
    // path is the room for its guess. `read` says when the guess was short:
    // UTF-8 spends at most three bytes per unit, which is what a surrogate pair
    // costs across its two.
    let units = text->String.length
    stage->ensure(builder, variable, ~needed=variable.cursor + units)
    let written = switch variable.data->writeAscii(text, variable.cursor) {
    | -1 =>
      let {read, written} =
        encoder->encodeInto(text, variable.data->TypedArray.subarray(~start=variable.cursor))
      if read < units {
        stage->ensure(builder, variable, ~needed=variable.cursor + units * 3)
        let {written} =
          encoder->encodeInto(text, variable.data->TypedArray.subarray(~start=variable.cursor))
        written
      } else {
        written
      }
    | ascii => ascii
    }
    variable.cursor = variable.cursor + written
    variable.ends->TypedArray.set(row, variable.cursor)
  }
)

%%private(
  let writeBytes = (stage, builder, variable, ~row, bytes: Uint8Array.t) => {
    let length = bytes->TypedArray.length
    stage->ensure(builder, variable, ~needed=variable.cursor + length)
    variable.data->setFrom(bytes, variable.cursor)
    variable.cursor = variable.cursor + length
    variable.ends->TypedArray.set(row, variable.cursor)
  }
)

%%private(
  let markNull = (builder, ~row) => {
    builder.nulls->TypedArray.set(row, 1)
    // A row with no value still ends where the one before it did, or the row
    // after it would start before its own beginning.
    switch builder.storage {
    | Text(variable) | Bytes(variable) => variable.ends->TypedArray.set(row, variable.cursor)
    | Floats(_) | Unsigned(_) | Signed(_) => ()
    }
  }
)

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
  let writePresent = (stage, builder, ~row, value: unknown) =>
    switch builder.storage {
    | Floats(floats) =>
      floats->TypedArray.set(row, value->toNumber->finiteOrThrow(~column=builder.name))
    | Unsigned(unsigned) =>
      unsigned->TypedArray.set(
        row,
        value->checkedBigInt(~builder, ~min=0n, ~max=18446744073709551615n),
      )
    | Signed(signed) =>
      signed->TypedArray.set(
        row,
        value->checkedBigInt(~builder, ~min=-9223372036854775808n, ~max=9223372036854775807n),
      )
    | Text(variable) =>
      stage->writeText(builder, variable, ~row, value->toText(~replacer=builder.replacer))
    | Bytes(variable) =>
      stage->writeBytes(builder, variable, ~row, value->(Utils.magic: unknown => Uint8Array.t))
    }
)

%%private(let isAbsent = (value: unknown) => value === %raw(`undefined`) || value === %raw(`null`))

// Writes one value of a row the handler set. `undefined`/`null` marks the row's
// null bit, which a column that accepts NULL stores as such — and which one that
// does not has no way to store: RowBinary carries no "absent", so the row would
// land holding the type's zero, a value the handler never chose and that nothing
// downstream could tell from one it did.
let writeValue = (stage, ~column, ~row, value: unknown) => {
  let builder = stage.builders->Array.getUnsafe(column)
  if value->isAbsent {
    if builder.isNullable {
      builder->markNull(~row)
    } else {
      JsError.throwWithMessage(
        `No value for the \`${builder.name}\` column, which is not nullable. Set the field before saving the entity, or make it optional in the schema.`,
      )
    }
  } else {
    stage->writePresent(builder, ~row, value)
  }
}

let writeDeletedValue = (stage, ~column, ~row, value: unknown) => {
  let builder = stage.builders->Array.getUnsafe(column)
  if value->isAbsent {
    builder->markNull(~row)
  } else {
    stage->writePresent(builder, ~row, value)
  }
}

let columnCount = stage => stage.builders->Array.length

// Ends the filling phase and returns the handle the write is asked for. Every
// lent buffer is detached here, so a view left over from this stage throws on
// its next write instead of reaching memory Rust is reading.
let commit = stage => {
  stage.arena.commitStage(~handle=stage.handle, ~buffers=stage.buffers)
  stage.handle
}

let abort = stage => stage.arena.abortStage(~handle=stage.handle, ~buffers=stage.buffers)
