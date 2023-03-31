let deleteDictKey = (_dict: Js.Dict.t<'a>, _key: string) => %raw(`delete _dict[_key]`)

let databaseDict: Js.Dict.t<Types.gravatarEntity> = Js.Dict.empty()

let getGravatarDb = (~id: string) => {
  Js.Dict.get(databaseDict, id)
}

let setGravatarDb = (~gravatar: Types.gravatarEntity) => {
  Js.Dict.set(databaseDict, gravatar.id, gravatar)
}

let batchSetGravatar = (batch: array<Types.gravatarEntity>) => {
  batch
  ->Belt.Array.forEach(entity => {
    setGravatarDb(~gravatar=entity)
  })
  ->Promise.resolve
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
