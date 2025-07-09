const TableModule = require("envio/src/db/Table.res.js");
const Utils = require("envio/src/Utils.res.js");
const { publicSchema } = require("./Db.res.js");

// db operations for raw_events:
const MAX_ITEMS_PER_QUERY = 500;

const chunkBatchQuery = (queryToExecute) => async (sql, entityDataArray) => {
  const responses = [];
  // Split entityDataArray into chunks of MAX_ITEMS_PER_QUERY
  for (let i = 0; i < entityDataArray.length; i += MAX_ITEMS_PER_QUERY) {
    const chunk = entityDataArray.slice(i, i + MAX_ITEMS_PER_QUERY);
    const pendingRes = queryToExecute(sql, chunk);
    responses.push(pendingRes);
  }
  return Promise.all(responses);
};

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

module.exports.readLatestSyncedEventOnChainId = (sql, chainId) => sql`
  SELECT *
  FROM ${sql(publicSchema)}.event_sync_state
  WHERE chain_id = ${chainId}`;

module.exports.batchSetEventSyncState = (sql, entityDataArray) => {
  return sql`
    INSERT INTO ${sql(publicSchema)}.event_sync_state
  ${sql(
    entityDataArray,
    "chain_id",
    "block_number",
    "log_index",
    "block_timestamp",
    "is_pre_registering_dynamic_contracts"
  )}
    ON CONFLICT(chain_id) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "block_number" = EXCLUDED."block_number",
    "log_index" = EXCLUDED."log_index",
    "block_timestamp" = EXCLUDED."block_timestamp",
    "is_pre_registering_dynamic_contracts" = EXCLUDED."is_pre_registering_dynamic_contracts";
    `;
};

module.exports.readLatestChainMetadataState = (sql, chainId) => sql`
  SELECT *
  FROM ${sql(publicSchema)}.chain_metadata
  WHERE chain_id = ${chainId}`;

module.exports.batchSetChainMetadata = (sql, entityDataArray) => {
  return sql`
    INSERT INTO ${sql(publicSchema)}.chain_metadata
  ${sql(
    entityDataArray,
    "chain_id",
    "start_block", // this is left out of the on conflict below as it only needs to be set once
    "end_block", // this is left out of the on conflict below as it only needs to be set once
    "block_height",
    "first_event_block_number",
    "latest_processed_block",
    "num_events_processed",
    "is_hyper_sync", // this is left out of the on conflict below as it only needs to be set once
    "num_batches_fetched",
    "latest_fetched_block_number",
    "timestamp_caught_up_to_head_or_endblock"
  )}
  ON CONFLICT(chain_id) DO UPDATE
  SET
  "chain_id" = EXCLUDED."chain_id",
  "first_event_block_number" = EXCLUDED."first_event_block_number",
  "latest_processed_block" = EXCLUDED."latest_processed_block",
  "num_events_processed" = EXCLUDED."num_events_processed",
  "num_batches_fetched" = EXCLUDED."num_batches_fetched",
  "latest_fetched_block_number" = EXCLUDED."latest_fetched_block_number",
  "timestamp_caught_up_to_head_or_endblock" = EXCLUDED."timestamp_caught_up_to_head_or_endblock",
  "block_height" = EXCLUDED."block_height";`
    .then((res) => {})
    .catch((err) => {
      console.log("errored", err);
    });
};

module.exports.batchDeleteRawEvents = (sql, entityIdArray) => sql`
  DELETE
  FROM ${sql(publicSchema)}."raw_events"
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)};`;
// end db operations for raw_events

const batchSetEndOfBlockRangeScannedDataCore = (sql, rowDataArray) => {
  return sql`
    INSERT INTO ${sql(publicSchema)}."end_of_block_range_scanned_data"
  ${sql(rowDataArray, "chain_id", "block_number", "block_hash")}
    ON CONFLICT(chain_id, block_number) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "block_number" = EXCLUDED."block_number",
    "block_hash" = EXCLUDED."block_hash";`;
};

module.exports.batchSetEndOfBlockRangeScannedData = chunkBatchQuery(
  batchSetEndOfBlockRangeScannedDataCore
);

module.exports.readEndOfBlockRangeScannedDataForChain = (sql, chainId) => {
  return sql`
    SELECT * FROM ${sql(publicSchema)}."end_of_block_range_scanned_data"
    WHERE
      chain_id = ${chainId}
      ORDER BY block_number ASC;`;
};

module.exports.deleteStaleEndOfBlockRangeScannedDataForChain = (
  sql,
  chainId,
  blockNumberThreshold
) => {
  return sql`
    DELETE
    FROM ${sql(publicSchema)}."end_of_block_range_scanned_data"
    WHERE chain_id = ${chainId}
    AND block_number < ${blockNumberThreshold};`;
};

