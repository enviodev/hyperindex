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

// `chainIdTag` carries the (column, chain id) of a per-chain entity whose rows
// all belong to one chain: the column is then a constant of the schema rather
// than a field read off every entity.
let makeSetUpdateSchema = (
  ~idSchema: S.t<EntityId.t>,
  ~chainIdTag: option<(string, ChainId.t)>=?,
  entitySchema: S.t<'entity>,
): S.t<Change.t<'entity>> => {
  S.object(s => {
    s.tag(changeFieldName, RowAction.SET)
    switch chainIdTag {
    | Some((column, chainId)) => s.tag(column, chainId)
    | None => ()
    }
    Change.Set({
      checkpointId: s.field(checkpointIdFieldName, unsafeCheckpointIdSchema),
      entityId: s.field(Table.idFieldName, idSchema),
      entity: s.flatten(entitySchema),
    })
  })
}

let historyTablePrefix = "envio_history_"
// `$` can't occur in a GraphQL entity name, so it marks where a truncated name
// stops and the index that keeps it unique begins. Without that boundary two
// long names whose indexes differ in digit count can truncate onto the same
// identifier, and `CREATE TABLE IF NOT EXISTS` would hand both entities one
// history table.
let historyTableName = (~entityName, ~entityIndex) =>
  fitPgTableName(historyTablePrefix ++ entityName, ~uniqueSuffix=`$${entityIndex->Int.toString}`)
