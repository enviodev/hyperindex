// Laying a batch of rows into the arena for Postgres to take.
//
// The values are written where they will be read from, and the statement's
// parameters are built from them in Rust rather than by the driver.
//
// Measured against the driver this replaced, on a six-column table of 60k rows,
// this is a wash: the batch write spends most of its time waiting on the server,
// and the values still cross from JavaScript one at a time either way. It is
// here because it is the shape the ClickHouse sink already writes through, not
// because it made the write cheaper. `packages/envio-tests/bench.mjs` is what
// says so.

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

// A column of arrays has no slot: the arena carries one value per row, and an
// array is a value the row holds rather than a run of them. A table with one
// binds its parameters as text instead.
let canStage = (fields: array<Table.field>) => fields->Array.every(field => !field.isArray)

let columns = (fields: array<Table.field>): array<Staging.column> =>
  fields->Array.map(field => {
    Staging.name: field->Table.getPgDbFieldName,
    kind: field.fieldType->slotFor,
    isNullable: field.isNullable,
    replacer: %raw(`undefined`),
  })

// Lays a batch into the arena, column by column. The values are the ones the
// table's own schema produced — a bigint as its digits, a date as its text, a
// boolean as the number the statement's cast expects — so nothing here has to
// know what a column means, only where its values go.
//
// The rows of a column are written in order because a variable-width slot's row
// starts where the row before it ended.
let stage = (
  arena,
  ~table,
  ~columns: array<Staging.column>,
  ~values: array<array<unknown>>,
  ~rows,
) => {
  let stage = arena->Staging.begin(~table, ~rows, ~columns)
  try {
    for column in 0 to columns->Array.length - 1 {
      let values = values->Array.getUnsafe(column)
      for row in 0 to rows - 1 {
        stage->Staging.writeValue(~column, ~row, values->Array.getUnsafe(row))
      }
    }
    stage->Staging.commit
  } catch {
  | exn =>
    stage->Staging.abort
    throw(exn)
  }
}
