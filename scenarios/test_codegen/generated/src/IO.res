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

  module User = {
    let userDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.userEntity>>> = ref(Js.Dict.empty())

    let getUser = (~id: string) => {
      let row = Js.Dict.get(userDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setUser = (~user: Types.userEntity, ~crud: Types.crud) => {
      let userCurrentCrud = Js.Dict.get(userDict.contents, user.id)->Belt.Option.map(row => {
        row.crud
      })

      Js.Dict.set(
        userDict.contents,
        user.id,
        {entity: user, crud: entityCurrentCrud(userCurrentCrud, crud)},
      )
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
    User.userDict := Js.Dict.empty()
    Gravatar.gravatarDict := Js.Dict.empty()
  }
}

type uniqueEntityReadIds = Js.Dict.t<Types.id>
type allEntityReads = Js.Dict.t<uniqueEntityReadIds>

let loadEntities = async (entityBatch: array<Types.entityRead>) => {
  let uniqueUserDict = Js.Dict.empty()

  let uniqueGravatarDict = Js.Dict.empty()

  entityBatch->Belt.Array.forEach(readEntity => {
    switch readEntity {
    | UserRead(entity) =>
      let _ = Js.Dict.set(uniqueUserDict, readEntity->Types.entitySerialize, entity)
    | GravatarRead(entity) =>
      let _ = Js.Dict.set(uniqueGravatarDict, readEntity->Types.entitySerialize, entity)
    }
  })

  let userEntitiesArray = await DbFunctions.User.readUserEntities(Js.Dict.values(uniqueUserDict))

  userEntitiesArray->Belt.Array.forEach(user => InMemoryStore.User.setUser(~user, ~crud=Types.Read))

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
  let userRows = InMemoryStore.User.userDict.contents->Js.Dict.values

  let deleteUserIdsPromise = () => {
    let deleteUserIds =
      userRows
      ->Belt.Array.keepMap(userRow => userRow.crud == Types.Delete ? Some(userRow.entity) : None)
      ->Belt.Array.map(user => user.id)

    if deleteUserIds->Belt.Array.length > 0 {
      DbFunctions.User.batchDeleteUser(deleteUserIds)
    } else {
      ()->Promise.resolve
    }
  }
  let setUserPromise = () => {
    let setUser =
      userRows->Belt.Array.keepMap(userRow =>
        userRow.crud == Types.Create || userRow.crud == Update ? Some(userRow.entity) : None
      )

    if setUser->Belt.Array.length > 0 {
      DbFunctions.User.batchSetUser(setUser)
    } else {
      ()->Promise.resolve
    }
  }

  let gravatarRows = InMemoryStore.Gravatar.gravatarDict.contents->Js.Dict.values

  let deleteGravatarIdsPromise = () => {
    let deleteGravatarIds =
      gravatarRows
      ->Belt.Array.keepMap(gravatarRow =>
        gravatarRow.crud == Types.Delete ? Some(gravatarRow.entity) : None
      )
      ->Belt.Array.map(gravatar => gravatar.id)

    if deleteGravatarIds->Belt.Array.length > 0 {
      DbFunctions.Gravatar.batchDeleteGravatar(deleteGravatarIds)
    } else {
      ()->Promise.resolve
    }
  }
  let setGravatarPromise = () => {
    let setGravatar =
      gravatarRows->Belt.Array.keepMap(gravatarRow =>
        gravatarRow.crud == Types.Create || gravatarRow.crud == Update
          ? Some(gravatarRow.entity)
          : None
      )

    if setGravatar->Belt.Array.length > 0 {
      DbFunctions.Gravatar.batchSetGravatar(setGravatar)
    } else {
      ()->Promise.resolve
    }
  }

  await [
    deleteUserIdsPromise(),
    setUserPromise(),
    deleteGravatarIdsPromise(),
    setGravatarPromise(),
  ]->Promise.all
}
