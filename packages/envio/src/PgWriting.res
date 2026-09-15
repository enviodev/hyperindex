// Laying a batch of rows into the arena for Postgres to take.
//
// The values are written where they will be read from, and the statement's
// parameters are built from them in Rust. The path this replaces serialized
// each row in JavaScript and handed the driver arrays to render — which for a
// `bytea` column meant building a hex literal a character at a time, the most
// expensive thing a batch write did.

// Which arena slot a column's values travel in.
//
// The slots are the ones the statement's own casts expect. A boolean goes in as
// a number because the insert binds `INTEGER[]::BOOLEAN[]`, and everything a
// double cannot hold exactly — a bigint, a decimal, a timestamp — goes in as
// text, which is what the driver being replaced sent for them too.
let slotFor = (fieldType: Table.fieldType) =>
    switch fieldType {
    | Boolean
    | Int32
    | Uint32
    | UInt52
    | SmallInt
    | Number
    | ChainId
    | Serial
    | BigSerial =>
      Staging.F64
    | Bytea => Staging.Bytes
    | String
    | UInt64
    | BigInt(_)
    | BigDecimal(_)
    | Json
    | Date
    | Enum(_) =>
      Staging.Text
    }

// A column of arrays has no slot: unnesting one would spread it across the rows
// instead of keeping it as a value, so a table holding one takes the statement
// that binds every cell on its own.
let canStage = (fields: array<Table.field>) => fields->Array.every(field => !field.isArray)

let columns = (fields: array<Table.field>): array<Staging.column> =>
  fields->Array.map(field => {
    Staging.name: field->Table.getPgDbFieldName,
    kind: field.fieldType->slotFor,
    isNullable: field.isNullable,
    replacer: %raw(`undefined`),
  })

@val @scope("Array") external isArray: unknown => bool = "isArray"
@send external toISOString: Date.t => string = "toISOString"

// Two values reach a text slot as something other than their own text. A `Date`
// is an object, and a `BigDecimal` is one too — left alone, both would be
// written as the JSON of an object rather than as the value the column takes.
%%private(
  let prepared = (fieldType: Table.fieldType, value: unknown) =>
    switch fieldType {
    | Date => value->(Utils.magic: unknown => Date.t)->toISOString->(Utils.magic: string => unknown)
    | BigDecimal(_) =>
      value
      ->(Utils.magic: unknown => BigDecimal.t)
      ->BigDecimal.toString
      ->(Utils.magic: string => unknown)

    | Boolean => (value === %raw(`true`) ? 1 : 0)->(Utils.magic: int => unknown)
    | _ => value
    }
)

// Fills one column of the batch. The rows are written in order because a
// variable-width slot's row starts where the row before it ended.
let stage = (arena, ~table, ~fields: array<Table.field>, ~rows: array<'row>) => {
  let stage = arena->Staging.begin(~table, ~rows=rows->Array.length, ~columns=columns(fields))
  try {
    fields->Array.forEachWithIndex((field, column) => {
      let fieldType = field.fieldType
      // The row object is keyed by the schema's name for the field, which a
      // `column_name_format` rename leaves alone.
      let key = field->Table.getApiFieldName
      for row in 0 to rows->Array.length - 1 {
        let value =
          rows->Array.getUnsafe(row)->(Utils.magic: 'row => dict<unknown>)->Dict.getUnsafe(key)
        switch value->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.toOption {
        | None => stage->Staging.writeValue(~column, ~row, %raw(`null`))
        | Some(value) => stage->Staging.writeValue(~column, ~row, prepared(fieldType, value))
        }
      }
    })
    stage->Staging.commit
  } catch {
  | exn =>
    stage->Staging.abort
    throw(exn)
  }
}
