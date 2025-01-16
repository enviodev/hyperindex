open RescriptMocha

describe("LoadLayer", () => {
  Async.it("Trys to load non existing entity from db", async () => {
    let mock = Mock.LoadLayer.make()

    let getUser =
      mock.loadLayer->LoadLayer.makeLoader(
        ~entityMod=module(Entities.User),
        ~inMemoryStore=InMemoryStore.make(),
        ~logger=Logging.logger,
      )

    let user = await getUser("123")

    Assert.deepEqual(user, None)
    Assert.deepEqual(
      mock.loadEntitiesByIdsCalls,
      [
        {
          entityIds: ["123"],
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
        },
      ],
    )
    Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
  })

  Async.it(
    "Does two round trips to db when requesting non existing entity one by one",
    async () => {
      let mock = Mock.LoadLayer.make()

      let getUser =
        mock.loadLayer->LoadLayer.makeLoader(
          ~entityMod=module(Entities.User),
          ~inMemoryStore=InMemoryStore.make(),
          ~logger=Logging.logger,
        )

      let user1 = await getUser("1")
      let user2 = await getUser("2")

      Assert.deepEqual(user1, None)
      Assert.deepEqual(user2, None)
      Assert.deepEqual(
        mock.loadEntitiesByIdsCalls,
        [
          {
            entityIds: ["1"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
          {
            entityIds: ["2"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
        ],
      )
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
    },
  )

  Async.it(
    "Stores the loaded entity in the in memory store and starts returning it on a subsequent call",
    async () => {
      let mock = Mock.LoadLayer.make()

      let getUser =
        mock.loadLayer->LoadLayer.makeLoader(
          ~entityMod=module(Entities.User),
          ~inMemoryStore=InMemoryStore.make(),
          ~logger=Logging.logger,
        )

      let user1 = await getUser("1")
      let user2 = await getUser("1")

      Assert.deepEqual(user1, None)
      Assert.deepEqual(user2, None)
      Assert.deepEqual(
        mock.loadEntitiesByIdsCalls,
        [
          {
            entityIds: ["1"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
        ],
      )
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
    },
  )

  Async.it("Doesn't stack with an await in between of loader calls", async () => {
    let mock = Mock.LoadLayer.make()

    let getUser =
      mock.loadLayer->LoadLayer.makeLoader(
        ~entityMod=module(Entities.User),
        ~inMemoryStore=InMemoryStore.make(),
        ~logger=Logging.logger,
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
      mock.loadEntitiesByIdsCalls,
      [
        {
          entityIds: ["1"],
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
        },
        {
          entityIds: ["2"],
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
        },
      ],
    )
    Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
  })

  Async.it(
    "Batches requests to db when requesting non existing entity in Promise.all",
    async () => {
      let mock = Mock.LoadLayer.make()

      let getUser =
        mock.loadLayer->LoadLayer.makeLoader(
          ~entityMod=module(Entities.User),
          ~inMemoryStore=InMemoryStore.make(),
          ~logger=Logging.logger,
        )

      let users = await Promise.all([getUser("1"), getUser("2")])

      Assert.deepEqual(users, [None, None])
      Assert.deepEqual(
        mock.loadEntitiesByIdsCalls,
        [
          {
            entityIds: ["1", "2"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
        ],
      )
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
    },
  )

  Async.it(
    "Doesn't select entity from the db which was initially in the in memory store",
    async () => {
      let mock = Mock.LoadLayer.make()

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

      let getUser =
        mock.loadLayer->LoadLayer.makeLoader(
          ~entityMod=module(Entities.User),
          ~inMemoryStore,
          ~logger=Logging.logger,
        )

      let users = await Promise.all([getUser("1"), getUser("2")])

      Assert.deepEqual(users, [Some(user1), None])
      Assert.deepEqual(
        mock.loadEntitiesByIdsCalls,
        [
          {
            entityIds: ["2"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
        ],
      )
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
    },
  )

  Async.it(
    "Still selects entity from the db, even if it was added while LoadLayer was awaiting execution. But use the in memory store version to resolve",
    async () => {
      let mock = Mock.LoadLayer.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Entities.User.t
      )

      let inMemoryStore = Mock.InMemoryStore.make()

      let getUser =
        mock.loadLayer->LoadLayer.makeLoader(
          ~entityMod=module(Entities.User),
          ~inMemoryStore,
          ~logger=Logging.logger,
        )

      let userPromise = getUser("1")

      inMemoryStore->Mock.InMemoryStore.setEntity(~entityMod=module(Entities.User), user1)

      let user = await userPromise

      // It's Some(user1) even though from db we get None
      Assert.deepEqual(user, Some(user1))
      Assert.deepEqual(
        mock.loadEntitiesByIdsCalls,
        [
          {
            entityIds: ["1"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
        ],
      )
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
    },
  )

  Async.it(
    "Batch separated by microtasks, so it doesn't stack with an item after immediately resolving await (getting an existing entity from in memory store)",
    async () => {
      let mock = Mock.LoadLayer.make()

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

      let getUser =
        mock.loadLayer->LoadLayer.makeLoader(
          ~entityMod=module(Entities.User),
          ~inMemoryStore,
          ~logger=Logging.logger,
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
        mock.loadEntitiesByIdsCalls,
        [
          {
            entityIds: ["2"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
          {
            entityIds: ["3"],
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
          },
        ],
      )
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, [])
    },
  )

  Async.it("Trys to load non existing entities from db by field", async () => {
    let mock = Mock.LoadLayer.make()

    let getUsersWithId =
      mock.loadLayer->LoadLayer.makeWhereLoader(
        ~entityMod=module(Entities.User),
        ~operator=Eq,
        ~inMemoryStore=InMemoryStore.make(),
        ~logger=Logging.logger,
        ~fieldName="id",
        ~fieldValueSchema=S.string,
      )
    let getUsersWithUpdates =
      mock.loadLayer->LoadLayer.makeWhereLoader(
        ~entityMod=module(Entities.User),
        ~operator=Gt,
        ~inMemoryStore=InMemoryStore.make(),
        ~logger=Logging.logger,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
      )

    let users1 = await getUsersWithId("123")
    let users2 = await getUsersWithUpdates(0)

    Assert.deepEqual(users1, [])
    Assert.deepEqual(users2, [])
    Assert.deepEqual(mock.loadEntitiesByIdsCalls, [])
    Assert.deepEqual(
      mock.loadEntitiesByFieldCalls,
      [
        {
          fieldName: "id",
          fieldValue: "123"->Utils.magic,
          fieldValueSchema: S.string->Utils.magic,
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
          operator: Eq,
        },
        {
          fieldName: "updatesCountOnUserForTesting",
          fieldValue: 0->Utils.magic,
          fieldValueSchema: S.int->Utils.magic,
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
          operator: Gt,
        },
      ],
    )
  })

  Async.it("Gets entity from inMemoryStore by index if it exists", async () => {
    let mock = Mock.LoadLayer.make()

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

    let getUsersWithId =
      mock.loadLayer->LoadLayer.makeWhereLoader(
        ~operator=Eq,
        ~entityMod=module(Entities.User),
        ~inMemoryStore,
        ~logger=Logging.logger,
        ~fieldName="id",
        ~fieldValueSchema=S.string,
      )

    let getUsersWithUpdates =
      mock.loadLayer->LoadLayer.makeWhereLoader(
        ~entityMod=module(Entities.User),
        ~operator=Gt,
        ~inMemoryStore=InMemoryStore.make(),
        ~logger=Logging.logger,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
      )

    Assert.deepEqual(await getUsersWithId("1"), [user1])
    Assert.deepEqual(await getUsersWithUpdates(0), [user2])
    Assert.deepEqual(mock.loadEntitiesByIdsCalls, [])
    Assert.deepEqual(
      mock.loadEntitiesByFieldCalls,
      [
        {
          fieldName: "id",
          fieldValue: "1"->Utils.magic,
          fieldValueSchema: S.string->Utils.magic,
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
          operator: Eq,
        },
        {
          fieldName: "updatesCountOnUserForTesting",
          fieldValue: 0->Utils.magic,
          fieldValueSchema: S.int->Utils.magic,
          entityMod: module(Entities.User)->Entities.entityModToInternal,
          logger: Logging.logger,
          operator: Gt,
        },
      ],
    )
  })

  Async.it(
    "Correctly gets entity from inMemoryStore by index if the entity set after the index creation",
    async () => {
      let mock = Mock.LoadLayer.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Entities.User.t
      )

      let inMemoryStore = InMemoryStore.make()

      let getUsersWithId =
        mock.loadLayer->LoadLayer.makeWhereLoader(
          ~operator=Eq,
          ~entityMod=module(Entities.User),
          ~inMemoryStore,
          ~logger=Logging.logger,
          ~fieldName="id",
          ~fieldValueSchema=S.string,
        )

      let users = await getUsersWithId("1")

      let loadEntitiesByFieldSingleDbCall = [
        (
          {
            fieldName: "id",
            fieldValue: "1"->Utils.magic,
            fieldValueSchema: S.string->Utils.magic,
            entityMod: module(Entities.User)->Entities.entityModToInternal,
            logger: Logging.logger,
            operator: Eq,
          }: Mock.LoadLayer.loadEntitiesByFieldCall
        ),
      ]
      Assert.deepEqual(users, [])
      Assert.deepEqual(mock.loadEntitiesByIdsCalls, [])
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, loadEntitiesByFieldSingleDbCall)

      inMemoryStore->Mock.InMemoryStore.setEntity(~entityMod=module(Entities.User), user1)

      // The second time gets from inMemoryStore
      let users = await getUsersWithId("1")
      Assert.deepEqual(users, [user1])
      Assert.deepEqual(mock.loadEntitiesByIdsCalls, [])
      Assert.deepEqual(mock.loadEntitiesByFieldCalls, loadEntitiesByFieldSingleDbCall)
    },
  )
})
