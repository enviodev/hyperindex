open Vitest

describe("LoadLayer", () => {
  Async.it("Trys to load non existing entity from db", async t => {
    let storageMock = MockIndexer.Storage.make([#loadOrThrow])
    let inMemoryStore = MockIndexer.InMemoryStore.make()
    let loadManager = LoadManager.make()

    let getUser = entityId =>
      LoadLayer.loadById(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~inMemoryStore,
        ~entityId,
        ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        ~shouldGroup=true,
      )

    let user = await getUser("123")

    t.expect(user).toEqual(None)
    t.expect(storageMock.loadOrThrowCalls).toEqual([
      {
        "fieldName": "id",
        "fieldValues": ["123"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
    ])
  })

  Async.it("Does two round trips to db when requesting non existing entity one by one", async t => {
    let storageMock = MockIndexer.Storage.make([#loadOrThrow])
    let loadManager = LoadManager.make()
    let inMemoryStore = MockIndexer.InMemoryStore.make()

    let getUser = entityId =>
      LoadLayer.loadById(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~inMemoryStore,
        ~entityId,
        ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        ~shouldGroup=true,
      )

    let user1 = await getUser("1")
    let user2 = await getUser("2")

    t.expect(user1).toEqual(None)
    t.expect(user2).toEqual(None)
    t.expect(storageMock.loadOrThrowCalls).toEqual([
      {
        "fieldName": "id",
        "fieldValues": ["1"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
      {
        "fieldName": "id",
        "fieldValues": ["2"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
    ])
  })

  Async.it(
    "Stores the loaded entity in the in memory store and starts returning it on a subsequent call",
    async t => {
      let storageMock = MockIndexer.Storage.make([#loadOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = MockIndexer.InMemoryStore.make()
      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~persistence=storageMock->MockIndexer.Storage.toPersistence,
          ~entityConfig=MockIndexer.entityConfig(User),
          ~inMemoryStore,
          ~entityId,
          ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let user1 = await getUser("1")
      let user2 = await getUser("1")

      t.expect(user1).toEqual(None)
      t.expect(user2).toEqual(None)
      t.expect(storageMock.loadOrThrowCalls).toEqual([
        {
          "fieldName": "id",
          "fieldValues": ["1"]->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
      ])
    },
  )

  Async.it("Doesn't stack with an await in between of loader calls", async t => {
    let storageMock = MockIndexer.Storage.make([#loadOrThrow])
    let loadManager = LoadManager.make()
    let inMemoryStore = MockIndexer.InMemoryStore.make()
    let getUser = entityId =>
      LoadLayer.loadById(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~inMemoryStore,
        ~entityId,
        ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        ~shouldGroup=true,
      )

    let user1 = await getUser("1")

    await Promise.make(
      (resolve, _reject) => {
        let _ = setTimeout(
          () => {
            resolve()
          },
          0,
        )
      },
    )

    let user2 = await getUser("2")

    t.expect(user1).toEqual(None)
    t.expect(user2).toEqual(None)
    t.expect(storageMock.loadOrThrowCalls).toEqual([
      {
        "fieldName": "id",
        "fieldValues": ["1"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
      {
        "fieldName": "id",
        "fieldValues": ["2"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
    ])
  })

  Async.it("Batches requests to db when requesting non existing entity in Promise.all", async t => {
    let storageMock = MockIndexer.Storage.make([#loadOrThrow])
    let loadManager = LoadManager.make()
    let inMemoryStore = MockIndexer.InMemoryStore.make()
    let getUser = entityId =>
      LoadLayer.loadById(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~inMemoryStore,
        ~entityId,
        ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        ~shouldGroup=true,
      )

    let users = await Promise.all([getUser("1"), getUser("2")])

    t.expect(users).toEqual([None, None])
    t.expect(storageMock.loadOrThrowCalls).toEqual([
      {
        "fieldName": "id",
        "fieldValues": ["1", "2"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
    ])
  })

  Async.it(
    "Doesn't select entity from the db which was initially in the in memory store",
    async t => {
      let storageMock = MockIndexer.Storage.make([#loadOrThrow])
      let loadManager = LoadManager.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Indexer.Entities.User.t
      )

      let inMemoryStore = MockIndexer.InMemoryStore.make(
        ~entities=[(MockIndexer.entityConfig(User), [user1])],
      )
      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~persistence=storageMock->MockIndexer.Storage.toPersistence,
          ~entityConfig=MockIndexer.entityConfig(User),
          ~inMemoryStore,
          ~entityId,
          ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let users = await Promise.all([getUser("1"), getUser("2")])

      t.expect(users).toEqual([
        Some(user1->(Utils.magic: Indexer.Entities.User.t => Internal.entity)),
        None,
      ])
      t.expect(storageMock.loadOrThrowCalls).toEqual([
        {
          "fieldName": "id",
          "fieldValues": ["2"]->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
      ])
    },
  )

  Async.it(
    "Still selects entity from the db, even if it was added while LoadLayer was awaiting execution. But use the in memory store version to resolve",
    async t => {
      let storageMock = MockIndexer.Storage.make([#loadOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = MockIndexer.InMemoryStore.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Indexer.Entities.User.t
      )

      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~persistence=storageMock->MockIndexer.Storage.toPersistence,
          ~entityConfig=MockIndexer.entityConfig(User),
          ~inMemoryStore,
          ~entityId,
          ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
          ~shouldGroup=true,
        )

      let userPromise = getUser("1")

      // There's a one more in-memory check
      // After schedule resolve and before load operation call
      // So skip a microtask to bypass the check
      await Promise.resolve()

      inMemoryStore->MockIndexer.InMemoryStore.setEntity(
        ~entityConfig=MockIndexer.entityConfig(User),
        user1,
      )

      let user = await userPromise

      // It's Some(user1) even though from db we get None
      t.expect(user).toEqual(Some(user1->(Utils.magic: Indexer.Entities.User.t => Internal.entity)))
      t.expect(storageMock.loadOrThrowCalls).toEqual([
        {
          "fieldName": "id",
          "fieldValues": ["1"]->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
      ])
    },
  )

  Async.it(
    "Batch separated by microtasks, so it doesn't stack with an item after immediately resolving await (getting an existing entity from in memory store)",
    async t => {
      let storageMock = MockIndexer.Storage.make([#loadOrThrow])
      let loadManager = LoadManager.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Indexer.Entities.User.t
      )

      let inMemoryStore = MockIndexer.InMemoryStore.make(
        ~entities=[(MockIndexer.entityConfig(User), [user1])],
      )

      let getUser = entityId =>
        LoadLayer.loadById(
          ~loadManager,
          ~persistence=storageMock->MockIndexer.Storage.toPersistence,
          ~entityConfig=MockIndexer.entityConfig(User),
          ~inMemoryStore,
          ~entityId,
          ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
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

      t.expect(users).toEqual([None, None])
      // If we used setTimeout for schedule it would behave differently,
      // but we are not sure that it'll bring some benefits
      t.expect(storageMock.loadOrThrowCalls).toEqual([
        {
          "fieldName": "id",
          "fieldValues": ["2"]->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
        {
          "fieldName": "id",
          "fieldValues": ["3"]->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
      ])
    },
  )

  Async.it("Trys to load non existing entities from db by field", async t => {
    let storageMock = MockIndexer.Storage.make([#loadOrThrow])
    let loadManager = LoadManager.make()
    let inMemoryStore = MockIndexer.InMemoryStore.make()

    let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem
    let getUsersWithId = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~operator=Eq,
        ~inMemoryStore,
        ~fieldName="id",
        ~fieldValueSchema=S.string,
        ~item,
        ~fieldValue,
        ~shouldGroup=true,
      )
    let getUsersWithUpdates = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~operator=Gt,
        ~inMemoryStore,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
        ~item,
        ~fieldValue,
        ~shouldGroup=true,
      )

    let users1 = await getUsersWithId("123")
    let users2 = await getUsersWithUpdates(0)

    t.expect(users1).toEqual([])
    t.expect(users2).toEqual([])
    t.expect(storageMock.loadOrThrowCalls).toEqual([
      {
        "fieldName": "id",
        "fieldValues": ["123"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
      {
        "fieldName": "updatesCountOnUserForTesting",
        "fieldValues": [0]->Utils.magic,
        "tableName": "User",
        "operator": #">",
      },
    ])

    // Test Lt operator
    let getUsersWithUpdatesLt = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~operator=Lt,
        ~inMemoryStore,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
        ~item,
        ~fieldValue,
        ~shouldGroup=true,
      )

    let users3 = await getUsersWithUpdatesLt(5)
    t.expect(users3).toEqual([])
    t.expect(
      storageMock.loadOrThrowCalls->Array.length,
      ~message="Should have added Lt operator call",
    ).toEqual(3)
    t.expect(storageMock.loadOrThrowCalls->Array.get(2)).toEqual(
      Some({
        "fieldName": "updatesCountOnUserForTesting",
        "fieldValues": [5]->Utils.magic,
        "tableName": "User",
        "operator": #"<",
      }),
    )
  })

  Async.it("Gets entity from inMemoryStore by index if it exists", async t => {
    let storageMock = MockIndexer.Storage.make([#loadOrThrow])
    let loadManager = LoadManager.make()

    let user1: Indexer.Entities.User.t = {
      id: "1",
      accountType: USER,
      address: "",
      gravatar_id: None,
      updatesCountOnUserForTesting: 0,
    }
    let user2: Indexer.Entities.User.t = {
      id: "2",
      accountType: USER,
      address: "",
      gravatar_id: None,
      updatesCountOnUserForTesting: 1,
    }

    let inMemoryStore = MockIndexer.InMemoryStore.make(
      ~entities=[(MockIndexer.entityConfig(User), [user1, user2])],
    )

    let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem
    let getUsersWithId = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~operator=Eq,
        ~inMemoryStore,
        ~fieldName="id",
        ~fieldValueSchema=S.string,
        ~item,
        ~fieldValue,
        ~shouldGroup=true,
      )

    let getUsersWithUpdates = fieldValue =>
      LoadLayer.loadByField(
        ~loadManager,
        ~persistence=storageMock->MockIndexer.Storage.toPersistence,
        ~entityConfig=MockIndexer.entityConfig(User),
        ~operator=Gt,
        ~inMemoryStore,
        ~fieldName="updatesCountOnUserForTesting",
        ~fieldValueSchema=S.int,
        ~item,
        ~fieldValue,
        ~shouldGroup=true,
      )

    t.expect(await getUsersWithId("1")).toEqual([
      user1->(Utils.magic: Indexer.Entities.User.t => Internal.entity),
    ])
    t.expect(await getUsersWithUpdates(0), ~message="Should have loaded user2").toEqual([
      user2->(Utils.magic: Indexer.Entities.User.t => Internal.entity),
    ])
    t.expect(storageMock.loadOrThrowCalls).toEqual([
      {
        "fieldName": "id",
        "fieldValues": ["1"]->Utils.magic,
        "tableName": "User",
        "operator": #"=",
      },
      {
        "fieldName": "updatesCountOnUserForTesting",
        "fieldValues": [0]->Utils.magic,
        "tableName": "User",
        "operator": #">",
      },
    ])

    // The second time gets from inMemoryStore
    t.expect(await getUsersWithId("1")).toEqual([
      user1->(Utils.magic: Indexer.Entities.User.t => Internal.entity),
    ])
    t.expect(await getUsersWithUpdates(0)).toEqual([
      user2->(Utils.magic: Indexer.Entities.User.t => Internal.entity),
    ])
    t.expect(
      storageMock.loadOrThrowCalls->Array.length,
      ~message=`Shouldn't add more calls to the db`,
    ).toEqual(2)

    inMemoryStore->MockIndexer.InMemoryStore.setEntity(
      ~entityConfig=MockIndexer.entityConfig(User),
      {...user2, updatesCountOnUserForTesting: 0},
    )

    t.expect(
      await getUsersWithUpdates(0),
      ~message=`Doesn't get the user after the value is updated and not match the query`,
    ).toEqual([])
    t.expect(
      storageMock.loadOrThrowCalls->Array.length,
      ~message=`Shouldn't add more calls to the db`,
    ).toEqual(2)
  })

  Async.it(
    "Correctly gets entity from inMemoryStore by index if the entity set after the index creation",
    async t => {
      let storageMock = MockIndexer.Storage.make([#loadOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = MockIndexer.InMemoryStore.make()

      let user1 = (
        {
          id: "1",
          accountType: USER,
          address: "",
          gravatar_id: None,
          updatesCountOnUserForTesting: 0,
        }: Indexer.Entities.User.t
      )

      let item = MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem
      let getUsersWithId = fieldValue =>
        LoadLayer.loadByField(
          ~loadManager,
          ~persistence=storageMock->MockIndexer.Storage.toPersistence,
          ~entityConfig=MockIndexer.entityConfig(User),
          ~operator=Eq,
          ~inMemoryStore,
          ~fieldName="id",
          ~fieldValueSchema=S.string,
          ~item,
          ~fieldValue,
          ~shouldGroup=true,
        )

      let users = await getUsersWithId("1")

      let loadEntitiesByFieldSingleDbCall = [
        {
          "fieldName": "id",
          "fieldValues": ["1"]->Utils.magic,
          "tableName": "User",
          "operator": #"=",
        },
      ]
      t.expect(users).toEqual([])
      t.expect(storageMock.loadOrThrowCalls).toEqual(loadEntitiesByFieldSingleDbCall)

      inMemoryStore->MockIndexer.InMemoryStore.setEntity(
        ~entityConfig=MockIndexer.entityConfig(User),
        user1,
      )

      // The second time gets from inMemoryStore
      let users = await getUsersWithId("1")
      t.expect(users).toEqual([user1->(Utils.magic: Indexer.Entities.User.t => Internal.entity)])
      t.expect(storageMock.loadOrThrowCalls).toEqual(loadEntitiesByFieldSingleDbCall)
    },
  )
})

describe("LoadLayer effect cache", () => {
  // Reproduces an envio v3.1.0-rc.x regression: an effect with an *optional*
  // output that resolves to None leaks the ReScript nested-option sentinel
  // `{ BS_PRIVATE_NESTED_SOME_NONE: 0 }` instead of JS `undefined`. The
  // in-memory cache stores `option<output>` (here `option<option<bigint>>`)
  // and the cache hit path returns it without unwrapping the outer option,
  // so `Some(None)` reaches the handler. envio 3.0.2 returned `undefined`.
  Async.it(
    "Returns None (not the Some(None) sentinel) on a cache hit for an optional output that resolved to None",
    async t => {
      let storageMock = MockIndexer.Storage.make([#loadOrThrow])
      let loadManager = LoadManager.make()
      let inMemoryStore = MockIndexer.InMemoryStore.make()

      let callCount = ref(0)
      let effect =
        Envio.createEffect(
          {
            name: "optionalOutputEffect",
            input: S.string,
            output: S.null(S.bigint),
            rateLimit: Disable,
            cache: false,
          },
          async _ => {
            callCount := callCount.contents + 1
            None
          },
        )->(Utils.magic: Envio.effect<string, option<bigint>> => Internal.effect)

      let callEffect = () =>
        LoadLayer.loadEffect(
          ~loadManager,
          ~persistence=storageMock->MockIndexer.Storage.toPersistence,
          ~effect,
          ~effectArgs={
            input: "test"->(Utils.magic: string => Internal.effectInput),
            context: {"cache": false}->(Utils.magic: {..} => Internal.effectContext),
            cacheKey: "test",
            checkpointId: 0n,
          },
          ~inMemoryStore,
          ~shouldGroup=true,
          ~item=MockEvents.newGravatarLog1->MockEvents.newGravatarEventToBatchItem,
        )->(Utils.magic: promise<Internal.effectOutput> => promise<option<bigint>>)

      // Cache miss: runs the handler and seeds the in-memory cache.
      let first = await callEffect()
      // Cache hit: served from the in-memory effect cache.
      let second = await callEffect()

      t.expect((callCount.contents, first, second)).toEqual((1, None, None))
    },
  )
})
