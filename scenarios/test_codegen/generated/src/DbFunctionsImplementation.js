// db operations for raw_events:

module.exports.readLatestRawEventsBlockNumberProcessedOnChainId = (
  sql,
  chainId
) => sql`
  SELECT block_number
  FROM public.raw_events
  WHERE chain_id = ${chainId}
  ORDER BY event_id DESC
  LIMIT 1;`;

module.exports.readRawEventsEntities = (sql, entityIdArray) => sql`
  SELECT *
  FROM public.raw_events
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)}`;

const batchSetRawEventsCore = (sql, entityDataArray) => {
  return sql`
    INSERT INTO public.raw_events
  ${sql(
    entityDataArray,
    "chain_id",
    "event_id",
    "block_number",
    "log_index",
    "transaction_index",
    "transaction_hash",
    "src_address",
    "block_hash",
    "block_timestamp",
    "event_type",
    "params"
  )}
    ON CONFLICT(chain_id, event_id) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "event_id" = EXCLUDED."event_id",
    "block_number" = EXCLUDED."block_number",
    "log_index" = EXCLUDED."log_index",
    "transaction_index" = EXCLUDED."transaction_index",
    "transaction_hash" = EXCLUDED."transaction_hash",
    "src_address" = EXCLUDED."src_address",
    "block_hash" = EXCLUDED."block_hash",
    "block_timestamp" = EXCLUDED."block_timestamp",
    "event_type" = EXCLUDED."event_type",
    "params" = EXCLUDED."params";`;
};

const chunkBatchQuery = (
  sql,
  entityDataArray,
  maxItemsPerQuery,
  queryToExecute
) => {
  const promises = [];

  // Split entityDataArray into chunks of maxItemsPerQuery
  for (let i = 0; i < entityDataArray.length; i += maxItemsPerQuery) {
    const chunk = entityDataArray.slice(i, i + maxItemsPerQuery);

    promises.push(queryToExecute(sql, chunk));
  }

  // Execute all promises
  return Promise.all(promises);
};

module.exports.batchSetRawEvents = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal
  const MAX_ITEMS_PER_QUERY_RawEvents = 50;

  return chunkBatchQuery(
    sql,
    entityDataArray,
    MAX_ITEMS_PER_QUERY_RawEvents,
    batchSetRawEventsCore
  );
};

module.exports.batchDeleteRawEvents = (sql, entityIdArray) => sql`
  DELETE
  FROM public.raw_events
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)};`;
// end db operations for raw_events

module.exports.readDynamicContractsOnChainIdAtOrBeforeBlock = (
  sql,
  chainId,
  block_number
) => sql`
  SELECT contract_address, contract_type
  FROM public.dynamic_contract_registry as c
  JOIN raw_events e ON c.chain_id = e.chain_id
  AND c.event_id = e.event_id
  WHERE e.block_number <= ${block_number} AND e.chain_id = ${chainId};`;

//Start db operations dynamic_contract_registry
module.exports.readDynamicContractRegistryEntities = (
  sql,
  entityIdArray
) => sql`
  SELECT *
  FROM public.dynamic_contract_registry
  WHERE (chain_id, contract_address) IN ${sql(entityIdArray)}`;

const batchSetDynamicContractRegistryCore = (sql, entityDataArray) => {
  return sql`
    INSERT INTO public.dynamic_contract_registry
  ${sql(
    entityDataArray,
    "chain_id",
    "event_id",
    "contract_address",
    "contract_type"
  )}
    ON CONFLICT(chain_id, contract_address) DO UPDATE
    SET
    "chain_id" = EXCLUDED."chain_id",
    "event_id" = EXCLUDED."event_id",
    "contract_address" = EXCLUDED."contract_address",
    "contract_type" = EXCLUDED."contract_type";`;
};

module.exports.batchSetDynamicContractRegistry = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal
  const MAX_ITEMS_PER_QUERY_DynamicContractRegistry = 50;

  return chunkBatchQuery(
    sql,
    entityDataArray,
    MAX_ITEMS_PER_QUERY_DynamicContractRegistry,
    batchSetDynamicContractRegistryCore
  );
};

module.exports.batchDeleteDynamicContractRegistry = (sql, entityIdArray) => sql`
  DELETE
  FROM public.dynamic_contract_registry
  WHERE (chain_id, contract_address) IN ${sql(entityIdArray)};`;
// end db operations for dynamic_contract_registry

//////////////////////////////////////////////
// DB operations for User:
//////////////////////////////////////////////

module.exports.readUserEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"address",
"gravatar",
"updatesCountOnUserForTesting",
"tokens",
event_chain_id, 
event_id
FROM public.user
WHERE id IN ${sql(entityIdArray)};`;

const batchSetUserCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
    gravatar: entityData.entity.gravatar !== undefined ? entityData.entity.gravatar : null,
  }));
  return sql`
    INSERT INTO public.user
${sql(combinedEntityAndEventData,
    "id",
    "address",
    "gravatar",
    "updatesCountOnUserForTesting",
    "tokens",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "address" = EXCLUDED."address",
  "gravatar" = EXCLUDED."gravatar",
  "updatesCountOnUserForTesting" = EXCLUDED."updatesCountOnUserForTesting",
  "tokens" = EXCLUDED."tokens",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetUser = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_User = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_User, batchSetUserCore);
}

module.exports.batchDeleteUser = (sql, entityIdArray) => sql`
DELETE
FROM public.user
WHERE id IN ${sql(entityIdArray)};`
// end db operations for User

//////////////////////////////////////////////
// DB operations for Gravatar:
//////////////////////////////////////////////

