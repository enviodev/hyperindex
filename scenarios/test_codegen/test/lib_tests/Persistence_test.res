open RescriptMocha

describe("Test Persistence layer init", () => {
  Async.it("Should initialize the persistence layer without the user entities", async () => {
    let storageMock = Mock.Storage.make([#isInitialized, #initialize])

    let persistence = Persistence.make(
      ~userEntities=[],
      ~staticTables=[],
      ~dcRegistryEntityConfig=module(
        TablesStatic.DynamicContractRegistry
      )->Entities.entityModToInternal,
      ~allEnums=[],
      ~storage=storageMock.storage,
    )

    Assert.deepEqual(
      persistence.allEntities,
      [module(TablesStatic.DynamicContractRegistry)->Entities.entityModToInternal],
      ~message=`All entities should automatically include the indexer core ones`,
    )
    Assert.deepEqual(
      persistence.staticTables,
      [],
      // This is not implemented yet and passed via dependencies
      ~message=`All static tables should automatically include the indexer core ones`,
    )
    Assert.deepEqual(
      persistence.allEnums,
      [Persistence.entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig],
      ~message=`All enums should automatically include the indexer core ones`,
    )
    Assert.deepEqual(
      persistence.storageStatus,
      Persistence.Unknown,
      ~message=`Intial storage status should be unknown`,
    )

    Assert.deepEqual(
      storageMock.isInitializedCalls,
      [],
      ~message=`Storage should not be initialized`,
    )
    Assert.deepEqual(storageMock.initializeCalls, [], ~message=`Storage should not be initialized`)

    let p = persistence->Persistence.init

    Assert.deepEqual(
      storageMock.isInitializedCalls,
      [true],
      ~message=`Should check whether storage is initialized`,
    )
    Assert.deepEqual(
      storageMock.initializeCalls,
      [],
      ~message=`Shouldn't call initialize before init check`,
    )

    storageMock.resolveIsInitialized(false)
    let _ = await Promise.resolve()

    Assert.deepEqual(
      switch persistence.storageStatus {
      | Persistence.Initializing(_) => true
      | _ => false
      },
      true,
      ~message=`Storage status should be initializing`,
    )

    Assert.deepEqual(
      storageMock.initializeCalls,
      [
        {
          "entities": persistence.allEntities,
          "generalTables": persistence.staticTables,
          "enums": persistence.allEnums,
        },
      ],
      ~message=`Should initialize if storage is not initialized`,
    )

    storageMock.resolveInitialize()
    let _ = await Promise.resolve()

    Assert.deepEqual(
      persistence.storageStatus,
      Persistence.Ready({cleanRun: true, effectCaches: Js.Dict.empty()}),
      ~message=`Storage status should be ready`,
    )

    // Can resolve the promise now
    await p

    await persistence->Persistence.init
    Assert.deepEqual(
      (storageMock.isInitializedCalls->Array.length, storageMock.initializeCalls->Array.length),
      (1, 1),
      ~message=`Calling init the second time shouldn't do anything`,
    )

    let _p2 = persistence->Persistence.init(~reset=true)
    Assert.deepEqual(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.initializeCalls->Js.Array2.unsafe_get(1),
      ),
      (
        1,
        2,
        {
          "entities": persistence.allEntities,
          "generalTables": persistence.staticTables,
          "enums": persistence.allEnums,
        },
      ),
      ~message=`Calling init with reset=true should ignore that the storage is already ready.
      It will perform initialize call with cleanRun=true without additional check for storage being initialized`,
    )
  })

  Async.it("Should skip initialization when storage is already initialized", async () => {
    let storageMock = Mock.Storage.make([#isInitialized, #loadCaches])

    let persistence = Persistence.make(
      ~userEntities=[],
      ~staticTables=[],
      ~dcRegistryEntityConfig=module(
        TablesStatic.DynamicContractRegistry
      )->Entities.entityModToInternal,
      ~allEnums=[],
      ~storage=storageMock.storage,
    )

    let p = persistence->Persistence.init
    // Additional calls to init should not do anything
    let _ = persistence->Persistence.init
    let _ = persistence->Persistence.init

    storageMock.resolveIsInitialized(true)
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()

    Assert.deepEqual(
      persistence.storageStatus,
      Persistence.Ready({cleanRun: false, effectCaches: Js.Dict.empty()}),
      ~message=`Storage status should be ready`,
    )
    Assert.deepEqual(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.loadCachesCalls.contents,
      ),
      (1, 0, 1),
      ~message=`Storage should be already initialized without additional initialize calls.
Although it should load effect caches metadata.`,
    )

    // Can resolve the promise now
    await p
  })
})
