open Table

module RowAction = {
  type t = SET | DELETE
  let variants = [SET, DELETE]
  let name = "ENVIO_HISTORY_CHANGE"
  let schema = S.enum(variants)
}

type entityUpdateAction<'entityType> =
  | Set('entityType)
  | Delete

type entityUpdate<'entityType> = {
  entityId: string,
  entityUpdateAction: entityUpdateAction<'entityType>,
  checkpointId: int,
}

// Prefix with envio_ to avoid colleasions
let changeFieldName = "envio_change"
let checkpointIdFieldName = "checkpoint_id"

let makeSetUpdateSchema: S.t<'entity> => S.t<entityUpdate<'entity>> = entitySchema => {
  S.object(s => {
    s.tag(changeFieldName, RowAction.SET)
    {
      checkpointId: s.field(checkpointIdFieldName, S.int),
      entityId: s.field("id", S.string),
      entityUpdateAction: Set(s.flatten(entitySchema)),
    }
  })
}

type t<'entity> = {
  table: table,
  setUpdateSchema: S.t<entityUpdate<'entity>>,
  // Used for parsing
  setUpdateSchemaRows: S.t<array<entityUpdate<'entity>>>,
  makeInsertDeleteUpdatesQuery: (~pgSchema: string) => string,
  makeGetRollbackRemovedIdsQuery: (~pgSchema: string) => string,
  makeGetRollbackRestoredEntitiesQuery: (~pgSchema: string) => string,
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

let fromTable = (table: table, ~schema: S.t<'entity>, ~entityIndex): t<'entity> => {
  let id = "id"

  let dataFields = table.fields->Belt.Array.keepMap(field =>
    switch field {
    | Field(field) =>
      switch field.fieldName {
      //id is not nullable and should be part of the pk
      | "id" => {...field, fieldName: id, isPrimaryKey: true}->Field->Some
      | _ =>
        {
          ...field,
          isNullable: true, //All entity fields are nullable in the case
          isIndex: false, //No need to index any additional entity data fields in entity history
        }
        ->Field
        ->Some
      }

    | DerivedFrom(_) => None
    }
  )

  let actionField = mkField(changeFieldName, Custom(RowAction.name), ~fieldSchema=S.never)

  let checkpointIdField = mkField(
    checkpointIdFieldName,
    Integer,
    ~fieldSchema=S.int,
    ~isPrimaryKey=true,
  )

  let entityTableName = table.tableName
  let historyTableName = historyTableName(~entityName=entityTableName, ~entityIndex)
  //ignore composite indices
  let table = mkTable(
    historyTableName,
    ~fields=dataFields->Belt.Array.concat([checkpointIdField, actionField]),
  )

  let setUpdateSchema = makeSetUpdateSchema(schema)

  let makeInsertDeleteUpdatesQuery = {
    // Get all field names for the INSERT statement
    let allFieldNames = table.fields->Belt.Array.map(field => field->getFieldName)
    let allFieldNamesStr =
      allFieldNames->Belt.Array.map(name => `"${name}"`)->Js.Array2.joinWith(", ")

    // Build the SELECT part: id from unnest, checkpoint_id from unnest, 'DELETE' for action, NULL for all other fields
    let selectParts = allFieldNames->Belt.Array.map(fieldName => {
      switch fieldName {
      | "id" => "u.id"
      | field if field == checkpointIdFieldName => "u.checkpoint_id"
      | field if field == changeFieldName => "'DELETE'"
      | _ => "NULL"
      }
    })
    let selectPartsStr = selectParts->Js.Array2.joinWith(", ")
    (~pgSchema) => {
      `INSERT INTO "${pgSchema}"."${historyTableName}" (${allFieldNamesStr})
SELECT ${selectPartsStr}
FROM UNNEST($1::text[], $2::int[]) AS u(id, checkpoint_id)`
    }
  }

  // Get data field names for rollback queries (exclude changeFieldName and checkpointIdFieldName)
  let dataFieldNames =
    table.fields
    ->Belt.Array.map(field => field->getFieldName)
    ->Belt.Array.keep(fieldName =>
      fieldName != changeFieldName && fieldName != checkpointIdFieldName
    )
  let dataFieldsCommaSeparated =
    dataFieldNames->Belt.Array.map(name => `"${name}"`)->Js.Array2.joinWith(", ")

  // Returns entity IDs that were created after the rollback target and have no history before it.
  // These entities should be deleted during rollback.
  let makeGetRollbackRemovedIdsQuery = (~pgSchema) => {
    `SELECT DISTINCT id
FROM "${pgSchema}"."${historyTableName}"
WHERE "${checkpointIdFieldName}" > $1
  AND NOT EXISTS (
    SELECT 1
    FROM "${pgSchema}"."${historyTableName}" h
    WHERE h.id = "${historyTableName}".id
      AND h."${checkpointIdFieldName}" <= $1
  )`
  }

  // Returns the most recent entity state for IDs that need to be restored during rollback.
  // For each ID modified after the rollback target, retrieves its latest state at or before the target.
  let makeGetRollbackRestoredEntitiesQuery = (~pgSchema) => {
    `SELECT DISTINCT ON (id) ${dataFieldsCommaSeparated}
FROM "${pgSchema}"."${historyTableName}"
WHERE "${checkpointIdFieldName}" <= $1
  AND EXISTS (
    SELECT 1
    FROM "${pgSchema}"."${historyTableName}" h
    WHERE h.id = "${historyTableName}".id
      AND h."${checkpointIdFieldName}" > $1
  )
ORDER BY id, "${checkpointIdFieldName}" DESC`
  }

  {
    table,
    setUpdateSchema,
    setUpdateSchemaRows: S.array(setUpdateSchema),
    makeInsertDeleteUpdatesQuery,
    makeGetRollbackRemovedIdsQuery,
    makeGetRollbackRestoredEntitiesQuery,
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
// we create it automatically with checkpoint_id 0
let makeBackfillHistoryQuery = (~pgSchema, ~entityName, ~entityIndex) => {
  let historyTableRef = `"${pgSchema}"."${historyTableName(~entityName, ~entityIndex)}"`
  `WITH target_ids AS (
  SELECT UNNEST($1::${(Text: Table.fieldType :> string)}[]) AS id
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

let insertDeleteUpdates = (
  sql,
  ~pgSchema,
  ~entityHistory,
  ~batchDeleteEntityIds,
  ~batchDeleteCheckpointIds,
) => {
  sql
  ->Postgres.preparedUnsafe(
    entityHistory.makeInsertDeleteUpdatesQuery(~pgSchema),
    (batchDeleteEntityIds, batchDeleteCheckpointIds)->Obj.magic,
  )
  ->Promise.ignoreValue
}

let rollback = (sql, ~pgSchema, ~entityName, ~entityIndex, ~rollbackTargetCheckpointId: int) => {
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
