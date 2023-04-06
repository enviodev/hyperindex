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
type uniqueEntityReadIds = Js.Dict.t<Types.id>
type allEntityReads = Js.Dict.t<uniqueEntityReadIds>

let loadEntities = async (entityBatch: array<Types.entityRead>) => {
  // 1. Get all unique entityRead values
  /// TODO: we probably want to pass this in in a batched way, and not have to group them like this.
  ///       just doing this to get E2E working.
  let uniqueGravatarsDict = Js.Dict.empty()

  entityBatch->Belt.Array.forEach(entity => {
    switch entity {
    | GravatarRead(gravatar) =>
      let _ = Js.Dict.set(uniqueGravatarsDict, entity->Types.entitySerialize, gravatar)
    }
  })

  let gravatarEntitiesArray = await DbFunctions.readGravatarEntities(
    Js.Dict.values(uniqueGravatarsDict),
  )

  gravatarEntitiesArray->Belt.Array.forEach(gravatar =>
    InMemoryStore.setGravatar(~gravatar, ~crud=Types.Read)
  )
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

  let deleteGravatarIds =
    gravatarRows
    ->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Delete ? Some(gravatarRow.entity) : None
    )
    ->Belt.Array.map(gravatar => gravatar.id)

  let setGravatars =
    gravatarRows->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Create || gravatarRow.crud == Update
        ? Some(gravatarRow.entity)
        : None
    )

  await (
    DbFunctions.batchDeleteGravatar(deleteGravatarIds),
    DbFunctions.batchSetGravatar(setGravatars),
  )->Promise.all2
}
