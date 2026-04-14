open Vitest

describe("Test Persistence layer init", () => {
  Async.it("Should initialize the persistence layer without the user entities", async t => {
    let storageMock = Mock.Storage.make([#isInitialized, #resumeInitialState, #initialize])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    t.expect(
      persistence.allEntities,
      ~message=`All entities should automatically include the indexer core ones`,
    ).toEqual([InternalTable.EnvioAddresses.entityConfig])
    t.expect(
      persistence.allEnums,
      ~message=`All enums should automatically include the indexer core ones`,
    ).toEqual([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
    t.expect(
      persistence.storageStatus,
      ~message=`Intial storage status should be unknown`,
    ).toEqual(Persistence.Unknown)

    t.expect(
      storageMock.isInitializedCalls,
      ~message=`Storage should not be initialized`,
    ).toEqual([])
    t.expect(storageMock.initializeCalls, ~message=`Storage should not be initialized`).toEqual([])

    let p = persistence->Persistence.init(~chainConfigs=[])

    t.expect(
      storageMock.isInitializedCalls,
      ~message=`Should check whether storage is initialized`,
    ).toEqual([true])
    t.expect(
      storageMock.initializeCalls,
      ~message=`Shouldn't call initialize before init check`,
    ).toEqual([])

    storageMock.resolveIsInitialized(false)
    let _ = await Promise.resolve()

    t.expect(
      switch persistence.storageStatus {
      | Persistence.Initializing(_) => true
      | _ => false
      },
      ~message=`Storage status should be initializing`,
    ).toEqual(true)

    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Should initialize if storage is not initialized`,
    ).toEqual(
      (
        1,
        [
          {
            "entities": persistence.allEntities,
            "chainConfigs": [],
            "enums": persistence.allEnums,
          },
        ],
        0,
      ),
    )

    let initialState: Persistence.initialState = {
      cleanRun: true,
      chains: [],
      cache: Js.Dict.empty(),
      reorgCheckpoints: [],
      checkpointId: 0n,
    }
    storageMock.resolveInitialize(initialState)
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()

    t.expect(
      persistence.storageStatus,
      ~message=`Storage status should be ready`,
    ).toEqual(Persistence.Ready(initialState))

    // Can resolve the promise now
    await p

    await persistence->Persistence.init(~chainConfigs=[])
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Calling init the second time shouldn't do anything`,
    ).toEqual((1, 1, 0))

    let _p2 = persistence->Persistence.init(~reset=true, ~chainConfigs=[])
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.initializeCalls->Js.Array2.unsafe_get(1),
      ),
      ~message=`Calling init with reset=true should ignore that the storage is already ready.
      It will perform initialize call with cleanRun=true without additional check for storage being initialized`,
    ).toEqual(
      (
        1,
        2,
        {
          "entities": persistence.allEntities,
          "chainConfigs": [],
          "enums": persistence.allEnums,
        },
      ),
    )
  })

  Async.it("Should skip initialization when storage is already initialized", async t => {
    let storageMock = Mock.Storage.make([#isInitialized, #resumeInitialState])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    let p = persistence->Persistence.init(~chainConfigs=[])
    // Additional calls to init should not do anything
    let _ = persistence->Persistence.init(~chainConfigs=[])
    let _ = persistence->Persistence.init(~chainConfigs=[])

    storageMock.resolveIsInitialized(true)
    let _ = await Promise.resolve()

    let initialState: Persistence.initialState = {
      cleanRun: false,
      chains: [],
      cache: Js.Dict.empty(),
      reorgCheckpoints: [],
      checkpointId: 0n,
    }
    storageMock.resolveLoadInitialState(initialState)
    let _ = await Promise.resolve()

    t.expect(
      persistence.storageStatus,
      ~message=`Storage status should be ready`,
    ).toEqual(Persistence.Ready(initialState))
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Storage should be already initialized without additional initialize calls.
Although it should load effect caches metadata.`,
    ).toEqual((1, 0, 1))

    // Can resolve the promise now
    await p
  })
})
