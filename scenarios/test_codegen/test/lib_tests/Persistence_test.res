open Vitest

let resetCmd = "envio dev -r"

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
    let p =
      persistence->Persistence.init(~chainConfigs=[], ~envioInfo, ~resetCommand=resetCmd)

    t.expect(
      storageMock.isInitializedCalls,
      ~message=`Should check whether storage is initialized`,
    ).toEqual([true])
    t.expect(
      storageMock.initializeCalls,
      ~message=`Shouldn't call initialize before init check`,
    ).toEqual([])

    storageMock.resolveIsInitialized(false)
    // Two microtask flushes: one for the inner isInitialized promise, one
    // for the Promise.all wrapper that fans out across all storages.
    let _ = await Promise.resolve()
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
      envioInfo: Some(envioInfo),
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

    await persistence->Persistence.init(~chainConfigs=[], ~envioInfo, ~resetCommand=resetCmd)
    t.expect(
      (
        storageMock.isInitializedCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Calling init the second time shouldn't do anything`,
    ).toEqual((1, 1, 0))

    let _p2 =
      persistence->Persistence.init(
        ~reset=true,
        ~chainConfigs=[],
        ~envioInfo,
        ~resetCommand=resetCmd,
      )
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

    let p =
      persistence->Persistence.init(~chainConfigs=[], ~envioInfo, ~resetCommand=resetCmd)
    // Additional calls to init should not do anything
    let _ =
      persistence->Persistence.init(~chainConfigs=[], ~envioInfo, ~resetCommand=resetCmd)
    let _ =
      persistence->Persistence.init(~chainConfigs=[], ~envioInfo, ~resetCommand=resetCmd)

    storageMock.resolveIsInitialized(true)
    // Two flushes — Persistence fans out via Promise.all over storages,
    // adding a microtask hop before resumeInitialState gets called.
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()

    let initialState: Persistence.initialState = {
      cleanRun: false,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointId: 0n,
      // Compat check sees a stored value matching the running one → no-op.
      envioInfo: Some(envioInfo),
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

  // Drive a single resume against a mock that returns `~storedEnvioInfo` from
  // resumeInitialState, then capture whatever Persistence.init throws.
  let resumeWith = async (~storedEnvioInfo: option<JSON.t>, ~current: JSON.t) => {
    let storageMock = MockIndexer.Storage.make([#isInitialized, #resumeInitialState])
    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    let resumePromise =
      persistence->Persistence.init(
        ~chainConfigs=[],
        ~envioInfo=current,
        ~resetCommand=resetCmd,
      )
    storageMock.resolveIsInitialized(true)
    // Two flushes — same Promise.all microtask hop as above.
    let _ = await Promise.resolve()
    let _ = await Promise.resolve()
    let initialState: Persistence.initialState = {
      cleanRun: false,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointId: 0n,
      envioInfo: storedEnvioInfo,
    }
    storageMock.resolveLoadInitialState(initialState)

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

  Async.it("Throws version-mismatch incompat error when envio_info is missing", async t => {
    let (_, message, _) = await resumeWith(
      ~storedEnvioInfo=None,
      ~current=JSON.parseOrThrow(`{"name": "demo"}`),
    )
    t.expect(message, ~message="full incompat message with missing-info bullet").toBe(
      `The following config changes are incompatible with the existing indexer data:

    - envio info is missing — storage initialized by an older envio

Pick one:

  1. Revert the changes above    # resume indexing where it left off
  2. envio dev -r                # wipe the database and re-index from scratch`,
    )
  })

  Async.it("Throws on resume when stored envio_info diverges from the current config", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "evm": {}}`)
    let current = JSON.parseOrThrow(`{"name": "new", "evm": {}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="full incompat message naming the diverged path").toBe(
      `The following config changes are incompatible with the existing indexer data:

    - name

Pick one:

  1. Revert the changes above    # resume indexing where it left off
  2. envio dev -r                # wipe the database and re-index from scratch`,
    )
  })

  Async.it("Throws naming chains.<id> when a new chain is added", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="full incompat message naming the new chain key").toBe(
      `The following config changes are incompatible with the existing indexer data:

    - evm.chains.10

Pick one:

  1. Revert the changes above    # resume indexing where it left off
  2. envio dev -r                # wipe the database and re-index from scratch`,
    )
  })

  Async.it("Throws naming chains.<id> when an existing chain is removed", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="full incompat message naming the removed chain key").toBe(
      `The following config changes are incompatible with the existing indexer data:

    - evm.chains.10

Pick one:

  1. Revert the changes above    # resume indexing where it left off
  2. envio dev -r                # wipe the database and re-index from scratch`,
    )
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
    let (raised, _message, storageMock) = await resumeWith(
      ~storedEnvioInfo=Some(stored),
      ~current,
    )
    t.expect(
      (raised, storageMock.resumeInitialStateCalls->Array.length),
      ~message="rpc/hypersync edits should not throw and resumeInitialState runs once",
    ).toEqual((None, 1))
  })
})