module.exports.readGravatarEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"owner",
"displayName",
"imageUrl",
"updatesCount",
event_chain_id, 
event_id
FROM public.gravatar
WHERE id IN ${sql(entityIdArray)};`;

const batchSetGravatarCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
  }));
  return sql`
    INSERT INTO public.gravatar
${sql(combinedEntityAndEventData,
    "id",
    "owner",
    "displayName",
    "imageUrl",
    "updatesCount",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "owner" = EXCLUDED."owner",
  "displayName" = EXCLUDED."displayName",
  "imageUrl" = EXCLUDED."imageUrl",
  "updatesCount" = EXCLUDED."updatesCount",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetGravatar = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_Gravatar = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_Gravatar, batchSetGravatarCore);
}

module.exports.batchDeleteGravatar = (sql, entityIdArray) => sql`
DELETE
FROM public.gravatar
WHERE id IN ${sql(entityIdArray)};`
// end db operations for Gravatar

//////////////////////////////////////////////
// DB operations for Nftcollection:
//////////////////////////////////////////////

module.exports.readNftcollectionEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"contractAddress",
"name",
"symbol",
"maxSupply",
"currentSupply",
event_chain_id, 
event_id
FROM public.nftcollection
WHERE id IN ${sql(entityIdArray)};`;

const batchSetNftcollectionCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
  }));
  return sql`
    INSERT INTO public.nftcollection
${sql(combinedEntityAndEventData,
    "id",
    "contractAddress",
    "name",
    "symbol",
    "maxSupply",
    "currentSupply",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "contractAddress" = EXCLUDED."contractAddress",
  "name" = EXCLUDED."name",
  "symbol" = EXCLUDED."symbol",
  "maxSupply" = EXCLUDED."maxSupply",
  "currentSupply" = EXCLUDED."currentSupply",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetNftcollection = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_Nftcollection = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_Nftcollection, batchSetNftcollectionCore);
}

module.exports.batchDeleteNftcollection = (sql, entityIdArray) => sql`
DELETE
FROM public.nftcollection
WHERE id IN ${sql(entityIdArray)};`
// end db operations for Nftcollection

//////////////////////////////////////////////
// DB operations for Token:
//////////////////////////////////////////////

module.exports.readTokenEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"tokenId",
"collection",
"owner",
event_chain_id, 
event_id
FROM public.token
WHERE id IN ${sql(entityIdArray)};`;

const batchSetTokenCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
  }));
  return sql`
    INSERT INTO public.token
${sql(combinedEntityAndEventData,
    "id",
    "tokenId",
    "collection",
    "owner",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "tokenId" = EXCLUDED."tokenId",
  "collection" = EXCLUDED."collection",
  "owner" = EXCLUDED."owner",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetToken = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_Token = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_Token, batchSetTokenCore);
}

module.exports.batchDeleteToken = (sql, entityIdArray) => sql`
DELETE
FROM public.token
WHERE id IN ${sql(entityIdArray)};`
// end db operations for Token

//////////////////////////////////////////////
// DB operations for A:
//////////////////////////////////////////////

module.exports.readAEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"b",
event_chain_id, 
event_id
FROM public.a
WHERE id IN ${sql(entityIdArray)};`;

const batchSetACore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
  }));
  return sql`
    INSERT INTO public.a
${sql(combinedEntityAndEventData,
    "id",
    "b",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "b" = EXCLUDED."b",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetA = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_A = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_A, batchSetACore);
}

module.exports.batchDeleteA = (sql, entityIdArray) => sql`
DELETE
FROM public.a
WHERE id IN ${sql(entityIdArray)};`
// end db operations for A

//////////////////////////////////////////////
// DB operations for B:
//////////////////////////////////////////////

module.exports.readBEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"a",
"c",
event_chain_id, 
event_id
FROM public.b
WHERE id IN ${sql(entityIdArray)};`;

const batchSetBCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
    c: entityData.entity.c !== undefined ? entityData.entity.c : null,
  }));
  return sql`
    INSERT INTO public.b
${sql(combinedEntityAndEventData,
    "id",
    "a",
    "c",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "a" = EXCLUDED."a",
  "c" = EXCLUDED."c",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetB = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_B = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_B, batchSetBCore);
}

module.exports.batchDeleteB = (sql, entityIdArray) => sql`
DELETE
FROM public.b
WHERE id IN ${sql(entityIdArray)};`
// end db operations for B

//////////////////////////////////////////////
// DB operations for C:
//////////////////////////////////////////////

module.exports.readCEntities = (sql, entityIdArray) => sql`
SELECT 
"id",
"a",
event_chain_id, 
event_id
FROM public.c
WHERE id IN ${sql(entityIdArray)};`;

const batchSetCCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
  }));
  return sql`
    INSERT INTO public.c
${sql(combinedEntityAndEventData,
    "id",
    "a",
    "event_chain_id",
    "event_id",
  )}
  ON CONFLICT(id) DO UPDATE
  SET
  "id" = EXCLUDED."id",
  "a" = EXCLUDED."a",
  "event_chain_id" = EXCLUDED."event_chain_id",
  "event_id" = EXCLUDED."event_id";`;
}

module.exports.batchSetC = (sql, entityDataArray) => {
  // TODO: make this max batch size optimal. Do calculations to achieve this.
  const MAX_ITEMS_PER_QUERY_C = 50;

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_C, batchSetCCore);
}

module.exports.batchDeleteC = (sql, entityIdArray) => sql`
DELETE
FROM public.c
WHERE id IN ${sql(entityIdArray)};`
// end db operations for C

