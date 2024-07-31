const TableModule = require("./Table.bs.js");
// db operations for raw_events:
const MAX_ITEMS_PER_QUERY = 500;

const chunkBatchQuery = async (sql, entityDataArray, queryToExecute) => {
  const responses = [];
  // Split entityDataArray into chunks of MAX_ITEMS_PER_QUERY
  for (let i = 0; i < entityDataArray.length; i += MAX_ITEMS_PER_QUERY) {
    const chunk = entityDataArray.slice(i, i + MAX_ITEMS_PER_QUERY);
    const response = await queryToExecute(sql, chunk);
    responses.push(response);
  }
  return responses;
};

const commaSeparateDynamicMapQuery = (sql, dynQueryConstructors) =>
  sql`${dynQueryConstructors.map(
    (constrQuery, i) =>
      sql`${constrQuery(sql)}${i === dynQueryConstructors.length - 1 ? sql`` : sql`, `
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
  )}
    ON CONFLICT(chain_id) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "block_number" = EXCLUDED."block_number",
    "log_index" = EXCLUDED."log_index",
    "block_timestamp" = EXCLUDED."block_timestamp";
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
    .then((res) => { })
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
    .then((res) => { })
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
  )}
    ON CONFLICT(chain_id, event_id) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "event_id" = EXCLUDED."event_id",
    "event_name" = EXCLUDED."event_name",
    "contract_name" = EXCLUDED."contract_name",
    "block_number" = EXCLUDED."block_number",
    "log_index" = EXCLUDED."log_index",
    "transaction_fields" = EXCLUDED."transaction_fields",
    "block_fields" = EXCLUDED."block_fields",
    "src_address" = EXCLUDED."src_address",
    "block_hash" = EXCLUDED."block_hash",
    "block_timestamp" = EXCLUDED."block_timestamp",
    "params" = EXCLUDED."params";`;
};

module.exports.batchInsertEntityHistory = async (sql, entityDataArray) => {
  for (const entity of entityDataArray) {
    // Prepare parameters, ensuring undefined values are explicitly set to null
    const {
      block_timestamp,
      chain_id,
      block_number,
      log_index,
      params,
      entity_type,
      entity_id,
      previous_block_timestamp = null,
      previous_chain_id = null,
      previous_block_number = null,
      previous_log_index = null,
    } = entity;

    // Call the PostgreSQL function for each entity
    await sql`
      SELECT insert_entity_history(
        ${block_timestamp},
        ${chain_id},
        ${block_number},
        ${log_index},
        ${params},
        ${entity_type},
        ${entity_id},
        ${previous_block_timestamp},
        ${previous_chain_id},
        ${previous_block_number},
        ${previous_log_index}
      )
    `;
  }
};

module.exports.deleteAllEntityHistoryOnChainBeforeThreshold = async (
  sql,
  chainId,
  blockNumberThreshold,
  blockTimestampThreshold,
) => {
  await sql`
  DELETE FROM "public"."entity_history"
  WHERE chain_id = ${chainId}
    AND block_timestamp < ${blockTimestampThreshold}
    AND block_number < ${blockNumberThreshold}
    AND block_number NOT IN (
        SELECT MAX(block_number)
        FROM "public"."entity_history"
        WHERE chain_id = ${chainId}
        AND block_timestamp < ${blockTimestampThreshold}
        AND block_number < ${blockNumberThreshold}
        GROUP BY chain_id
  );`;
};

module.exports.deleteAllEntityHistoryAfterEventIdentifier = async (
  sql,
  { blockTimestamp, chainId, blockNumber, logIndex },
) => {
  await sql`
  DELETE FROM "public"."entity_history"
  WHERE 
    block_timestamp > ${blockTimestamp} OR
    (block_timestamp = ${blockTimestamp} AND chain_id > ${chainId}) OR
    (block_timestamp = ${blockTimestamp} AND chain_id = ${chainId} AND block_number > ${blockNumber}) OR
    (block_timestamp = ${blockTimestamp} AND chain_id = ${chainId} AND block_number = ${blockNumber} AND log_index > ${logIndex});
