const TableModule = require("./Table.bs.js");
// db operations for raw_events:
const MAX_ITEMS_PER_QUERY = 500;

const chunkBatchQuery = async (sql, entityDataArray, queryToExecute) => {
  const responses = [];
  // Split entityDataArray into chunks of MAX_ITEMS_PER_QUERY
  for (let i = 0; i < entityDataArray.length; i += MAX_ITEMS_PER_QUERY) {
    const chunk = entityDataArray.slice(i, i + MAX_ITEMS_PER_QUERY);
    const pendingRes = queryToExecute(sql, chunk);
    responses.push(pendingRes);
  }
  return Promise.all(responses);
};

const commaSeparateDynamicMapQuery = (sql, dynQueryConstructors) =>
  sql`${dynQueryConstructors.map(
    (constrQuery, i) =>
      sql`${constrQuery(sql)}${
        i === dynQueryConstructors.length - 1 ? sql`` : sql`, `
      }`,
  )}`;

const batchSetItemsInTableCore = (table, sql, rowDataArray) => {
  const fieldNames = TableModule.getFieldNames(table).filter(
    (fieldName) => fieldName !== "db_write_timestamp",
  );
  const primaryKeyFieldNames = TableModule.getPrimaryKeyFieldNames(table);
  const fieldQueryConstructors = fieldNames.map(
    (fieldName) => (sql) => sql`${sql(fieldName)} = EXCLUDED.${sql(fieldName)}`,
  );
  const pkQueryConstructors = primaryKeyFieldNames.map(
    (pkField) => (sql) => sql(pkField),
  );

  return sql`
INSERT INTO "public".${sql(table.tableName)}
${sql(rowDataArray, ...fieldNames)}
ON CONFLICT(${sql`${commaSeparateDynamicMapQuery(
    sql,
    pkQueryConstructors,
  )}`}) DO UPDATE
SET
${sql`${commaSeparateDynamicMapQuery(sql, fieldQueryConstructors)}`};`;
};

module.exports.batchSetItemsInTable = (table, sql, rowDataArray) => {
  const queryToExecute = (sql, chunk) =>
    batchSetItemsInTableCore(table, sql, chunk);
  return chunkBatchQuery(sql, rowDataArray, queryToExecute);
};

module.exports.batchDeleteItemsInTable = (table, sql, pkArray) => {
  const primaryKeyFieldNames = TableModule.getPrimaryKeyFieldNames(table);

  if (primaryKeyFieldNames.length === 1) {
    return sql`
      DELETE
      FROM "public".${sql(table.tableName)}
      WHERE ${sql(primaryKeyFieldNames[0])} IN ${sql(pkArray)};
      `;
  } else {
    //TODO, if needed create a delete query for multiple field matches
    //May be best to make pkArray an array of objects with fieldName -> value
  }
};

module.exports.batchReadItemsInTable = (table, sql, pkArray) => {
  const primaryKeyFieldNames = TableModule.getPrimaryKeyFieldNames(table);

  if (primaryKeyFieldNames.length === 1) {
    return sql`
      SELECT *
      FROM "public".${sql(table.tableName)}
      WHERE ${sql(primaryKeyFieldNames[0])} IN ${sql(pkArray)};
      `;
  } else {
    //TODO, if needed create a select query for multiple field matches
    //May be best to make pkArray an array of objects with fieldName -> value
  }
};

module.exports.whereEqQuery = (table, sql, fieldName, value) => {
  return sql`
    SELECT *
    FROM "public".${sql(table.tableName)}
    WHERE ${sql(fieldName)} = ${value};
    `;
};

module.exports.readLatestSyncedEventOnChainId = (sql, chainId) => sql`
  SELECT *
  FROM public.event_sync_state
  WHERE chain_id = ${chainId}`;

