const TableModule = require("envio/src/db/Table.res.js");
const { publicSchema } = require("./Db.res.js");

module.exports.batchDeleteItemsInTable = (table, sql, pkArray) => {
  const primaryKeyFieldNames = TableModule.getPrimaryKeyFieldNames(table);

  if (primaryKeyFieldNames.length === 1) {
    return sql`
      DELETE
      FROM ${sql(publicSchema)}.${sql(table.tableName)}
      WHERE ${sql(primaryKeyFieldNames[0])} IN ${sql(pkArray)};
      `;
  } else {
    //TODO, if needed create a delete query for multiple field matches
    //May be best to make pkArray an array of objects with fieldName -> value
  }
};

const makeHistoryTableName = (entityName) => entityName + "_history";

/**
  Find the "first change" serial originating from the reorg chain above the safe block number 
  (Using serial to account for unordered multi chain reorgs, where an earier event on another chain could be rolled back)

  If for instance there are no entity changes based on the reorg chain, the other
  chains do not need to be rolled back, and if the reorg chain has new included events, it does not matter
  that if those events are processed out of order from other chains since this is "unordered_multichain_mode"
*/
module.exports.getFirstChangeSerial_UnorderedMultichain = (
  sql,
  reorgChainId,
  safeBlockNumber,
  entityName
) =>
  sql`
    SELECT
      MIN(serial) AS first_change_serial
    FROM
      ${sql(publicSchema)}.${sql(makeHistoryTableName(entityName))}
    WHERE
      entity_history_chain_id = ${reorgChainId}
      AND entity_history_block_number > ${safeBlockNumber}
  `;

/**
  Find the "first change" serial originating from any chain above the provided safe block

  Ordered multichain mode needs to ensure that all chains rollback to any event that occurred after the reorg chain
  block number. Regardless of whether the reorg chain incurred any changes or not to entities. There could be no changes
  on the orphaned blocks, but new changes on the reorged blocks where other chains need to be processed in order after this
  fact.
*/
module.exports.getFirstChangeSerial_OrderedMultichain = (
  sql,
  safeBlockTimestamp,
  reorgChainId,
  safeBlockNumber,
  entityName
) =>
  sql`
    SELECT
      MIN(serial) AS first_change_serial
    FROM
      ${sql(publicSchema)}.${sql(makeHistoryTableName(entityName))}
    WHERE
      entity_history_block_timestamp > ${safeBlockTimestamp}
      OR
      (entity_history_block_timestamp = ${safeBlockTimestamp} AND entity_history_chain_id > ${reorgChainId})
      OR
      (entity_history_block_timestamp = ${safeBlockTimestamp} AND entity_history_chain_id = ${reorgChainId} AND entity_history_block_number > ${safeBlockNumber})
  `;

module.exports.deleteRolledBackEntityHistory = (
  sql,
  entityName,
  getFirstChangeSerial
) => sql`
  WITH
    first_change AS (
      -- Step 1: Find the "first change" serial originating from the reorg chain above the safe block number 
      -- (Using serial to account for unordered multi chain reorgs, where an earier event on another chain could be rolled back)
      ${getFirstChangeSerial(sql)}
    )
  -- Step 2: Delete all rows that have a serial >= the first change serial
  DELETE FROM
    ${sql(publicSchema)}.${sql(makeHistoryTableName(entityName))}
  WHERE
    serial >= (
      SELECT
        first_change_serial
      FROM
        first_change
    )
    -- Filter out rows with a chain_id of 0 since they are the copied history rows
    -- check timestamp as well in case a future chain is added with id of 0
    AND NOT (
      entity_history_chain_id = 0 AND
      entity_history_block_timestamp = 0
    );
  `;

module.exports.getRollbackDiff = (sql, entityName, getFirstChangeSerial) => sql`
  WITH
    first_change AS (
      -- Step 1: Find the "first change" serial originating from the reorg chain above the safe block number 
      -- (Using serial to account for unordered multi chain reorgs, where an earier event on another chain could be rolled back)
      ${getFirstChangeSerial(sql)}
    ),
    rollback_ids AS (
      -- Step 2: Get all unique entity ids of rows that require rollbacks where the row's serial is above the first change serial
      SELECT DISTINCT
        ON (id) after.*
      FROM
        ${sql(publicSchema)}.${sql(makeHistoryTableName(entityName))} after
      WHERE
        after.serial >= (
          SELECT
            first_change_serial
          FROM
            first_change
        ) 
        -- Filter out rows with a chain_id of 0 since they are the copied history rows
        -- check timestamp as well in case a future chain is added with id of 0
        AND NOT (
          after.entity_history_chain_id = 0 AND
          after.entity_history_block_timestamp = 0
        )
      ORDER BY
        after.id,
        after.serial ASC -- Select the row with the lowest serial per id
    )
  -- Step 3: For each relevant id, join to the row on the "previous_entity_history" fields
  SELECT
    -- Select all before fields, overriding the needed values with defaults
    before.*,
    -- In the case where no previous row exists, coalesce the needed values since this new entity
    -- will need to be deleted
    COALESCE(before.id, after.id) AS id,
    COALESCE(before.action, 'DELETE') AS action,
    -- Deleting at 0 values will work fine for future rollbacks
    COALESCE(before.entity_history_block_number, 0) AS entity_history_block_number,
    COALESCE(before.entity_history_block_timestamp, 0) AS entity_history_block_timestamp,
    COALESCE(before.entity_history_chain_id, 0) AS entity_history_chain_id,
    COALESCE(before.entity_history_log_index, 0) AS entity_history_log_index
  FROM
    -- Use a RIGHT JOIN, to ensure that nulls get returned if there is no "before" row
    ${sql(publicSchema)}.${sql(makeHistoryTableName(entityName))} before
    RIGHT JOIN rollback_ids after ON before.id = after.id
    AND before.entity_history_block_timestamp = after.previous_entity_history_block_timestamp
    AND before.entity_history_chain_id = after.previous_entity_history_chain_id
    AND before.entity_history_block_number = after.previous_entity_history_block_number
    AND before.entity_history_log_index = after.previous_entity_history_log_index;
`;
