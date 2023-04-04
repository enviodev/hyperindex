module InMemoryStore = {
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

    let applicableCrud = switch (gravatarCurrentCrud, crud) {
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
    | (None, _) => crud
    }

    Js.Dict.set(gravatarDict.contents, gravatar.id, {entity: gravatar, crud: applicableCrud})
  }

  let resetStore = () => {
    gravatarDict := Js.Dict.empty()
  }
}

let loadEntities = async (entityBatch: array<Types.entityRead>) => {
  let uniqueEntities: Js.Dict.t<Types.entityRead> = Js.Dict.empty()

  //1. Get all unique entityRead values
  entityBatch->Belt.Array.forEach(entity => {
    let _ = Js.Dict.set(uniqueEntities, entity->Types.entitySerialize, entity)
  })

  let uniqueEntitiesArray = uniqueEntities->Js.Dict.values

  let entitiesArray = await DbStub.readGravatarEntities(uniqueEntitiesArray)

  entitiesArray->Belt.Array.forEach(entity => {
    switch entity {
    | GravatarEntity(gravatar) => InMemoryStore.setGravatar(~gravatar, ~crud=Types.Read)
    }
  })
}

let createBatch = () => {
  InMemoryStore.resetStore()
}

// let getContext = () => {
//   // pass all references from in memory store for batch to context object and return
//   ContextStub.context
// }

let executeBatch = async () => {
  let gravatarRows = InMemoryStore.gravatarDict.contents->Js.Dict.values

  let deleteGravatars =
    gravatarRows->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Delete ? Some(gravatarRow.entity) : None
    )
  let setGravatars =
    gravatarRows->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Create || gravatarRow.crud == Update
        ? Some(gravatarRow.entity)
        : None
    )

  await (
    DbStub.batchDeleteGravatar(deleteGravatars),
    DbStub.batchSetGravatar(setGravatars),
  )->Promise.all2
}

module InMemoryStore = {
  let gravatarDict: Js.Dict.t<Types.gravatarEntity> = Js.Dict.empty()

  let getGravatar = (~id: string) => {
    Js.Dict.get(gravatarDict, id)
  }

  let setGravatar = (~id: string, ~gravatar: Types.gravatarEntity) => {
    Js.Dict.set(gravatarDict, id, gravatar)
  }
}
