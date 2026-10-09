let columns = (fields: array<Table.field>, ~kinds: array<Staging.kind>): array<Staging.column> =>
  fields->Array.mapWithIndex((field, index) => {
    Staging.name: field->Table.getPgDbFieldName,
    kind: kinds->Array.getUnsafe(index),
    isNullable: field.isNullable,
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