module.exports.rollbackEndOfBlockRangeScannedDataForChain = (
  sql,
  chainId,
  knownBlockNumber
) => {
  return sql`
    DELETE
    FROM ${sql(publicSchema)}."end_of_block_range_scanned_data"
    WHERE chain_id = ${chainId}
    AND block_number > ${knownBlockNumber};`;
};

module.exports.deleteInvalidDynamicContractsOnRestart = (
  sql,
  chainId,
  restartBlockNumber,
  restartLogIndex
) => {
  return sql`
    DELETE
    FROM ${sql(publicSchema)}."dynamic_contract_registry"
    WHERE chain_id = ${chainId}
    AND (
      registering_event_block_number > ${restartBlockNumber} 
      OR registering_event_block_number = ${restartBlockNumber}
      AND registering_event_log_index > ${restartLogIndex}
    );`;
};

module.exports.deleteInvalidDynamicContractsHistoryOnRestart = (
  sql,
  chainId,
  restartBlockNumber,
  restartLogIndex
) => {
  return sql`
    DELETE
    FROM ${sql(publicSchema)}."dynamic_contract_registry_history"
    WHERE entity_history_chain_id = ${chainId}
    AND (
      entity_history_block_number > ${restartBlockNumber} 
      OR entity_history_block_number = ${restartBlockNumber}
      AND entity_history_log_index > ${restartLogIndex}
    );`;
};

module.exports.readAllDynamicContracts = (sql, chainId) => sql`
  SELECT *
  FROM ${sql(publicSchema)}."dynamic_contract_registry"
  WHERE chain_id = ${chainId};`;

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

module.exports.getFirstChangeEntityHistoryPerChain = (
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
  -- Step 2: Distinct on entity_history_chain_id, get the entity_history_block_number of the row with the 
  -- lowest serial >= the first change serial
  SELECT DISTINCT
    ON (entity_history_chain_id) *
  FROM
    ${sql(publicSchema)}.${sql(makeHistoryTableName(entityName))}
  WHERE
    serial >= (
      SELECT
        first_change_serial
      FROM
        first_change
    )
  ORDER BY
    entity_history_chain_id,
    serial
    ASC; -- Select the row with the lowest serial per id
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

module.exports.pruneStaleEntityHistory = (
  sql,
  entityName,
  safeChainIdAndBlockNumberArray,
  // shouldDeepCleanHistory is a boolean that determines whether to delete stale history
  // items of entities that are in the reorg threshold (expensive to calculate)
  // or to do a shallow clean (only deletes history items of entities that are not in the reorg threshold)
  shouldDeepClean
) => {
  const tableName = makeHistoryTableName(entityName);
  return sql`
  WITH first_change AS (
    SELECT
      MIN(serial) AS first_change_serial
    FROM
      ${sql(publicSchema)}.${sql(tableName)}
    WHERE
      ${Utils.$$Array.interleave(
        safeChainIdAndBlockNumberArray.map(
          ({ chainId, blockNumber }) =>
            sql`(entity_history_chain_id = ${chainId} AND entity_history_block_number > ${blockNumber})`
        ),
        sql` OR `
      )}
  ),
  items_in_reorg_threshold AS (
    SELECT DISTINCT
      ON (id) *
    FROM
      ${sql(publicSchema)}.${sql(tableName)}
    WHERE
      serial >= (SELECT first_change_serial FROM first_change)
      -- Filter out rows with a chain_id of 0 since they are the copied history rows
      -- check timestamp as well in case a future chain is added with id of 0
      AND NOT (
        entity_history_chain_id = 0 AND
        entity_history_block_timestamp = 0
      )
    ORDER BY
      id,
      serial ASC -- Select the row with the lowest serial per id
  )${
    shouldDeepClean
      ? sql`
  -- Select all the previous history items for each id in the reorg threshold
  ,previous_items AS (
    SELECT
      prev.id,
      prev.serial
    FROM
      ${sql(publicSchema)}.${sql(tableName)} prev
    INNER JOIN
      items_in_reorg_threshold r
    ON
      r.id = prev.id
      AND
      r.previous_entity_history_chain_id = prev.entity_history_chain_id
      AND
      r.previous_entity_history_block_number = prev.entity_history_block_number
      AND
      r.previous_entity_history_log_index = prev.entity_history_log_index
  )`
      : sql``
  }
  DELETE FROM
    ${sql(publicSchema)}.${sql(tableName)} eh
  WHERE
    -- Delete all entity history of entities that are not in the reorg threshold
    eh.id NOT IN (SELECT id FROM items_in_reorg_threshold)
  ${
    shouldDeepClean
      ? sql`
    -- Delete all rows where id matches a row in previous_items but has a lower serial
    OR 
    eh.serial < (SELECT serial FROM previous_items WHERE previous_items.id = eh.id)`
      : sql``
  }
`;
};

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