module.exports.batchSetEventSyncState = (sql, entityDataArray) => {
  return sql`
    INSERT INTO public.event_sync_state
  ${sql(
    entityDataArray,
    "chain_id",
    "block_number",
    "log_index",
    "block_timestamp",
    "is_pre_registering_dynamic_contracts",
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
  FROM public.chain_metadata
  WHERE chain_id = ${chainId}`;

module.exports.batchSetChainMetadata = (sql, entityDataArray) => {
  return sql`
    INSERT INTO public.chain_metadata
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
    "timestamp_caught_up_to_head_or_endblock",
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

module.exports.setChainMetadataBlockHeight = (sql, entityDataArray) => {
  return sql`
    INSERT INTO public.chain_metadata
  ${sql(
    entityDataArray,
    "chain_id",
    "start_block", // this is left out of the on conflict below as it only needs to be set once
    "end_block", // this is left out of the on conflict below as it only needs to be set once
    "block_height",
  )}
  ON CONFLICT(chain_id) DO UPDATE
  SET
  "chain_id" = EXCLUDED."chain_id",
  "block_height" = EXCLUDED."block_height";`
    .then((res) => {})
    .catch((err) => {
      console.log("errored", err);
    });
};

module.exports.readLatestRawEventsBlockNumberProcessedOnChainId = (
  sql,
  chainId,
) => sql`
  SELECT block_number
  FROM "public"."raw_events"
  WHERE chain_id = ${chainId}
  ORDER BY event_id DESC
  LIMIT 1;`;

module.exports.readRawEventsEntities = (sql, entityIdArray) => sql`
  SELECT *
  FROM "public"."raw_events"
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)}`;

module.exports.getRawEventsPageGtOrEqEventId = (
  sql,
  chainId,
  eventId,
  limit,
  contractAddresses,
) => sql`
  SELECT *
  FROM "public"."raw_events"
  WHERE "chain_id" = ${chainId}
  AND "event_id" >= ${eventId}
  AND "src_address" IN ${sql(contractAddresses)}
  ORDER BY "event_id" ASC
  LIMIT ${limit}
`;

module.exports.getRawEventsPageWithinEventIdRangeInclusive = (
  sql,
  chainId,
  fromEventIdInclusive,
  toEventIdInclusive,
  limit,
  contractAddresses,
) => sql`
  SELECT *
  FROM public.raw_events
  WHERE "chain_id" = ${chainId}
  AND "event_id" >= ${fromEventIdInclusive}
  AND "event_id" <= ${toEventIdInclusive}
  AND "src_address" IN ${sql(contractAddresses)}
  ORDER BY "event_id" ASC
  LIMIT ${limit}
`;

const batchSetRawEventsCore = (sql, entityDataArray) => {
  return sql`
    INSERT INTO "public"."raw_events"
  ${sql(
    entityDataArray,
    "chain_id",
    "event_id",
    "event_name",
    "contract_name",
    "block_number",
    "log_index",
    "transaction_fields",
    "block_fields",
    "src_address",
    "block_hash",
    "block_timestamp",
    "params",
  )};`;
};

const EventUtils = require("../EventUtils.bs.js");

module.exports.batchSetRawEvents = (sql, entityDataArray) => {
  return chunkBatchQuery(sql, entityDataArray, batchSetRawEventsCore);
};

module.exports.batchDeleteRawEvents = (sql, entityIdArray) => sql`
  DELETE
  FROM "public"."raw_events"
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)};`;
// end db operations for raw_events

const batchSetEndOfBlockRangeScannedDataCore = (sql, rowDataArray) => {
  return sql`
    INSERT INTO "public"."end_of_block_range_scanned_data"
  ${sql(
    rowDataArray,
    "chain_id",
    "block_timestamp",
    "block_number",
    "block_hash",
  )}
    ON CONFLICT(chain_id, block_number) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "block_timestamp" = EXCLUDED."block_timestamp",
    "block_number" = EXCLUDED."block_number",
    "block_hash" = EXCLUDED."block_hash";`;
};

module.exports.batchSetEndOfBlockRangeScannedData = (sql, rowDataArray) => {
  return chunkBatchQuery(
    sql,
    rowDataArray,
    batchSetEndOfBlockRangeScannedDataCore,
  );
};

module.exports.readEndOfBlockRangeScannedDataForChain = (sql, chainId) => {
  return sql`
    SELECT * FROM "public"."end_of_block_range_scanned_data"
    WHERE
      chain_id = ${chainId}
      ORDER BY block_number ASC;`;
};

module.exports.deleteStaleEndOfBlockRangeScannedDataForChain = (
  sql,
  chainId,
  blockNumberThreshold,
  blockTimestampThreshold,
) => {
  return sql`
    DELETE
    FROM "public"."end_of_block_range_scanned_data"
    WHERE chain_id = ${chainId}
    AND block_number < ${blockNumberThreshold}
    AND block_timestamp < ${blockTimestampThreshold}
    ;`;
};

module.exports.readDynamicContractsOnChainIdAtOrBeforeBlockNumber = (
  sql,
  chainId,
  blockNumber,
) => sql`
  SELECT *
  FROM "public"."dynamic_contract_registry"
  WHERE registering_event_block_number <= ${blockNumber} 
  AND chain_id = ${chainId};`;

module.exports.readDynamicContractsOnChainIdMatchingEvents = (
  sql,
  chainId,
  preRegisterEvents, // array<{registering_event_contract_name, registering_event_name, registering_event_src_address}>
) => {
  return sql`
    SELECT *
    FROM "public"."dynamic_contract_registry"
    WHERE chain_id = ${chainId}
    AND (registering_event_contract_name, registering_event_name, registering_event_src_address) IN ${sql(
      preRegisterEvents.map((item) => sql(item)),
    )};
  `;
};

const makeHistoryTableName = (entityName) => entityName + "_history";

/**
  Find the "first change" serial originating from the reorg chain above the safe block number 
  (Using serial to account for unordered multi chain reorgs, where an earier event on another chain could be rolled back)
*/
module.exports.getFirstChangeSerial_UnorderedMultichain = (
  sql,
  reorgChainId,
  safeBlockNumber,
  entityName,
) =>
  sql`
    SELECT
      MIN(serial) AS first_change_serial
    FROM
      public.${sql(makeHistoryTableName(entityName))}
    WHERE
      entity_history_chain_id = ${reorgChainId}
      AND entity_history_block_number > ${safeBlockNumber}
  `;

/**
  Find the "first change" serial originating from any chain above the provided safe block
*/
module.exports.getFirstChangeSerial_OrderedMultichain = (
  sql,
  safeBlockTimestamp,
  reorgChainId,
  safeBlockNumber,
  entityName,
) =>
  sql`
    SELECT
      MIN(serial) AS first_change_serial
    FROM
      public.${sql(makeHistoryTableName(entityName))}
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
  getFirstChangeSerial,
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
    public.${sql(makeHistoryTableName(entityName))}
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
  getFirstChangeSerial,
) => sql`
  WITH
    first_change AS (
      -- Step 1: Find the "first change" serial originating from the reorg chain above the safe block number 
      -- (Using serial to account for unordered multi chain reorgs, where an earier event on another chain could be rolled back)
      ${getFirstChangeSerial(sql)}
    )
  -- Step 2: Delete all rows that have a serial >= the first change serial
  DELETE FROM
    public.${sql(makeHistoryTableName(entityName))}
  WHERE
    serial >= (
      SELECT
        first_change_serial
      FROM
        first_change
    );
  `;

