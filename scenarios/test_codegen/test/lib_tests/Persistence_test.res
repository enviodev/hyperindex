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

    let envioInfo = JSON.Encode.object(Dict.make())
    // Resume path now requires a stored envio_info row; without it, init
    // throws a version-mismatch incompat error (covered by a separate test).
    storageMock.seedEnvioInfo(envioInfo)

    let p = persistence->Persistence.init(~chainConfigs=[], ~envioInfo)
    // Additional calls to init should not do anything
    let _ = persistence->Persistence.init(~chainConfigs=[], ~envioInfo)
    let _ = persistence->Persistence.init(~chainConfigs=[], ~envioInfo)

    storageMock.resolveIsInitialized(true)
    // Drain enough microtasks for readEnvioInfo + the compat check to
    // complete so resumeInitialState registers its resolver before we
    // resolve it.
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

  // Seed envio_info via the storage mock's initialize, then resume with a
  // different config and capture whatever Persistence.init decides to throw.
  let resumeWithDifferentConfig = async (~stored: JSON.t, ~current: JSON.t) => {
    let storageMock = MockIndexer.Storage.make([
      #isInitialized,
      #initialize,
      #resumeInitialState,
    ])
    let initialState: Persistence.initialState = {
      cleanRun: true,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointId: 0n,
    }
    let p1 = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    let initPromise = p1->Persistence.init(~chainConfigs=[], ~envioInfo=stored)
    storageMock.resolveIsInitialized(false)
    for _ in 1 to 3 {
      await Promise.resolve()
    }
    storageMock.resolveInitialize(initialState)
    await initPromise

    let p2 = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    let resumePromise = p2->Persistence.init(~chainConfigs=[], ~envioInfo=current)
    storageMock.resolveIsInitialized(true)
    // Drain enough microtasks for the compat-passing path to reach
    // resumeInitialState and register its resolver before we resolve it.
    for _ in 1 to 5 {
      await Promise.resolve()
    }
    let resumeInitialState: Persistence.initialState = {
      cleanRun: false,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointId: 0n,
    }
    storageMock.resolveLoadInitialState(resumeInitialState)

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
    (raised, message, storageMock)
  }

  Async.it("Throws version-mismatch incompat error when envio_info row is missing", async t => {
    // Mirrors the upgrade case: schema initialized by an older envio (or
    // envio_info row deleted out-of-band) — readEnvioInfo returns None and
    // we surface it as the same incompat error rather than resuming.
    let storageMock = MockIndexer.Storage.make([#isInitialized, #resumeInitialState])
    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    let resumePromise =
      persistence->Persistence.init(
        ~chainConfigs=[],
        ~envioInfo=JSON.parseOrThrow(`{"name": "demo"}`),
      )
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
    t.expect(raised->Option.isSome, ~message="should throw on missing row").toBe(true)
    t.expect(
      message->String.includes("incompatible") && message->String.includes("envio version"),
      ~message="reuses incompat error wording with version-mismatch bullet",
    ).toBe(true)
    t.expect(
      storageMock.resumeInitialStateCalls->Array.length,
      ~message="must not reach resumeInitialState",
    ).toBe(0)
  })

  Async.it("Throws on resume when stored envio_info diverges from the current config", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "evm": {}}`)
    let current = JSON.parseOrThrow(`{"name": "new", "evm": {}}`)
    let (raised, message, storageMock) = await resumeWithDifferentConfig(~stored, ~current)
    t.expect(raised->Option.isSome, ~message="should throw").toBe(true)
    t.expect(message->String.includes("incompatible"), ~message="error wording").toBe(true)
    t.expect(message->String.includes("name"), ~message="names the diverged path").toBe(true)
    t.expect(
      storageMock.resumeInitialStateCalls->Array.length,
      ~message="compat check fails before resumeInitialState",
    ).toBe(0)
  })

  Async.it("Throws naming chains.<id> when a new chain is added", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let (raised, message, _) = await resumeWithDifferentConfig(~stored, ~current)
    t.expect(raised->Option.isSome, ~message="should throw on chain add").toBe(true)
    t.expect(
      message->String.includes("evm.chains.10"),
      ~message="error names the new chain key",
    ).toBe(true)
  })

  Async.it("Throws naming chains.<id> when an existing chain is removed", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let (raised, message, _) = await resumeWithDifferentConfig(~stored, ~current)
    t.expect(raised->Option.isSome, ~message="should throw on chain remove").toBe(true)
    t.expect(
      message->String.includes("evm.chains.10"),
      ~message="error names the removed chain key",
    ).toBe(true)
  })

  Async.it("Does NOT throw when only RPC or hypersync options change", async t => {
    // Both sides go through stripSensitiveData first, mimicking what
    // `Main.getEnvioInfo` does on every Persistence.init call.
    let stored = Config.stripSensitiveData(
      JSON.parseOrThrow(`{
        "evm": {"chains": {"1": {
          "id": 1,
          "hypersync": "https://eth.hypersync.xyz",
          "rpcs": [{"url": "u-old", "for": "fallback", "pollingInterval": 1000}]
        }}}
      }`),
    )
    let current = Config.stripSensitiveData(
      JSON.parseOrThrow(`{
        "evm": {"chains": {"1": {
          "id": 1,
          "rpcs": [{"url": "u-new", "for": "sync", "pollingInterval": 5000}]
        }}}
      }`),
    )
    let (raised, _message, storageMock) = await resumeWithDifferentConfig(~stored, ~current)
    t.expect(raised, ~message="rpc/hypersync edits should not throw").toEqual(None)
    t.expect(
      storageMock.resumeInitialStateCalls->Array.length,
      ~message="resumeInitialState runs once when compat passes",
    ).toBe(1)
  })
})
