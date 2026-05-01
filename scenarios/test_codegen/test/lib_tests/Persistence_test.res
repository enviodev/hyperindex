open Vitest

describe("Test Persistence layer init", () => {
  Async.it("Should initialize the persistence layer without the user entities", async t => {
    let storageMock = MockIndexer.Storage.make([#isInitialized, #resumeInitialState, #initialize])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    t.expect(
      persistence.allEntities,
      ~message=`All entities should automatically include the indexer core ones`,
    ).toEqual([InternalTable.EnvioAddresses.entityConfig])
    t.expect(
      persistence.allEnums,
      ~message=`All enums should automatically include the indexer core ones`,
    ).toEqual([EntityHistory.RowAction.config->Table.fromGenericEnumConfig])
    t.expect(persistence.storageStatus, ~message=`Intial storage status should be unknown`).toEqual(
      Persistence.Unknown,
    )

    t.expect(
      storageMock.isInitializedCalls,
      ~message=`Storage should not be initialized`,
    ).toEqual([])
    t.expect(storageMock.initializeCalls, ~message=`Storage should not be initialized`).toEqual([])

    let envioInfo = JSON.Encode.object(Dict.make())
    let p = persistence->Persistence.init(~chainConfigs=[], ~envioInfo)

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
    ).toEqual((
      1,
      [
        {
          "entities": persistence.allEntities,
          "chainConfigs": [],
          "enums": persistence.allEnums,
          "envioInfo": envioInfo,
        },
      ],
      0,
    ))

    let initialState: Persistence.initialState = {
      cleanRun: true,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointId: 0n,
    }
    storageMock.resolveInitialize(initialState)
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()

    t.expect(persistence.storageStatus, ~message=`Storage status should be ready`).toEqual(
      Persistence.Ready(initialState),
    )

    // Can resolve the promise now
    await p

    await persistence->Persistence.init(~chainConfigs=[], ~envioInfo)
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Calling init the second time shouldn't do anything`,
    ).toEqual((1, 1, 0))

    let _p2 = persistence->Persistence.init(~reset=true, ~chainConfigs=[], ~envioInfo)
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.initializeCalls->Array.getUnsafe(1),
      ),
      ~message=`Calling init with reset=true should ignore that the storage is already ready.
      It will perform initialize call with cleanRun=true without additional check for storage being initialized`,
    ).toEqual((
      1,
      2,
      {
        "entities": persistence.allEntities,
        "chainConfigs": [],
        "enums": persistence.allEnums,
        "envioInfo": envioInfo,
      },
    ))
  })

  Async.it("Should skip initialization when storage is already initialized", async t => {
    let storageMock = MockIndexer.Storage.make([#isInitialized, #resumeInitialState])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    let p = persistence->Persistence.init(~chainConfigs=[], ~envioInfo=JSON.Encode.object(Dict.make()))
    // Additional calls to init should not do anything
    let _ = persistence->Persistence.init(~chainConfigs=[], ~envioInfo=JSON.Encode.object(Dict.make()))
    let _ = persistence->Persistence.init(~chainConfigs=[], ~envioInfo=JSON.Encode.object(Dict.make()))

    storageMock.resolveIsInitialized(true)
    // init goes through readEnvioInfo + writeEnvioInfo (backfill arm — the
    // mock returns None) before reaching resumeInitialState. Drain enough
    // microtasks for resumeInitialState to register its resolver before we
    // try to resolve it.
    for _ in 1 to 5 {
      await Promise.resolve()
    }

    let initialState: Persistence.initialState = {
      cleanRun: false,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointId: 0n,
    }
    storageMock.resolveLoadInitialState(initialState)
    await p

    t.expect(persistence.storageStatus, ~message=`Storage status should be ready`).toEqual(
      Persistence.Ready(initialState),
    )
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Storage should be already initialized without additional initialize calls.
Although it should load effect caches metadata.`,
    ).toEqual((1, 0, 1))
  })

  Async.it(
    "Throws on resume when stored envio_info diverges from the current config",
    async t => {
      let storageMock = MockIndexer.Storage.make([
        #isInitialized,
        #initialize,
        #resumeInitialState,
      ])

      // Seed envio_info with one config via initialize, then re-init the
      // persistence layer with a different config — Persistence.init should
      // detect the mismatch in resumeInitialState's compat check and throw.
      let storedConfig = JSON.parseOrThrow(`{"name": "old", "evm": {}}`)
      let initialState: Persistence.initialState = {
        cleanRun: true,
        chains: [],
        cache: Dict.make(),
        reorgCheckpoints: [],
        checkpointId: 0n,
      }

      let firstPersistence = Persistence.make(
        ~userEntities=[],
        ~allEnums=[],
        ~storage=storageMock.storage,
      )
      let initPromise =
        firstPersistence->Persistence.init(~chainConfigs=[], ~envioInfo=storedConfig)
      storageMock.resolveIsInitialized(false)
      for _ in 1 to 3 {
        await Promise.resolve()
      }
      storageMock.resolveInitialize(initialState)
      await initPromise

      // New persistence sharing the same storage mock — envio_info is now
      // populated with `storedConfig`, so a mismatching ~envioInfo on resume
      // should fail before resumeInitialState is even called.
      let secondPersistence = Persistence.make(
        ~userEntities=[],
        ~allEnums=[],
        ~storage=storageMock.storage,
      )
      let mismatchedConfig = JSON.parseOrThrow(`{"name": "new", "evm": {}}`)
      let resumePromise =
        secondPersistence->Persistence.init(~chainConfigs=[], ~envioInfo=mismatchedConfig)
      storageMock.resolveIsInitialized(true)

      let raised = try {
        await resumePromise
        None
      } catch {
      | exn => Some(exn)
      }
      let message = switch raised {
      | Some(JsExn(e)) => e->JsExn.message->Option.getOr("")
      | _ => ""
      }
      t.expect(
        message->String.includes("Incompatible") || message->String.includes("incompatible"),
        ~message="should throw an incompatibility error mentioning the failure",
      ).toBe(true)
      t.expect(
        message->String.includes("name"),
        ~message="should name the diverged path",
      ).toBe(true)
      t.expect(
        storageMock.resumeInitialStateCalls->Array.length,
        ~message="resumeInitialState should NOT have been called — compat check fails first",
      ).toBe(0)
    },
  )
})
