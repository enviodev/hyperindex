const postgres = require("postgres")

const sql = postgres("postgres://postgres:testing@localhost:5433/envio-dev")

  // db operations for User:

  module.exports.readUserEntities = (entityIdArray) => sql`
  SELECT *
  FROM public.user
  WHERE id IN ${sql(entityIdArray)}`

  module.exports.batchSetUser = (entityDataArray) => sql`
    INSERT INTO public.user
  ${sql(entityDataArray,
    "id",
    "address",
    "gravatar",
  )}
    ON CONFLICT(id) DO UPDATE
    SET
    "id" = EXCLUDED."id"
      ,
    "address" = EXCLUDED."address"
      ,
    "gravatar" = EXCLUDED."gravatar"
  ;`

  module.exports.batchDeleteUser = (entityIdArray) => sql`
  DELETE
  FROM public.user
  WHERE id IN ${sql(entityIdArray)};`
  // end db operations for User
  // db operations for Gravatar:

  module.exports.readGravatarEntities = (entityIdArray) => sql`
  SELECT *
  FROM public.gravatar
  WHERE id IN ${sql(entityIdArray)}`

  module.exports.batchSetGravatar = (entityDataArray) => sql`
    INSERT INTO public.gravatar
  ${sql(entityDataArray,
    "id",
    "owner",
    "displayName",
    "imageUrl",
    "updatesCount",
  )}
    ON CONFLICT(id) DO UPDATE
    SET
    "id" = EXCLUDED."id"
      ,
    "owner" = EXCLUDED."owner"
      ,
    "displayName" = EXCLUDED."displayName"
      ,
    "imageUrl" = EXCLUDED."imageUrl"
      ,
    "updatesCount" = EXCLUDED."updatesCount"
  ;`

  module.exports.batchDeleteGravatar = (entityIdArray) => sql`
  DELETE
  FROM public.gravatar
  WHERE id IN ${sql(entityIdArray)};`
  // end db operations for Gravatar
