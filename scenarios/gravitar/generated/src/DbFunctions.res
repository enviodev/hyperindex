open DrizzleOrm

/// Below should be generated from the schema:
type gravatarValues

let gravatarValues: Drizzle.values<Types.gravatarEntity, gravatarValues> = (
  insertion,
  gravatarEntities,
) => insertion->Drizzle.values(gravatarEntities)

let deleteDictKey = (_dict: Js.Dict.t<'a>, _key: string) => %raw(`delete _dict[_key]`)

let databaseDict: Js.Dict.t<Types.gravatarEntity> = Js.Dict.empty()

let getGravatarDb = (~id: string) => {
  Js.Dict.get(databaseDict, id)
}

let setGravatarDb = (~gravatar: Types.gravatarEntity) => {
  Js.Dict.set(databaseDict, gravatar.id, gravatar)
}

/*
let batchUpsertGravatars = async (gravatarsArray) => {
  await db
    .insert(users)
    .values(gravatarsArray)
    .onConflictDoUpdate(gravatarsArray.map((gravatar) => { target: gravatar.id, set: { owner: gravitar.owner, displayName: gravitar.displayName, imageUrl: gravitar.imageUrl, updatesCount: gravitar.updatesCount } });
};
*/

let batchSetGravatar = async (batch: array<Types.gravatarEntity>) => {
  let db = await DbProvision.getDb()

  db->Drizzle.insert(~table=DbSchema.gravatar)->gravatarValues(batch)
}

let batchDeleteGravatar = (batch: array<Types.gravatarEntity>) => {
  batch
  ->Belt.Array.forEach(entity => {
    deleteDictKey(databaseDict, entity.id)
  })
  ->Promise.resolve
}

let readGravatarEntities = (entityReads: array<Types.entityRead>): promise<array<Types.entity>> => {
  entityReads
  ->Belt.Array.keepMap(entityRead => {
    switch entityRead {
    | GravatarRead(id) =>
      getGravatarDb(~id)->Belt.Option.map(gravatar => Types.GravatarEntity(gravatar))
    }
  })
  ->Promise.resolve
}
