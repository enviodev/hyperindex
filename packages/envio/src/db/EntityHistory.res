open Table

module RowAction = {
  type t = SET | DELETE
  let variants = [SET, DELETE]
  let name = "ENVIO_HISTORY_CHANGE"
  let schema = S.enum(variants)
  let config: Table.enumConfig<t> = {
    name,
    variants,
    schema,
  }
}

// Prefix with envio_ to avoid colleasions
let changeFieldName = "envio_change"
let checkpointIdFieldName = "envio_checkpoint_id"
let checkpointIdFieldType = Uint32
let changeFieldType = Enum({config: RowAction.config->Table.fromGenericEnumConfig})

let unsafeCheckpointIdSchema =
  S.string
  ->S.setName("CheckpointId")
  ->S.transform(s => {
    parser: string =>
      switch string->Belt.Float.fromString {
      | Some(float) => float
      | None => s.fail("The string is not valid CheckpointId")
      },
    serializer: float => float->Belt.Float.toString,
  })

let makeSetUpdateSchema: S.t<'entity> => S.t<Change.t<'entity>> = entitySchema => {
  S.object(s => {
    s.tag(changeFieldName, RowAction.SET)
    Change.Set({
      checkpointId: s.field(checkpointIdFieldName, unsafeCheckpointIdSchema),
      entityId: s.field(Table.idFieldName, S.string),
      entity: s.flatten(entitySchema),
    })
  })
}

type pgEntityHistory<'entity> = {
  table: Table.table,
  setChangeSchema: S.t<Change.t<'entity>>,
  // Used for parsing
  setChangeSchemaRows: S.t<array<Change.t<'entity>>>,
}

let maxPgTableNameLength = 63
let historyTablePrefix = "envio_history_"
let historyTableName = (~entityName, ~entityIndex) => {
  let fullName = historyTablePrefix ++ entityName
  if fullName->String.length > maxPgTableNameLength {
    let entityIndexStr = entityIndex->Belt.Int.toString
    fullName->Js.String.slice(~from=0, ~to_=maxPgTableNameLength - entityIndexStr->String.length) ++
      entityIndexStr
  } else {
    fullName
  }
}

type safeReorgBlocks = {
  chainIds: array<int>,
  blockNumbers: array<int>,
}

// We want to keep only the minimum history needed to survive chain reorgs and delete everything older.
// Each chain gives us a "safe block": we assume reorgs will never happen at that block.
// The latest checkpoint belonging to safe blocks of all chains is the safe checkpoint id.
//
// What we keep per entity id:
// - If there are history rows in reorg threshold (after the safe block), we keep the anchor and delete all older rows.
// - If there are no history rows in reorg threshold (after the safe block), even the anchor is redundant, so we delete it too.
// Anchor is the latest history row at or before the safe checkpoint id.
// This is the last state that could ever be relevant during a rollback.
//
// Why this is safe:
// - Rollbacks will not cross the safe checkpoint id, so rows older than the anchor can never be referenced again.
// - If nothing changed in reorg threshold (after the safe checkpoint), the current state for that id can be reconstructed from the
//   origin table; we do not need a pre-safe anchor for it.
let makePruneStaleEntityHistoryQuery = (~entityName, ~entityIndex, ~pgSchema) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`

  `WITH anchors AS (
  SELECT t.id, MAX(t.${checkpointIdFieldName}) AS keep_checkpoint_id
  FROM ${historyTableRef} t WHERE t.${checkpointIdFieldName} <= $1
  GROUP BY t.id
)
DELETE FROM ${historyTableRef} d
USING anchors a
WHERE d.id = a.id
  AND (
    d.${checkpointIdFieldName} < a.keep_checkpoint_id
    OR (
      d.${checkpointIdFieldName} = a.keep_checkpoint_id AND
      NOT EXISTS (
        SELECT 1 FROM ${historyTableRef} ps 
        WHERE ps.id = d.id AND ps.${checkpointIdFieldName} > $1
      ) 
    )
  );`
}

let pruneStaleEntityHistory = (
  sql,
  ~entityName,
  ~entityIndex,
  ~pgSchema,
  ~safeCheckpointId,
): promise<unit> => {
  sql->Postgres.preparedUnsafe(
    makePruneStaleEntityHistoryQuery(~entityName, ~entityIndex, ~pgSchema),
    [safeCheckpointId]->Utils.magic,
  )
}

// If an entity doesn't have a history before the update
// we create it automatically with envio_checkpoint_id 0
let makeBackfillHistoryQuery = (~pgSchema, ~entityName, ~entityIndex) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`
  `WITH target_ids AS (
  SELECT UNNEST($1::${(Text: Postgres.columnType :> string)}[]) AS id
),
missing_history AS (
  SELECT e.*
  FROM "${pgSchema}"."${entityName}" e
  JOIN target_ids t ON e.id = t.id
  LEFT JOIN ${historyTableRef} h ON h.id = e.id
  WHERE h.id IS NULL
)
INSERT INTO ${historyTableRef}
SELECT *, 0 AS ${checkpointIdFieldName}, '${(RowAction.SET :> string)}' as ${changeFieldName}
FROM missing_history;`
}

let backfillHistory = (sql, ~pgSchema, ~entityName, ~entityIndex, ~ids: array<string>) => {
  sql
  ->Postgres.preparedUnsafe(
    makeBackfillHistoryQuery(~entityName, ~entityIndex, ~pgSchema),
    [ids]->Obj.magic,
  )
  ->Promise.ignoreValue
}

let rollback = (sql, ~pgSchema, ~entityName, ~entityIndex, ~rollbackTargetCheckpointId: float) => {
  sql
  ->Postgres.preparedUnsafe(
    `DELETE FROM "${pgSchema}"."${historyTableName(
        ~entityName,
        ~entityIndex,
      )}" WHERE "${checkpointIdFieldName}" > $1;`,
    [rollbackTargetCheckpointId]->Utils.magic,
  )
  ->Promise.ignoreValue
}
