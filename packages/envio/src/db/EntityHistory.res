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
let checkpointIdFieldType = UInt64
let changeFieldType = Enum({config: RowAction.config->Table.fromGenericEnumConfig})

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
    let entityIndexStr = entityIndex->Int.toString
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
let makePruneStaleEntityHistoryQuery = (~entityName, ~entityIndex, ~pgSchema, ~chainIdColumn) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`

  // Per-chain entities key history by (id, chain_id), so the anchor and every
  // join must be chain-scoped — otherwise one chain's anchor would mask another
  // chain's still-relevant history for the same id.
  let (keyCols, joinCond, psScope) = switch chainIdColumn {
  | Some(col) => (
      `t.id, t.${col}`,
      `d.id = a.id AND d.${col} = a.${col}`,
      `ps.id = d.id AND ps.${col} = d.${col}`,
    )
  | None => (`t.id`, `d.id = a.id`, `ps.id = d.id`)
  }

  `WITH anchors AS (
  SELECT ${keyCols}, MAX(t.${checkpointIdFieldName}) AS keep_checkpoint_id
  FROM ${historyTableRef} t WHERE t.${checkpointIdFieldName} <= $1
  GROUP BY ${keyCols}
)
DELETE FROM ${historyTableRef} d
USING anchors a
WHERE ${joinCond}
  AND (
    d.${checkpointIdFieldName} < a.keep_checkpoint_id
    OR (
      d.${checkpointIdFieldName} = a.keep_checkpoint_id AND
      NOT EXISTS (
        SELECT 1 FROM ${historyTableRef} ps
        WHERE ${psScope} AND ps.${checkpointIdFieldName} > $1
      )
    )
  );`
}

let pruneStaleEntityHistory = (
  sql,
  ~entityName,
  ~entityIndex,
  ~pgSchema,
  ~chainIdColumn,
  ~safeCheckpointId,
): promise<unit> => {
  sql->Postgres.preparedUnsafe(
    makePruneStaleEntityHistoryQuery(~entityName, ~entityIndex, ~pgSchema, ~chainIdColumn),
    [safeCheckpointId->BigInt.toString]->(Utils.magic: array<string> => unknown),
  )
}

// If an entity doesn't have a history before the update
// we create it automatically with envio_checkpoint_id 0.
// For per-chain entities the entity table holds one row per (id, chain_id), so
// the "missing history" check is scoped by chain too — otherwise one chain's
// baseline would mask another's, and the checkpoint-0 rows would collide.
let makeBackfillHistoryQuery = (~pgSchema, ~entityName, ~entityIndex, ~chainIdColumn) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`
  let historyJoin = switch chainIdColumn {
  | Some(column) => `h.id = e.id AND h."${column}" = e."${column}"`
  | None => `h.id = e.id`
  }
  `WITH target_ids AS (
  SELECT UNNEST($1::${(Text: Postgres.columnType :> string)}[]) AS id
),
missing_history AS (
  SELECT e.*
  FROM "${pgSchema}"."${entityName}" e
  JOIN target_ids t ON e.id = t.id
  LEFT JOIN ${historyTableRef} h ON ${historyJoin}
  WHERE h.id IS NULL
)
INSERT INTO ${historyTableRef}
SELECT *, 0 AS ${checkpointIdFieldName}, '${(RowAction.SET :> string)}' as ${changeFieldName}
FROM missing_history;`
}

let backfillHistory = (
  sql,
  ~pgSchema,
  ~entityName,
  ~entityIndex,
  ~chainIdColumn,
  ~ids: array<string>,
) => {
  sql
  ->Postgres.preparedUnsafe(
    makeBackfillHistoryQuery(~entityName, ~entityIndex, ~pgSchema, ~chainIdColumn),
    [ids]->Obj.magic,
  )
  ->Utils.Promise.ignoreValue
}

let rollback = (
  sql,
  ~pgSchema,
  ~entityName,
  ~entityIndex,
  ~rollbackTargetCheckpointId: Internal.checkpointId,
) => {
  sql
  ->Postgres.preparedUnsafe(
    `DELETE FROM "${pgSchema}"."${historyTableName(
        ~entityName,
        ~entityIndex,
      )}" WHERE "${checkpointIdFieldName}" > $1;`,
    [rollbackTargetCheckpointId->BigInt.toString]->(Utils.magic: array<string> => unknown),
  )
  ->Utils.Promise.ignoreValue
}
