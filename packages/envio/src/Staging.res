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

type builder = {
  name: string,
  kind: kind,
  isNullable: bool,
  isVariable: bool,
  replacer: JSON.replacer,
  // Which column this is, and which buffer of the lent array carries its
  // payload — `grow` replaces that one so the commit detaches what is live.
  index: int,
  dataSlot: int,
  floats: Float64Array.t,
  unsigned: BigUint64Array.t,
  signed: BigInt64Array.t,
  mutable data: Uint8Array.t,
  ends: Uint32Array.t,
  nulls: Uint8Array.t,
  // Where this column's next value starts. A row's bytes run from the previous
  // row's end to its own, so every row has to set `ends`, null ones included.
  mutable cursor: int,
}

type t = {
  arena: arena,
  handle: int,
  buffers: array<ArrayBuffer.t>,
  builders: array<builder>,
}

%%private(let noFloats = Float64Array.fromLength(0))
%%private(let noUnsigned = BigUint64Array.fromLength(0))
%%private(let noSigned = BigInt64Array.fromLength(0))
%%private(let noBytes = Uint8Array.fromLength(0))
%%private(let noEnds = Uint32Array.fromLength(0))

let begin = (arena, ~table, ~rows, ~columns: array<column>) => {
  let {handle, buffers} = arena.beginStage(~table, ~rows)
  let slot = ref(0)
  let builders = columns->Array.mapWithIndex(({name, kind, isNullable, replacer}, index) => {
    let take = () => {
      let buffer = buffers->Array.getUnsafe(slot.contents)
      slot := slot.contents + 1
      buffer
    }
    switch kind {
    | F64 | U64 | I64 =>
      let values = take()
      {
        name,
        kind,
        isNullable,
        isVariable: false,
        replacer,
        index,
        dataSlot: -1,
        floats: kind === F64 ? Float64Array.fromBuffer(values) : noFloats,
        unsigned: kind === U64 ? BigUint64Array.fromBuffer(values) : noUnsigned,
        signed: kind === I64 ? BigInt64Array.fromBuffer(values) : noSigned,
        data: noBytes,
        ends: noEnds,
        nulls: Uint8Array.fromBuffer(take()),
        cursor: 0,
      }
    | Text | Bytes =>
      let dataSlot = slot.contents
      let data = take()
      {
        name,
        kind,
        isNullable,
        isVariable: true,
        replacer,
        index,
        dataSlot,
        floats: noFloats,
        unsigned: noUnsigned,
        signed: noSigned,
        data: Uint8Array.fromBuffer(data),
        ends: Uint32Array.fromBuffer(take()),
        nulls: Uint8Array.fromBuffer(take()),
        cursor: 0,
      }
    }
  })
  {arena, handle, buffers, builders}
}

%%private(
  let ensure = (stage, builder, ~needed) =>
    if needed > builder.data->TypedArray.length {
      let fresh = stage.arena.growStage(
        ~handle=stage.handle,
        ~column=builder.index,
        ~needed,
        ~stale=builder.data->TypedArray.buffer,
      )
      stage.buffers->Array.setUnsafe(builder.dataSlot, fresh)
      builder.data = Uint8Array.fromBuffer(fresh)
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

%%private(
  let writeText = (stage, builder, ~row, text) => {
    // `encodeInto` takes no destination offset, so the room has to be there
    // before the subarray is taken. One byte per UTF-16 unit is what an ASCII
    // id or hash needs, and `read` says when that guess was short: UTF-8 spends
    // at most three bytes per unit, which is what a surrogate pair costs across
    // its two.
    let units = text->String.length
    stage->ensure(builder, ~needed=builder.cursor + units)
    let {read, written} =
      encoder->encodeInto(text, builder.data->TypedArray.subarray(~start=builder.cursor))
    let written = if read < units {
      stage->ensure(builder, ~needed=builder.cursor + units * 3)
      let {written} =
        encoder->encodeInto(text, builder.data->TypedArray.subarray(~start=builder.cursor))
      written
    } else {
      written
    }
    builder.cursor = builder.cursor + written
    builder.ends->TypedArray.set(row, builder.cursor)
  }
)

%%private(
  let writeBytes = (stage, builder, ~row, bytes: Uint8Array.t) => {
    let length = bytes->TypedArray.length
    stage->ensure(builder, ~needed=builder.cursor + length)
    builder.data->setFrom(bytes, builder.cursor)
    builder.cursor = builder.cursor + length
    builder.ends->TypedArray.set(row, builder.cursor)
  }
)

%%private(
  let markNull = (builder, ~row) => {
    builder.nulls->TypedArray.set(row, 1)
    if builder.isVariable {
      builder.ends->TypedArray.set(row, builder.cursor)
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
    switch builder.kind {
    | F64 =>
      builder.floats->TypedArray.set(row, value->toNumber->finiteOrThrow(~column=builder.name))
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
    | Text => stage->writeText(builder, ~row, value->toText(~replacer=builder.replacer))
    | Bytes => stage->writeBytes(builder, ~row, value->(Utils.magic: unknown => Uint8Array.t))
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
