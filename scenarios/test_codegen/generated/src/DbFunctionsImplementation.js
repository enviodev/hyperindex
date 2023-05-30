// db operations for raw_events:

module.exports.readLatestRawEventsBlockNumberProcessedOnChainId = (sql, chainId) => sql`
  SELECT block_number
  FROM public.raw_events
  WHERE chain_id = ${chainId}
  ORDER BY event_id DESC
  LIMIT 1;
`

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
    "params" = EXCLUDED."params"
  ;`;
};

const chunkBatchQuery = (sql, entityDataArray, maxItemsPerQuery, queryToExecute) => {
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

  return chunkBatchQuery(sql, entityDataArray, MAX_ITEMS_PER_QUERY_RawEvents, batchSetRawEventsCore);
};

module.exports.batchDeleteRawEvents = (sql, entityIdArray) => sql`
  DELETE
  FROM public.raw_events
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)};`;
// end db operations for raw_events

  // db operations for User:

  module.exports.readUserEntities = (sql, entityIdArray) => sql`
  SELECT 
  "id",
  "address",
  "gravatar",
  "tokens",
  event_chain_id, 
  event_id
  FROM public.user
  WHERE id IN ${sql(entityIdArray)}`

  const batchSetUserCore = (sql, entityDataArray) => {
  const combinedEntityAndEventData = entityDataArray.map((entityData) => ({
    ...entityData.entity,
    ...entityData.eventData,
  }));
  return sql`
    INSERT INTO public.user
  ${sql(combinedEntityAndEventData,
    "id",
    "address",
    "gravatar",
    "tokens",
    "event_chain_id",
    "event_id",
  )}
    ON CONFLICT(id) DO UPDATE
    SET
    "id" = EXCLUDED."id",
    "address" = EXCLUDED."address",
    "gravatar" = EXCLUDED."gravatar",
    "tokens" = EXCLUDED."tokens",
    "event_chain_id" = EXCLUDED."event_chain_id",
    "event_id" = EXCLUDED."event_id"
  ;`
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

  // db operations for Gravatar:

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
  WHERE id IN ${sql(entityIdArray)}`

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
    "event_id" = EXCLUDED."event_id"
  ;`
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

  // db operations for Nftcollection:

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
  WHERE id IN ${sql(entityIdArray)}`

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
    "event_id" = EXCLUDED."event_id"
  ;`
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

  // db operations for Token:

  module.exports.readTokenEntities = (sql, entityIdArray) => sql`
  SELECT 
  "id",
  "tokenId",
  "collection",
  "owner",
  event_chain_id, 
  event_id
  FROM public.token
  WHERE id IN ${sql(entityIdArray)}`

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
    "event_id" = EXCLUDED."event_id"
  ;`
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

