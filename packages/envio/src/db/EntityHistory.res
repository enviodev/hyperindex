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

let makeSetUpdateSchema = (~idSchema: S.t<EntityId.t>, entitySchema: S.t<'entity>): S.t<
  Change.t<'entity>,
> => {
  S.object(s => {
    s.tag(changeFieldName, RowAction.SET)
    Change.Set({
      checkpointId: s.field(checkpointIdFieldName, unsafeCheckpointIdSchema),
      entityId: s.field(Table.idFieldName, idSchema),
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
  chainIds: array<ChainId.t>,
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
// A per-chain entity's rows are only comparable within a chain, so every id
// correlation in the history SQL widens to (id, chain id).
let makeKeyColumns = (~chainIdColumn: option<string>) =>
  switch chainIdColumn {
  | Some(column) => ["id", `"${column}"`]
  | None => ["id"]
  }

let makeKeyMatch = (~chainIdColumn, ~left, ~right) =>
  makeKeyColumns(~chainIdColumn)
  ->Array.map(column => `${left}.${column} = ${right}.${column}`)
  ->Array.joinUnsafe(" AND ")

let makePruneStaleEntityHistoryQuery = (~entityName, ~entityIndex, ~pgSchema, ~chainIdColumn) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`
  let keyColumns = makeKeyColumns(~chainIdColumn)
  let anchorKeys = keyColumns->Array.map(column => `t.${column}`)->Array.joinUnsafe(", ")

  // Whether a key still has a row above the safe checkpoint is an aggregate
  // over the same groups as the anchor, so it's computed in the one pass
  // rather than as a per-row correlated lookup.
  // `d.envio_checkpoint_id <= $1` is implied by the rest of the predicate — it
  // is there to keep the rows above the safe checkpoint out of the join.
  `WITH anchors AS (
  SELECT ${anchorKeys},
    MAX(t.${checkpointIdFieldName}) FILTER (WHERE t.${checkpointIdFieldName} <= $1) AS keep_checkpoint_id,
    bool_or(t.${checkpointIdFieldName} > $1) AS has_above
  FROM ${historyTableRef} t
  GROUP BY ${anchorKeys}
)
DELETE FROM ${historyTableRef} d
USING anchors a
WHERE ${makeKeyMatch(~chainIdColumn, ~left="d", ~right="a")}
  AND d.${checkpointIdFieldName} <= $1
  AND (d.${checkpointIdFieldName} < a.keep_checkpoint_id OR NOT a.has_above);`
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
// we create it automatically with envio_checkpoint_id 0
// The ids belong to a single chain (the flush group's scope), so the chain is
// bound once as $2 rather than unnested alongside them.
let makeBackfillHistoryQuery = (
  ~pgSchema,
  ~entityName,
  ~entityIndex,
  ~idPgType,
  ~chainIdColumn,
  ~chainId: option<ChainId.t>,
) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`
  let chainFilter = switch (chainIdColumn, chainId) {
  | (Some(column), Some(_)) => ` AND e."${column}" = $2`
  | _ => ""
  }
  `WITH target_ids AS (
  SELECT UNNEST($1::${idPgType}[]) AS id
),
missing_history AS (
  SELECT e.*
  FROM "${pgSchema}"."${entityName}" e
  JOIN target_ids t ON e.id = t.id${chainFilter}
  LEFT JOIN ${historyTableRef} h ON ${makeKeyMatch(~chainIdColumn, ~left="h", ~right="e")}
  WHERE h.id IS NULL
)
INSERT INTO ${historyTableRef}
SELECT *, 0 AS ${checkpointIdFieldName}, '${(RowAction.SET :> string)}' as ${changeFieldName}
FROM missing_history;`
}

let backfillHistory = (
  sql,
  ~pgSchema,
  ~table: Table.table,
  ~entityIndex,
  ~chainId: option<ChainId.t>,
  ~ids: array<EntityId.t>,
) => {
  let idPgType = table->Table.getIdPgFieldType(~pgSchema)
  let chainIdColumn = table->Table.getChainIdField->Option.map(Table.getPgDbFieldName)
  let params = [table->Table.encodeIdsToJson(ids)->(Utils.magic: JSON.t => unknown)]
  switch (chainIdColumn, chainId) {
  | (Some(_), Some(chainId)) =>
    params->Array.push(chainId->(Utils.magic: ChainId.t => unknown))->ignore
  | _ => ()
  }
  sql
  ->Postgres.preparedUnsafe(
    makeBackfillHistoryQuery(
      ~entityName=table.tableName,
      ~entityIndex,
      ~pgSchema,
      ~idPgType,
      ~chainIdColumn,
      ~chainId,
    ),
    params->Obj.magic,
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
