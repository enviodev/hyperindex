module InMemoryStore = {
  let entityCurrentCrud = (currentCrud: option<Types.crud>, nextCrud: Types.crud) => {
    switch (currentCrud, nextCrud) {
    | (Some(Create), Create) => Types.Create
    | (Some(Read), Create)
    | (Some(Update), Create)
    | (Some(Delete), Create) =>
      // dont know if this is an update or create
      Update
    | (Some(Create), Read) => Create
    | (Some(Read), Read) => Read
    | (Some(Update), Read) => Update
    | (Some(Delete), Read) => Delete
    | (Some(Create), Update) => Create
    | (Some(Read), Update) => Update
    | (Some(Update), Update) => Update
    | (Some(Delete), Update) => Update
    | (Some(Create), Delete) => Delete // interesting to note to line 23
    | (Some(Read), Delete) => Delete
    | (Some(Update), Delete) => Delete
    | (Some(Delete), Delete) => Delete
    | (None, _) => nextCrud
    }
  }

  module Gravatar = {
    let gravatarDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.gravatarEntity>>> = ref(
      Js.Dict.empty(),
    )

    let getGravatar = (~id: string) => {
      let row = Js.Dict.get(gravatarDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setGravatar = (~gravatar: Types.gravatarEntity, ~crud: Types.crud) => {
      let gravatarCurrentCrud = Js.Dict.get(
        gravatarDict.contents,
        gravatar.id,
      )->Belt.Option.map(row => {
        row.crud
      })

      Js.Dict.set(
        gravatarDict.contents,
        gravatar.id,
        {entity: gravatar, crud: entityCurrentCrud(gravatarCurrentCrud, crud)},
      )
    }
  }
  let resetStore = () => {
    Gravatar.gravatarDict := Js.Dict.empty()
  }
}

type uniqueEntityReadIds = Js.Dict.t<Types.id>
type allEntityReads = Js.Dict.t<uniqueEntityReadIds>

let loadEntities = async (entityBatch: array<Types.entityRead>) => {
  let uniqueGravatarDict = Js.Dict.empty()

  entityBatch->Belt.Array.forEach(readEntity => {
    switch readEntity {
    | GravatarRead(entity) =>
      let _ = Js.Dict.set(uniqueGravatarDict, readEntity->Types.entitySerialize, entity)
    }
  })

  let gravatarEntitiesArray = await DbFunctions.Gravatar.readGravatarEntities(
    Js.Dict.values(uniqueGravatarDict),
  )

  gravatarEntitiesArray->Belt.Array.forEach(gravatar =>
    InMemoryStore.Gravatar.setGravatar(~gravatar, ~crud=Types.Read)
  )
}

let createBatch = () => {
  InMemoryStore.resetStore()
}

let executeBatch = async () => {
  let gravatarRows = InMemoryStore.Gravatar.gravatarDict.contents->Js.Dict.values

  let deleteGravatarIds =
    gravatarRows
    ->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Delete ? Some(gravatarRow.entity) : None
    )
    ->Belt.Array.map(gravatar => gravatar.id)

  let setGravatar =
    gravatarRows->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Create || gravatarRow.crud == Update
        ? Some(gravatarRow.entity)
        : None
    )

  await [
    DbFunctions.Gravatar.batchDeleteGravatar(deleteGravatarIds),
    DbFunctions.Gravatar.batchSetGravatar(setGravatar),
  ]->Promise.all
}
