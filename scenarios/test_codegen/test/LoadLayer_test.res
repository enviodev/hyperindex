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
})
