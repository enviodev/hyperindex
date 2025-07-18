open RescriptMocha

describe("LoadLayer", () => {
  Async.it("Trys to load non existing entity from db", async () => {
    let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
    let inMemoryStore = InMemoryStore.make()
    let loadManager = LoadManager.make()

    let getUser = entityId =>
      LoadLayer.loadById(
        ~loadManager,
        ~storage=storageMock.storage,
        ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
        ~inMemoryStore,
        ~entityId,
        ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        ~shouldGroup=true,
      )

    let user = await getUser("123")

    Assert.deepEqual(user, None)
    Assert.deepEqual(
      storageMock.loadByIdsOrThrowCalls,
      [
        {
          "ids": ["123"],
          "tableName": "User",
        },
      ],
    )
  })

  Async.it(
    "Does two round trips to db when requesting non existing entity one by one",
    async () => {
      let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = InMemoryStore.make()

      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~inMemoryStore,
          ~entityId,
          ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let user1 = await getUser("1")
      let user2 = await getUser("2")

      Assert.deepEqual(user1, None)
      Assert.deepEqual(user2, None)
      Assert.deepEqual(
        storageMock.loadByIdsOrThrowCalls,
        [
          {
            "ids": ["1"],
            "tableName": "User",
          },
          {
            "ids": ["2"],
            "tableName": "User",
          },
        ],
      )
    },
  )

  Async.it(
    "Stores the loaded entity in the in memory store and starts returning it on a subsequent call",
    async () => {
      let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = InMemoryStore.make()
      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~inMemoryStore,
          ~entityId,
          ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let user1 = await getUser("1")
      let user2 = await getUser("1")

      Assert.deepEqual(user1, None)
      Assert.deepEqual(user2, None)
      Assert.deepEqual(
        storageMock.loadByIdsOrThrowCalls,
        [
          {
            "ids": ["1"],
            "tableName": "User",
          },
        ],
      )
    },
  )

  Async.it("Doesn't stack with an await in between of loader calls", async () => {
    let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
    let loadManager = LoadManager.make()
    let inMemoryStore = Mock.InMemoryStore.make()
    let getUser = entityId =>
      LoadLayer.loadById(
        ~loadManager,
        ~storage=storageMock.storage,
        ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
        ~inMemoryStore,
        ~entityId,
        ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        ~shouldGroup=true,
      )

    let user1 = await getUser("1")

    await Promise.make(
      (resolve, _reject) => {
        let _ = Js.Global.setTimeout(
          () => {
            resolve()
          },
          0,
        )
      },
    )

    let user2 = await getUser("2")

    Assert.deepEqual(user1, None)
    Assert.deepEqual(user2, None)
    Assert.deepEqual(
      storageMock.loadByIdsOrThrowCalls,
      [
        {
          "ids": ["1"],
          "tableName": "User",
        },
        {
          "ids": ["2"],
          "tableName": "User",
        },
      ],
    )
  })

  Async.it(
    "Batches requests to db when requesting non existing entity in Promise.all",
    async () => {
      let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = Mock.InMemoryStore.make()
      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~inMemoryStore,
          ~entityId,
          ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let users = await Promise.all([getUser("1"), getUser("2")])

      Assert.deepEqual(users, [None, None])
      Assert.deepEqual(
        storageMock.loadByIdsOrThrowCalls,
        [
          {
            "ids": ["1", "2"],
            "tableName": "User",
          },
        ],
      )
    },
  )

  Async.it(
    "Doesn't select entity from the db which was initially in the in memory store",
    async () => {
      let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
      let loadManager = LoadManager.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Entities.User.t
      )

      let inMemoryStore = Mock.InMemoryStore.make(~entities=[(module(Entities.User), [user1])])
      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~inMemoryStore,
          ~entityId,
          ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let users = await Promise.all([getUser("1"), getUser("2")])

      Assert.deepEqual(users, [Some(user1->Entities.User.castToInternal), None])
      Assert.deepEqual(
        storageMock.loadByIdsOrThrowCalls,
        [
          {
            "ids": ["2"],
            "tableName": "User",
          },
        ],
      )
      Assert.deepEqual(storageMock.loadByFieldOrThrowCalls, [])
    },
  )

  Async.it(
    "Still selects entity from the db, even if it was added while LoadLayer was awaiting execution. But use the in memory store version to resolve",
    async () => {
      let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = Mock.InMemoryStore.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Entities.User.t
      )

      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~inMemoryStore,
          ~entityId,
          ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let userPromise = getUser("1")

      // There's a one more in-memory check
      // After schedule resolve and before load operation call
      // So skip a microtask to bypass the check
      await Promise.resolve()

      inMemoryStore->Mock.InMemoryStore.setEntity(~entityMod=module(Entities.User), user1)

      let user = await userPromise

      // It's Some(user1) even though from db we get None
      Assert.deepEqual(user, Some(user1->Entities.User.castToInternal))
      Assert.deepEqual(
        storageMock.loadByIdsOrThrowCalls,
        [
          {
            "ids": ["1"],
            "tableName": "User",
          },
        ],
      )
    },
  )

  Async.it(
    "Batch separated by microtasks, so it doesn't stack with an item after immediately resolving await (getting an existing entity from in memory store)",
    async () => {
      let storageMock = Mock.Storage.make([#loadByIdsOrThrow])
      let loadManager = LoadManager.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Entities.User.t
      )

      let inMemoryStore = Mock.InMemoryStore.make(~entities=[(module(Entities.User), [user1])])

      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~inMemoryStore,
          ~entityId,
          ~eventItem=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let users = await Promise.all([
        getUser("2"),
        (
          async () => {
            let _ = await getUser("1")
            await getUser("3")
          }
        )(),
      ])

      Assert.deepEqual(users, [None, None])
      // If we used setTimeout for schedule it would behave differently,
      // but we are not sure that it'll bring some benefits
      Assert.deepEqual(
        storageMock.loadByIdsOrThrowCalls,
        [
          {
            "ids": ["2"],
            "tableName": "User",
          },
          {
            "ids": ["3"],
            "tableName": "User",
          },
        ],
      )
    },
  )

  Async.it("Trys to load non existing entities from db by field", async () => {
    let storageMock = Mock.Storage.make([#loadByFieldOrThrow])
    let loadManager = LoadManager.make()
    let inMemoryStore = Mock.InMemoryStore.make()

    let eventItem = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem
    let getUsersWithId = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~storage=storageMock.storage,
        ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
        ~operator=Eq,
        ~inMemoryStore,
        ~fieldName="id",
        ~fieldValueSchema=S.string,
        ~eventItem,
        ~fieldValue,
        ~shouldGroup=true,
      )
    let getUsersWithUpdates = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~storage=storageMock.storage,
        ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
        ~operator=Gt,
        ~inMemoryStore,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
        ~eventItem,
        ~fieldValue,
        ~shouldGroup=true,
      )

    let users1 = await getUsersWithId("123")
    let users2 = await getUsersWithUpdates(0)

    Assert.deepEqual(users1, [])
    Assert.deepEqual(users2, [])
    Assert.deepEqual(
      storageMock.loadByFieldOrThrowCalls,
      [
        {
          "fieldName": "id",
          "fieldValue": "123"->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
        {
          "fieldName": "updatesCountOnUserForTesting",
          "fieldValue": 0->Utils.magic,
          "tableName": "User",
          "operator": #">",
        },
      ],
    )
  })

  Async.it("Gets entity from inMemoryStore by index if it exists", async () => {
    let storageMock = Mock.Storage.make([#loadByIdsOrThrow, #loadByFieldOrThrow])
    let loadManager = LoadManager.make()

    let user1: Entities.User.t = {
      id: "1",
      accountType: USER,
      address: "",
      gravatar_id: None,
      updatesCountOnUserForTesting: 0,
    }
    let user2: Entities.User.t = {
      id: "2",
      accountType: USER,
      address: "",
      gravatar_id: None,
      updatesCountOnUserForTesting: 1,
    }

    let inMemoryStore = Mock.InMemoryStore.make(~entities=[(module(Entities.User), [user1, user2])])

    let eventItem = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem
    let getUsersWithId = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~storage=storageMock.storage,
        ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
        ~operator=Eq,
        ~inMemoryStore,
        ~fieldName="id",
        ~fieldValueSchema=S.string,
        ~eventItem,
        ~fieldValue,
        ~shouldGroup=true,
      )

    let getUsersWithUpdates = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~storage=storageMock.storage,
        ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
        ~operator=Gt,
        ~inMemoryStore,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
        ~eventItem,
        ~fieldValue,
        ~shouldGroup=true,
      )

    Assert.deepEqual(await getUsersWithId("1"), [user1->Entities.User.castToInternal])
    Assert.deepEqual(
      await getUsersWithUpdates(0),
      [user2->Entities.User.castToInternal],
      ~message="Should have loaded user2",
    )
    Assert.deepEqual(storageMock.loadByIdsOrThrowCalls, [])
    Assert.deepEqual(
      storageMock.loadByFieldOrThrowCalls,
      [
        {
          "fieldName": "id",
          "fieldValue": "1"->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
        {
          "fieldName": "updatesCountOnUserForTesting",
          "fieldValue": 0->Utils.magic,
          "tableName": "User",
          "operator": #">",
        },
      ],
    )

    // The second time gets from inMemoryStore
    Assert.deepEqual(await getUsersWithId("1"), [user1->Entities.User.castToInternal])
    Assert.deepEqual(await getUsersWithUpdates(0), [user2->Entities.User.castToInternal])
    Assert.deepEqual(storageMock.loadByIdsOrThrowCalls, [])
    Assert.deepEqual(
      storageMock.loadByFieldOrThrowCalls->Array.length,
      2,
      ~message=`Shouldn't add more calls to the db`,
    )

    inMemoryStore->Mock.InMemoryStore.setEntity(
      ~entityMod=module(Entities.User),
      {...user2, updatesCountOnUserForTesting: 0},
    )

    Assert.deepEqual(
      await getUsersWithUpdates(0),
      [],
      ~message=`Doesn't get the user after the value is updated and not match the query`,
    )
    Assert.deepEqual(storageMock.loadByIdsOrThrowCalls, [])
    Assert.deepEqual(
      storageMock.loadByFieldOrThrowCalls->Array.length,
      2,
      ~message=`Shouldn't add more calls to the db`,
    )
  })

  Async.it(
    "Correctly gets entity from inMemoryStore by index if the entity set after the index creation",
    async () => {
      let storageMock = Mock.Storage.make([#loadByFieldOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = Mock.InMemoryStore.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Entities.User.t
      )

      let eventItem = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem
      let getUsersWithId = fieldValue =>
        LoadLayer.loadByField(
          ~loadManager,
          ~storage=storageMock.storage,
          ~entityConfig=module(Entities.User)->Entities.entityModToInternal,
          ~operator=Eq,
          ~inMemoryStore,
          ~fieldName="id",
          ~fieldValueSchema=S.string,
          ~eventItem,
          ~fieldValue,
          ~shouldGroup=true,
        )

      let users = await getUsersWithId("1")

      let loadEntitiesByFieldSingleDbCall = [
        {
          "fieldName": "id",
          "fieldValue": "1"->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
      ]
      Assert.deepEqual(users, [])
      Assert.deepEqual(storageMock.loadByIdsOrThrowCalls, [])
      Assert.deepEqual(storageMock.loadByFieldOrThrowCalls, loadEntitiesByFieldSingleDbCall)

      inMemoryStore->Mock.InMemoryStore.setEntity(~entityMod=module(Entities.User), user1)

      // The second time gets from inMemoryStore
      let users = await getUsersWithId("1")
      Assert.deepEqual(users, [user1->Entities.User.castToInternal])
      Assert.deepEqual(storageMock.loadByIdsOrThrowCalls, [])
      Assert.deepEqual(storageMock.loadByFieldOrThrowCalls, loadEntitiesByFieldSingleDbCall)
    },
  )
})
