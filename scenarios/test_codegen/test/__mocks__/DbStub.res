let deleteDictKey = (_dict: Js.Dict.t<'a>, _key: string) => %raw(`delete _dict[_key]`)

let databaseDict: Js.Dict.t<Entities.Gravatar.t> = Js.Dict.empty()

let getGravatarDb = (~id: string) => {
  Js.Dict.get(databaseDict, id)
}

let setGravatarDb = (~gravatar: Entities.Gravatar.t) => {
  Js.Dict.set(databaseDict, gravatar.id, gravatar)
}

let batchSetGravatar = (batch: array<Entities.Gravatar.t>) => {
  batch
  ->Belt.Array.forEach(entity => {
    setGravatarDb(~gravatar=entity)
  })
  ->Promise.resolve
}

let batchDeleteGravatar = (batch: array<Entities.Gravatar.t>) => {
  batch
  ->Belt.Array.forEach(entity => {
    deleteDictKey(databaseDict, entity.id)
  })
  ->Promise.resolve
}

let readGravatarEntities = (entityReads: array<Types.id>): promise<array<Entities.Gravatar.t>> => {
  entityReads
  ->Belt.Array.keepMap(id => {
    getGravatarDb(~id)->Belt.Option.map(gravatar => gravatar)
  })
  ->Promise.resolve
}
