open Table

module RowAction = {
  type t = SET | DELETE
  let variants = [SET, DELETE]
  let schema = S.enum(variants)
}

// Prefix with envio_ to avoid colleasions
let changeFieldName = "envio_change"
let checkpointIdFieldName = "envio_checkpoint_id"

let unsafeCheckpointIdSchema =
  S.string
  ->S.setName("CheckpointId")
  ->S.transform(s => {
    parser: string =>
      switch BigInt.fromString(string) {
      | None => s.fail("The string is not valid CheckpointId")
      | Some(v) => v
      },
    serializer: bigint => bigint->BigInt.toString,
  })

let historyTablePrefix = "envio_history_"
// `$` can't occur in a GraphQL entity name, so it marks where a truncated name
// stops and the index that keeps it unique begins. Without that boundary two
// long names whose indexes differ in digit count can truncate onto the same
// identifier, and `CREATE TABLE IF NOT EXISTS` would hand both entities one
// history table.
let historyTableName = (~entityName, ~entityIndex) =>
  fitPgTableName(historyTablePrefix ++ entityName, ~uniqueSuffix=`$${entityIndex->Int.toString}`)
