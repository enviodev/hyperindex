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

  module RawEvents = {
    let rawEventsDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.rawEventsEntity>>> = ref(
      Js.Dict.empty(),
    )

    let getRawEvents = (~id: string) => {
      let row = Js.Dict.get(rawEventsDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setRawEvents = (~entity: Types.rawEventsEntity, ~crud: Types.crud) => {
      let key = EventUtils.getEventIdKeyString(~chainId=entity.chainId, ~eventId=entity.eventId)
      let rawEventCurrentCrud =
        rawEventsDict.contents
        ->Js.Dict.get(key)
        ->Belt.Option.map(row => {
          row.crud
        })

      rawEventsDict.contents->Js.Dict.set(
        key,
        {
          eventData: {chainId: entity.chainId, eventId: entity.eventId},
          entity,
          crud: entityCurrentCrud(rawEventCurrentCrud, crud),
        },
      )
    }
  }

  module User = {
    let userDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.userEntity>>> = ref(Js.Dict.empty())

    let getUser = (~id: string) => {
      let row = Js.Dict.get(userDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setUser = (~entity: Types.userEntity, ~crud: Types.crud, ~eventData: Types.eventData) => {
      let userCurrentCrud = Js.Dict.get(userDict.contents, entity.id)->Belt.Option.map(row => {
        row.crud
      })

      userDict.contents->Js.Dict.set(
        entity.id,
        {eventData, entity, crud: entityCurrentCrud(userCurrentCrud, crud)},
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

    let setGravatar = (
      ~entity: Types.gravatarEntity,
      ~crud: Types.crud,
      ~eventData: Types.eventData,
    ) => {
      let gravatarCurrentCrud = Js.Dict.get(
        gravatarDict.contents,
        entity.id,
      )->Belt.Option.map(row => {
        row.crud
      })

      gravatarDict.contents->Js.Dict.set(
        entity.id,
        {eventData, entity, crud: entityCurrentCrud(gravatarCurrentCrud, crud)},
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

let loadEntities = async (sql, entityBatch: array<Types.entityRead>) => {
  // TODO: these should use javascript Set
  let uniqueUserDict = Js.Dict.empty()

  let uniqueGravatarDict = Js.Dict.empty()

  let populateUserLoadAsEntityFunctions: array<unit => unit> = []
  let populateGravatarLoadAsEntityFunctions: array<unit => unit> = []

  let uniqueUserAsEntityFieldArray: array<string> = []
  let uniqueGravatarAsEntityFieldArray: array<string> = []

  entityBatch->Belt.Array.forEach(readEntity => {
    switch readEntity {
    | UserRead(entityId, userLoad) =>
      let _ = Js.Dict.set(uniqueUserDict, entityId, entityId)

      switch userLoad.loadGravatar {
      | Some(
          _ /* TODO: read this and recursively add loaders. See: https://github.com/Float-Capital/indexer/issues/293 */,
        ) =>
        let _ = populateUserLoadAsEntityFunctions->Js.Array2.push(() => {
          let _ = InMemoryStore.User.getUser(~id=entityId)->Belt.Option.map(
            userEntity => {
              userEntity.gravatar->Belt.Option.map(
                gravatarId =>
                  switch uniqueGravatarDict->Js.Dict.get(gravatarId) {
                  | Some(_) => // Already loaded
                    ()
                  | None =>
                    let _ = uniqueGravatarAsEntityFieldArray->Js.Array2.push(gravatarId)
                    Js.Dict.set(uniqueGravatarDict, gravatarId, gravatarId)
                  },
              )
            },
          )
        })
      | None => ()
      }
    | GravatarRead(entityId, gravatarLoad) =>
      let _ = Js.Dict.set(uniqueGravatarDict, entityId, entityId)

      switch gravatarLoad.loadOwner {
      | Some(
          _ /* TODO: read this and recursively add loaders. See: https://github.com/Float-Capital/indexer/issues/293 */,
        ) =>
        let _ = populateGravatarLoadAsEntityFunctions->Js.Array2.push(() => {
          let _ = InMemoryStore.Gravatar.getGravatar(~id=entityId)->Belt.Option.map(
            gravatarEntity => {
              switch uniqueUserDict->Js.Dict.get(gravatarEntity.owner) {
              | Some(_) => // Already loaded
                ()
              | None =>
                let _ = uniqueUserAsEntityFieldArray->Js.Array2.push(gravatarEntity.owner)
                Js.Dict.set(uniqueUserDict, gravatarEntity.owner, gravatarEntity.owner)
              }
            },
          )
        })
      | None => ()
      }
    }
  })

  if Js.Dict.keys(uniqueUserDict)->Array.length > 0 {
    let userEntitiesArray =
      await sql->DbFunctions.User.readUserEntities(Js.Dict.keys(uniqueUserDict))

    userEntitiesArray->Belt.Array.forEach(readRow => {
      let {entity, eventData} = DbFunctions.User.readRowToReadEntityData(readRow)
      InMemoryStore.User.setUser(~entity, ~eventData, ~crud=Types.Read)
    })
  }

  if Js.Dict.keys(uniqueGravatarDict)->Array.length > 0 {
    let gravatarEntitiesArray =
      await sql->DbFunctions.Gravatar.readGravatarEntities(Js.Dict.keys(uniqueGravatarDict))

    gravatarEntitiesArray->Belt.Array.forEach(readRow => {
      let {entity, eventData} = DbFunctions.Gravatar.readRowToReadEntityData(readRow)
      InMemoryStore.Gravatar.setGravatar(~entity, ~eventData, ~crud=Types.Read)
    })
  }

  // Execute first layer of additional load functions:
  populateUserLoadAsEntityFunctions->Belt.Array.forEach(func => func())
  populateGravatarLoadAsEntityFunctions->Belt.Array.forEach(func => func())

  if uniqueUserAsEntityFieldArray->Array.length > 0 {
    let userFieldEntitiesArray =
      await sql->DbFunctions.User.readUserEntities(uniqueUserAsEntityFieldArray)

    userFieldEntitiesArray->Belt.Array.forEach(readRow => {
      let {entity, eventData} = DbFunctions.User.readRowToReadEntityData(readRow)
      InMemoryStore.User.setUser(~entity, ~eventData, ~crud=Types.Read)
    })
  }

  if uniqueGravatarAsEntityFieldArray->Array.length > 0 {
    let gravatarFildEntitiesArray =
      await sql->DbFunctions.Gravatar.readGravatarEntities(uniqueGravatarAsEntityFieldArray)

    gravatarFildEntitiesArray->Belt.Array.forEach(readRow => {
      let {entity, eventData} = DbFunctions.Gravatar.readRowToReadEntityData(readRow)
      InMemoryStore.Gravatar.setGravatar(~entity, ~eventData, ~crud=Types.Read)
    })
  }
}

let executeBatch = async sql => {
  let rawEventsRows = InMemoryStore.RawEvents.rawEventsDict.contents->Js.Dict.values

  let deleteRawEventsIdsPromise = sql => {
    let deleteRawEventsIds =
      rawEventsRows
      ->Belt.Array.keepMap(rawEventsRow =>
        rawEventsRow.crud == Types.Delete ? Some(rawEventsRow.entity) : None
      )
      ->Belt.Array.map(rawEvents => (rawEvents.chainId, rawEvents.eventId))

    if deleteRawEventsIds->Belt.Array.length > 0 {
      sql->DbFunctions.RawEvents.batchDeleteRawEvents(deleteRawEventsIds)
    } else {
      ()->Promise.resolve
    }
  }

  let setRawEventsPromise = sql => {
    let setRawEvents =
      rawEventsRows->Belt.Array.keepMap(rawEventsRow =>
        rawEventsRow.crud == Types.Create || rawEventsRow.crud == Update
          ? Some(rawEventsRow.entity)
          : None
      )

    if setRawEvents->Belt.Array.length > 0 {
      sql->DbFunctions.RawEvents.batchSetRawEvents(setRawEvents)
    } else {
      ()->Promise.resolve
    }
  }

  let userRows = InMemoryStore.User.userDict.contents->Js.Dict.values

  let deleteUserIdsPromise = sql => {
    let deleteUserIds =
      userRows
      ->Belt.Array.keepMap(userRow => userRow.crud == Types.Delete ? Some(userRow.entity) : None)
      ->Belt.Array.map(user => user.id)

    if deleteUserIds->Belt.Array.length > 0 {
      sql->DbFunctions.User.batchDeleteUser(deleteUserIds)
    } else {
      ()->Promise.resolve
    }
  }
  let setUserPromise = sql => {
    let setUser =
      userRows->Belt.Array.keepMap(userRow =>
        userRow.crud == Types.Create || userRow.crud == Update ? Some(userRow) : None
      )

    if setUser->Belt.Array.length > 0 {
      sql->DbFunctions.User.batchSetUser(setUser)
    } else {
      ()->Promise.resolve
    }
  }

  let gravatarRows = InMemoryStore.Gravatar.gravatarDict.contents->Js.Dict.values

  let deleteGravatarIdsPromise = sql => {
    let deleteGravatarIds =
      gravatarRows
      ->Belt.Array.keepMap(gravatarRow =>
        gravatarRow.crud == Types.Delete ? Some(gravatarRow.entity) : None
      )
      ->Belt.Array.map(gravatar => gravatar.id)

    if deleteGravatarIds->Belt.Array.length > 0 {
      sql->DbFunctions.Gravatar.batchDeleteGravatar(deleteGravatarIds)
    } else {
      ()->Promise.resolve
    }
  }
  let setGravatarPromise = sql => {
    let setGravatar =
      gravatarRows->Belt.Array.keepMap(gravatarRow =>
        gravatarRow.crud == Types.Create || gravatarRow.crud == Update ? Some(gravatarRow) : None
      )

    if setGravatar->Belt.Array.length > 0 {
      sql->DbFunctions.Gravatar.batchSetGravatar(setGravatar)
    } else {
      ()->Promise.resolve
    }
  }

  let res = await sql->Postgres.beginSql(sql => {
    [
      sql->deleteRawEventsIdsPromise,
      sql->setRawEventsPromise,
      sql->deleteUserIdsPromise,
      sql->setUserPromise,
      sql->deleteGravatarIdsPromise,
      sql->setGravatarPromise,
    ]
  })

  res
}
