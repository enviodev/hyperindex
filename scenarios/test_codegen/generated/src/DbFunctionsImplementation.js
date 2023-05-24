// db operations for raw_events:

module.exports.readRawEventsEntities = (sql, entityIdArray) => sql`
  SELECT *
  FROM public.raw_events
  WHERE (chain_id, event_id) IN ${sql(entityIdArray)}`;

module.exports.batchSetRawEvents = (sql, entityDataArray) => {
  const valueCopyToFixBigIntType = entityDataArray; // This is required for BigInts to work in the db. See: https://github.com/Float-Capital/indexer/issues/212
  return sql`
    INSERT INTO public.raw_events
  ${sql(
    valueCopyToFixBigIntType,
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
  event_chain_id, 
  event_id
  FROM public.user
  WHERE id IN ${sql(entityIdArray)}`

  module.exports.batchSetUser = (sql, entityDataArray) => {
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
    "event_chain_id",
    "event_id",
  )}
    ON CONFLICT(id) DO UPDATE
    SET
    "id" = EXCLUDED."id",
    "address" = EXCLUDED."address",
    "gravatar" = EXCLUDED."gravatar",
    "event_chain_id" = EXCLUDED."event_chain_id",
    "event_id" = EXCLUDED."event_id"
  ;`
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

  module.exports.batchSetGravatar = (sql, entityDataArray) => {
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

  module.exports.batchDeleteGravatar = (sql, entityIdArray) => sql`
  DELETE
  FROM public.gravatar
  WHERE id IN ${sql(entityIdArray)};`
  // end db operations for Gravatar