const Utils = require("envio/src/Utils.bs.js");

module.exports.pruneStaleEntityHistory = (
  sql,
  entityName,
  safeChainIdAndBlockNumberArray,
) => {
  const tableName = makeHistoryTableName(entityName);
  return sql`
  WITH first_change AS (
    SELECT
      MIN(serial) AS first_change_serial
    FROM
      public.${sql(tableName)}
    WHERE
      ${Utils.$$Array.interleave(
    safeChainIdAndBlockNumberArray.map(
      ({ chainId, blockNumber }) =>
        sql`(entity_history_chain_id = ${chainId} AND entity_history_block_number > ${blockNumber})`,
    ),
    sql` OR `,
  )}
  ),
  items_in_reorg_threshold AS (
    SELECT DISTINCT
      ON (id) *
    FROM
      public.${sql(tableName)}
    WHERE
      serial >= (SELECT first_change_serial FROM first_change)
    ORDER BY
      id,
      serial ASC -- Select the row with the lowest serial per id
  ),
  -- Select all the previous history items for each id in the reorg threshold
  previous_items AS (
    SELECT
      prev.id,
      prev.serial
    FROM
      public.${sql(tableName)} prev
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
  )
  DELETE FROM
    public.${sql(tableName)} eh
  WHERE
    -- Delete all entity history of entities that are not in the reorg threshold
    eh.id NOT IN (SELECT id FROM items_in_reorg_threshold)
    -- Delete all rows where id matches a row in previous_items but has a lower serial
    OR 
    eh.serial < (SELECT serial FROM previous_items WHERE previous_items.id = eh.id);
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
        public.${sql(makeHistoryTableName(entityName))} after
      WHERE
        after.serial >= (
          SELECT
            first_change_serial
          FROM
            first_change
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
    public.${sql(makeHistoryTableName(entityName))} before
    RIGHT JOIN rollback_ids after ON before.id = after.id
    AND before.entity_history_block_timestamp = after.previous_entity_history_block_timestamp
    AND before.entity_history_chain_id = after.previous_entity_history_chain_id
    AND before.entity_history_block_number = after.previous_entity_history_block_number
    AND before.entity_history_log_index = after.previous_entity_history_log_index;
`;
