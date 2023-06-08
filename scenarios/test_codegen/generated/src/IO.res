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
  module DynamicContractRegistry = {
    let dynamicContractRegistryDict: ref<
      Js.Dict.t<Types.inMemoryStoreRow<Types.dynamicContractRegistryEntity>>,
    > = ref(Js.Dict.empty())

    let getDynamicContractRegistry = (~id: string) => {
      let row = Js.Dict.get(dynamicContractRegistryDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setDynamicContractRegistry = (
      ~entity: Types.dynamicContractRegistryEntity,
      ~crud: Types.crud,
    ) => {
      let key = EventUtils.getContractAddressKeyString(
        ~chainId=entity.chainId,
        ~contractAddress=entity.contractAddress,
      )
      let dynamicContractRegistryCurrentCrud =
        dynamicContractRegistryDict.contents
        ->Js.Dict.get(key)
        ->Belt.Option.map(row => {
          row.crud
        })

      dynamicContractRegistryDict.contents->Js.Dict.set(
        key,
        {
          eventData: {chainId: entity.chainId, eventId: entity.eventId->Ethers.BigInt.toString},
          entity,
          crud: entityCurrentCrud(dynamicContractRegistryCurrentCrud, crud),
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

  module Nftcollection = {
    let nftcollectionDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.nftcollectionEntity>>> = ref(
      Js.Dict.empty(),
    )

    let getNftcollection = (~id: string) => {
      let row = Js.Dict.get(nftcollectionDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setNftcollection = (
      ~entity: Types.nftcollectionEntity,
      ~crud: Types.crud,
      ~eventData: Types.eventData,
    ) => {
      let nftcollectionCurrentCrud = Js.Dict.get(
        nftcollectionDict.contents,
        entity.id,
      )->Belt.Option.map(row => {
        row.crud
      })

      nftcollectionDict.contents->Js.Dict.set(
        entity.id,
        {eventData, entity, crud: entityCurrentCrud(nftcollectionCurrentCrud, crud)},
      )
    }
  }

  module Token = {
    let tokenDict: ref<Js.Dict.t<Types.inMemoryStoreRow<Types.tokenEntity>>> = ref(Js.Dict.empty())

    let getToken = (~id: string) => {
      let row = Js.Dict.get(tokenDict.contents, id)
      row->Belt.Option.map(row => row.entity)
    }

    let setToken = (~entity: Types.tokenEntity, ~crud: Types.crud, ~eventData: Types.eventData) => {
      let tokenCurrentCrud = Js.Dict.get(tokenDict.contents, entity.id)->Belt.Option.map(row => {
        row.crud
      })

      tokenDict.contents->Js.Dict.set(
        entity.id,
        {eventData, entity, crud: entityCurrentCrud(tokenCurrentCrud, crud)},
      )
    }
  }
  let resetStore = () => {
    User.userDict := Js.Dict.empty()
    Gravatar.gravatarDict := Js.Dict.empty()
    Nftcollection.nftcollectionDict := Js.Dict.empty()
    Token.tokenDict := Js.Dict.empty()
  }
}

type uniqueEntityReadIds = Js.Dict.t<Types.id>
type allEntityReads = Js.Dict.t<uniqueEntityReadIds>

let loadEntities = async (sql, entityBatch: array<Types.entityRead>) => {
  let loadLayer = ref(false)

  let uniqueUserDict = Js.Dict.empty()
  let uniqueGravatarDict = Js.Dict.empty()
  let uniqueNftcollectionDict = Js.Dict.empty()
  let uniqueTokenDict = Js.Dict.empty()

  let populateLoadAsEntityFunctions: ref<array<unit => unit>> = ref([])

  let uniqueUserAsEntityFieldArray: ref<array<string>> = ref([])
  let uniqueGravatarAsEntityFieldArray: ref<array<string>> = ref([])
  let uniqueNftcollectionAsEntityFieldArray: ref<array<string>> = ref([])
  let uniqueTokenAsEntityFieldArray: ref<array<string>> = ref([])

  let rec userLinkedEntityLoader = (
    entityId: string,
    userLoad: Types.userLoaderConfig,
    layer: int,
  ) => {
    if !loadLayer.contents {
      // NOTE: Always set this to true if it is false, I'm sure there are optimizations. Correctness over optimization for now.
      loadLayer := true
    }
    if Js.Dict.get(uniqueUserDict, entityId)->Belt.Option.isNone {
      let _ = uniqueUserAsEntityFieldArray.contents->Js.Array2.push(entityId)
      let _ = Js.Dict.set(uniqueUserDict, entityId, entityId)
    }

    switch userLoad.loadGravatar {
    | Some(loadGravatar) =>
      let _ = populateLoadAsEntityFunctions.contents->Js.Array2.push(() => {
        let _ = InMemoryStore.User.getUser(~id=entityId)->Belt.Option.map(userEntity => {
          let _ =
            userEntity.gravatar->Belt.Option.map(
              gravatarId => gravatarLinkedEntityLoader(gravatarId, loadGravatar, layer + 1),
            )
        })
      })
    | None => ()
    }
    switch userLoad.loadTokens {
    | Some(loadToken) =>
      let _ = populateLoadAsEntityFunctions.contents->Js.Array2.push(() => {
        let _ = InMemoryStore.User.getUser(~id=entityId)->Belt.Option.map(userEntity => {
          let _ =
            userEntity.tokens->Belt.Array.map(
              tokensId => tokenLinkedEntityLoader(tokensId, loadToken, layer + 1),
            )
        })
      })
    | None => ()
    }
    ()
  }
  and gravatarLinkedEntityLoader = (
    entityId: string,
    gravatarLoad: Types.gravatarLoaderConfig,
    layer: int,
  ) => {
    if !loadLayer.contents {
      // NOTE: Always set this to true if it is false, I'm sure there are optimizations. Correctness over optimization for now.
      loadLayer := true
    }
    if Js.Dict.get(uniqueGravatarDict, entityId)->Belt.Option.isNone {
      let _ = uniqueGravatarAsEntityFieldArray.contents->Js.Array2.push(entityId)
      let _ = Js.Dict.set(uniqueGravatarDict, entityId, entityId)
    }

    switch gravatarLoad.loadOwner {
    | Some(loadUser) =>
      let _ = populateLoadAsEntityFunctions.contents->Js.Array2.push(() => {
        let _ = InMemoryStore.Gravatar.getGravatar(
          ~id=entityId,
        )->Belt.Option.map(gravatarEntity => {
          let _ = userLinkedEntityLoader(gravatarEntity.owner, loadUser, layer + 1)
        })
      })
    | None => ()
    }
    ()
  }
  and nftcollectionLinkedEntityLoader = (entityId: string, layer: int) => {
    if !loadLayer.contents {
      // NOTE: Always set this to true if it is false, I'm sure there are optimizations. Correctness over optimization for now.
      loadLayer := true
    }
    if Js.Dict.get(uniqueNftcollectionDict, entityId)->Belt.Option.isNone {
      let _ = uniqueNftcollectionAsEntityFieldArray.contents->Js.Array2.push(entityId)
      let _ = Js.Dict.set(uniqueNftcollectionDict, entityId, entityId)
    }

    ()
  }
  and tokenLinkedEntityLoader = (
    entityId: string,
    tokenLoad: Types.tokenLoaderConfig,
    layer: int,
  ) => {
    if !loadLayer.contents {
      // NOTE: Always set this to true if it is false, I'm sure there are optimizations. Correctness over optimization for now.
      loadLayer := true
    }
    if Js.Dict.get(uniqueTokenDict, entityId)->Belt.Option.isNone {
      let _ = uniqueTokenAsEntityFieldArray.contents->Js.Array2.push(entityId)
      let _ = Js.Dict.set(uniqueTokenDict, entityId, entityId)
    }

    switch tokenLoad.loadCollection {
    | Some(loadNftcollection) =>
      let _ = populateLoadAsEntityFunctions.contents->Js.Array2.push(() => {
        let _ = InMemoryStore.Token.getToken(~id=entityId)->Belt.Option.map(tokenEntity => {
          let _ = nftcollectionLinkedEntityLoader(tokenEntity.collection, layer + 1)
        })
      })
    | None => ()
    }
    switch tokenLoad.loadOwner {
    | Some(loadUser) =>
      let _ = populateLoadAsEntityFunctions.contents->Js.Array2.push(() => {
        let _ = InMemoryStore.Token.getToken(~id=entityId)->Belt.Option.map(tokenEntity => {
          let _ = userLinkedEntityLoader(tokenEntity.owner, loadUser, layer + 1)
        })
      })
    | None => ()
    }
    ()
  }

  entityBatch->Belt.Array.forEach(readEntity => {
    switch readEntity {
    | UserRead(entityId, userLoad) => userLinkedEntityLoader(entityId, userLoad, 0)
    | GravatarRead(entityId, gravatarLoad) => gravatarLinkedEntityLoader(entityId, gravatarLoad, 0)
    | NftcollectionRead(entityId) => nftcollectionLinkedEntityLoader(entityId, 0)
    | TokenRead(entityId, tokenLoad) => tokenLinkedEntityLoader(entityId, tokenLoad, 0)
    }
  })

  while loadLayer.contents {
    loadLayer := false

    if uniqueUserAsEntityFieldArray.contents->Array.length > 0 {
      let userFieldEntitiesArray =
        await sql->DbFunctions.User.readUserEntities(uniqueUserAsEntityFieldArray.contents)

      userFieldEntitiesArray->Belt.Array.forEach(readRow => {
        let {entity, eventData} = DbFunctions.User.readRowToReadEntityData(readRow)
        InMemoryStore.User.setUser(~entity, ~eventData, ~crud=Types.Read)
      })

      uniqueUserAsEntityFieldArray := []
    }
    if uniqueGravatarAsEntityFieldArray.contents->Array.length > 0 {
      let gravatarFieldEntitiesArray =
        await sql->DbFunctions.Gravatar.readGravatarEntities(
          uniqueGravatarAsEntityFieldArray.contents,
        )

      gravatarFieldEntitiesArray->Belt.Array.forEach(readRow => {
        let {entity, eventData} = DbFunctions.Gravatar.readRowToReadEntityData(readRow)
        InMemoryStore.Gravatar.setGravatar(~entity, ~eventData, ~crud=Types.Read)
      })

      uniqueGravatarAsEntityFieldArray := []
    }
    if uniqueNftcollectionAsEntityFieldArray.contents->Array.length > 0 {
      let nftcollectionFieldEntitiesArray =
        await sql->DbFunctions.Nftcollection.readNftcollectionEntities(
          uniqueNftcollectionAsEntityFieldArray.contents,
        )

      nftcollectionFieldEntitiesArray->Belt.Array.forEach(readRow => {
        let {entity, eventData} = DbFunctions.Nftcollection.readRowToReadEntityData(readRow)
        InMemoryStore.Nftcollection.setNftcollection(~entity, ~eventData, ~crud=Types.Read)
      })

      uniqueNftcollectionAsEntityFieldArray := []
    }
    if uniqueTokenAsEntityFieldArray.contents->Array.length > 0 {
      let tokenFieldEntitiesArray =
        await sql->DbFunctions.Token.readTokenEntities(uniqueTokenAsEntityFieldArray.contents)

      tokenFieldEntitiesArray->Belt.Array.forEach(readRow => {
        let {entity, eventData} = DbFunctions.Token.readRowToReadEntityData(readRow)
        InMemoryStore.Token.setToken(~entity, ~eventData, ~crud=Types.Read)
      })

      uniqueTokenAsEntityFieldArray := []
    }

    populateLoadAsEntityFunctions.contents->Belt.Array.forEach(func => func())

    populateLoadAsEntityFunctions := []
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

  let dynamicContractRegistryRows =
    InMemoryStore.DynamicContractRegistry.dynamicContractRegistryDict.contents->Js.Dict.values

  let deleteDynamicContractRegistryIdsPromise = sql => {
    let deleteDynamicContractRegistryIds =
      dynamicContractRegistryRows
      ->Belt.Array.keepMap(dynamicContractRegistryRow =>
        dynamicContractRegistryRow.crud == Types.Delete
          ? Some(dynamicContractRegistryRow.entity)
          : None
      )
      ->Belt.Array.map(dynamicContractRegistry => (
        dynamicContractRegistry.chainId,
        dynamicContractRegistry.contractAddress,
      ))

    if deleteDynamicContractRegistryIds->Belt.Array.length > 0 {
      sql->DbFunctions.DynamicContractRegistry.batchDeleteDynamicContractRegistry(
        deleteDynamicContractRegistryIds,
      )
    } else {
      ()->Promise.resolve
    }
  }

  let setDynamicContractRegistryPromise = sql => {
    let setDynamicContractRegistry =
      dynamicContractRegistryRows->Belt.Array.keepMap(dynamicContractRegistryRow =>
        dynamicContractRegistryRow.crud == Types.Create || dynamicContractRegistryRow.crud == Update
          ? Some(dynamicContractRegistryRow.entity)
          : None
      )

    if setDynamicContractRegistry->Belt.Array.length > 0 {
      sql->DbFunctions.DynamicContractRegistry.batchSetDynamicContractRegistry(
        setDynamicContractRegistry,
      )
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
    let setUser = userRows->Belt.Array.keepMap(userRow =>
      userRow.crud == Types.Create || userRow.crud == Update
        ? Some({
            ...userRow,
            entity: userRow.entity->Types.serializeUserEntity,
          })
        : None
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
    let setGravatar = gravatarRows->Belt.Array.keepMap(gravatarRow =>
      gravatarRow.crud == Types.Create || gravatarRow.crud == Update
        ? Some({
            ...gravatarRow,
            entity: gravatarRow.entity->Types.serializeGravatarEntity,
          })
        : None
    )

    if setGravatar->Belt.Array.length > 0 {
      sql->DbFunctions.Gravatar.batchSetGravatar(setGravatar)
    } else {
      ()->Promise.resolve
    }
  }

  let nftcollectionRows = InMemoryStore.Nftcollection.nftcollectionDict.contents->Js.Dict.values

  let deleteNftcollectionIdsPromise = sql => {
    let deleteNftcollectionIds =
      nftcollectionRows
      ->Belt.Array.keepMap(nftcollectionRow =>
        nftcollectionRow.crud == Types.Delete ? Some(nftcollectionRow.entity) : None
      )
      ->Belt.Array.map(nftcollection => nftcollection.id)

    if deleteNftcollectionIds->Belt.Array.length > 0 {
      sql->DbFunctions.Nftcollection.batchDeleteNftcollection(deleteNftcollectionIds)
    } else {
      ()->Promise.resolve
    }
  }
  let setNftcollectionPromise = sql => {
    let setNftcollection = nftcollectionRows->Belt.Array.keepMap(nftcollectionRow =>
      nftcollectionRow.crud == Types.Create || nftcollectionRow.crud == Update
        ? Some({
            ...nftcollectionRow,
            entity: nftcollectionRow.entity->Types.serializeNftcollectionEntity,
          })
        : None
    )

    if setNftcollection->Belt.Array.length > 0 {
      sql->DbFunctions.Nftcollection.batchSetNftcollection(setNftcollection)
    } else {
      ()->Promise.resolve
    }
  }

  let tokenRows = InMemoryStore.Token.tokenDict.contents->Js.Dict.values

  let deleteTokenIdsPromise = sql => {
    let deleteTokenIds =
      tokenRows
      ->Belt.Array.keepMap(tokenRow => tokenRow.crud == Types.Delete ? Some(tokenRow.entity) : None)
      ->Belt.Array.map(token => token.id)

    if deleteTokenIds->Belt.Array.length > 0 {
      sql->DbFunctions.Token.batchDeleteToken(deleteTokenIds)
    } else {
      ()->Promise.resolve
    }
  }
  let setTokenPromise = sql => {
    let setToken = tokenRows->Belt.Array.keepMap(tokenRow =>
      tokenRow.crud == Types.Create || tokenRow.crud == Update
        ? Some({
            ...tokenRow,
            entity: tokenRow.entity->Types.serializeTokenEntity,
          })
        : None
    )

    if setToken->Belt.Array.length > 0 {
      sql->DbFunctions.Token.batchSetToken(setToken)
    } else {
      ()->Promise.resolve
    }
  }

  let res = await sql->Postgres.beginSql(sql => {
    [
      sql->deleteRawEventsIdsPromise,
      sql->setRawEventsPromise,
      sql->deleteDynamicContractRegistryIdsPromise,
      sql->setDynamicContractRegistryPromise,
      sql->deleteUserIdsPromise,
      sql->setUserPromise,
      sql->deleteGravatarIdsPromise,
      sql->setGravatarPromise,
      sql->deleteNftcollectionIdsPromise,
      sql->setNftcollectionPromise,
      sql->deleteTokenIdsPromise,
      sql->setTokenPromise,
    ]
  })

  res
}