`;
};

const EventUtils = require("../EventUtils.bs.js");
module.exports.deleteAllDynamicContractRegistrationsAfterEventIdentifier =
  async (sql, { blockTimestamp, chainId, blockNumber, logIndex }) => {
    const eventId = EventUtils.packEventIndexFromRecord({
      blockNumber,
      logIndex,
    });

    return await sql`
      DELETE FROM "public"."dynamic_contract_registry"
      WHERE 
        block_timestamp > ${blockTimestamp} OR
        (block_timestamp = ${blockTimestamp} AND chain_id > ${chainId}) OR
        (block_timestamp = ${blockTimestamp} AND chain_id = ${chainId} AND event_id > ${eventId});
      `;
  };

module.exports.deleteAllRawEventsAfterEventIdentifier = async (
  sql,
  { blockTimestamp, chainId, blockNumber, logIndex },
) => {
  const eventId = EventUtils.packEventIndexFromRecord({
    blockNumber,
    logIndex,
  });

  return await sql`
      DELETE FROM "public"."raw_events"
      WHERE 
        block_timestamp > ${blockTimestamp} OR
        (block_timestamp = ${blockTimestamp} AND chain_id > ${chainId}) OR
        (block_timestamp = ${blockTimestamp} AND chain_id = ${chainId} AND event_id > ${eventId});
      `;
};

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

module.exports.readDynamicContractsOnChainIdAtOrBeforeBlock = (
  sql,
  chainId,
  block_number,
) => sql`
  SELECT c.contract_address, c.contract_type, c.event_id, c.chain_id, c.block_timestamp
  FROM "public"."dynamic_contract_registry" as c
  JOIN raw_events e ON c.chain_id = e.chain_id
  AND c.event_id = e.event_id
  WHERE e.block_number <= ${block_number} AND e.chain_id = ${chainId};`;

//Start db operations dynamic_contract_registry
module.exports.readDynamicContractRegistryEntities = (
  sql,
  entityIdArray,
) => sql`
  SELECT *
  FROM "public"."dynamic_contract_registry"
  WHERE (chain_id, contract_address) IN ${sql(entityIdArray)}`;

const batchSetDynamicContractRegistryCore = (sql, entityDataArray) => {
  return sql`
    INSERT INTO "public"."dynamic_contract_registry"
  ${sql(
    entityDataArray,
    "chain_id",
    "event_id",
    "block_timestamp",
    "contract_address",
    "contract_type",
  )}
    ON CONFLICT(chain_id, contract_address) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "event_id" = EXCLUDED."event_id",
    "contract_address" = EXCLUDED."contract_address",
    "contract_type" = EXCLUDED."contract_type";`;
};

module.exports.batchSetDynamicContractRegistry = (sql, entityDataArray) => {
  return chunkBatchQuery(
    sql,
    entityDataArray,
    batchSetDynamicContractRegistryCore,
  );
};

module.exports.batchDeleteDynamicContractRegistry = (sql, entityIdArray) => sql`
  DELETE
  FROM "public"."dynamic_contract_registry"
  WHERE (chain_id, contract_address) IN ${sql(entityIdArray)};`;
// end db operations for dynamic_contract_registry

module.exports.getRollbackDiff = (
  sql,
  blockTimestamp,
  chainId,
  blockNumber,
) => sql`
SELECT DISTINCT
    ON (
      COALESCE(old.entity_id, new.entity_id)
    ) COALESCE(old.entity_id, new.entity_id) AS entity_id,
    COALESCE(old.params, NULL) AS val,
    COALESCE(old.block_timestamp, NULL) AS block_timestamp,
    COALESCE(old.chain_id, NULL) AS chain_id,
    COALESCE(old.block_number, NULL) AS block_number,
    COALESCE(old.log_index, NULL) AS log_index,
    COALESCE(old.entity_type, new.entity_type) AS entity_type

FROM entity_history old
INNER JOIN
    entity_history next
    -- next should simply be a higher block multichain
    ON (
        next.block_timestamp > ${blockTimestamp}
        OR (next.block_timestamp = ${blockTimestamp} AND next.chain_id > ${chainId})
        OR (
            next.block_timestamp = ${blockTimestamp} AND next.chain_id = ${chainId} AND next.block_number >= ${blockNumber}
        )
    )
    -- old should be a lower block multichain
    AND (
        old.block_timestamp < ${blockTimestamp}
        OR (old.block_timestamp = ${blockTimestamp} AND old.chain_id < ${chainId})
        OR (old.block_timestamp = ${blockTimestamp} AND old.chain_id = ${chainId} AND old.block_number <= ${blockNumber})
    )
    -- old AND new ids AND entity types should match
    AND old.entity_id = next.entity_id
    AND old.entity_type = next.entity_type
    AND old.block_number = next.previous_block_number
FULL OUTER JOIN
    entity_history new
    ON old.entity_id = new.entity_id
    AND new.previous_block_number >= old.block_number
WHERE COALESCE(old.block_timestamp, 0) <= ${blockTimestamp} AND COALESCE(new.block_timestamp, ${blockTimestamp} + 1) >= ${blockTimestamp};
`;
