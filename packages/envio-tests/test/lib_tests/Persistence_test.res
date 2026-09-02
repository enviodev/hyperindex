open Vitest

let resetCmd = "envio dev -r"
let runCmd = Some("envio dev")

describe("Test Persistence layer init", () => {
  Async.it("Should initialize the persistence layer without the user entities", async t => {
    let storageMock = MockStorage.make([#isInitialized, #resumeInitialState, #initialize])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    t.expect(
      persistence.allEntities,
      ~message=`The indexer's own tables aren't entities, so the user's list is untouched`,
    ).toEqual([])
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
      persistence->Persistence.init(
        ~chainConfigs=[],
        ~contractMapping=ContractMapping.empty,
        ~envioInfo,
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
      )

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
      contractMapping: ContractMapping.empty,
      envioInfo: Some(envioInfo),
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

    await persistence->Persistence.init(
      ~chainConfigs=[],
      ~contractMapping=ContractMapping.empty,
      ~envioInfo,
      ~resetCommand=resetCmd,
      ~runCommand=runCmd,
    )
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
        ~contractMapping=ContractMapping.empty,
        ~envioInfo,
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
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
    let envioInfo = JSON.Encode.object(Dict.make())
    // The stored snapshot matches the running one, so the compat gate no-ops.
    let storageMock = MockStorage.make([#isInitialized, #resumeInitialState])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    let p =
      persistence->Persistence.init(
        ~chainConfigs=[],
        ~contractMapping=ContractMapping.empty,
        ~envioInfo,
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
      )
    // Additional calls to init should not do anything
    let _ =
      persistence->Persistence.init(
        ~chainConfigs=[],
        ~contractMapping=ContractMapping.empty,
        ~envioInfo,
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
      )
    let _ =
      persistence->Persistence.init(
        ~chainConfigs=[],
        ~contractMapping=ContractMapping.empty,
        ~envioInfo,
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
      )

    storageMock.resolveIsInitialized(true)
    // Let resumeInitialState register its resolver.
    await Utils.delay(0)

    let initialState: Persistence.initialState = {
      cleanRun: false,
      contractMapping: ContractMapping.empty,
      envioInfo: Some(envioInfo),
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

  // Drive a single resume whose payload carries `~storedEnvioInfo`, then
  // capture whatever Persistence.init throws.
  // The message a resume against `~storedEnvioInfo` fails with under the
  // current config, or `None` when it is allowed through.
  let resumeWith = (
    ~storedEnvioInfo: option<JSON.t>,
    ~current: JSON.t,
    ~resetCommand=resetCmd,
    ~runCommand=runCmd,
    ~hasClickhouse=false,
  ) =>
    try {
      Config.throwIfResumeIncompatible(
        ~storedEnvioInfo,
        ~storedContractMapping=ContractMapping.empty,
        ~envioInfo=current,
        ~contractMapping=ContractMapping.empty,
        ~resetCommand,
        ~runCommand,
        ~hasClickhouse,
      )
      None
    } catch {
    | JsExn(e) => Some(e->JsExn.message->Option.getOr(""))
    }

  Async.it(
    "Throws version-mismatch incompat error when the stored config is unreadable",
    async t => {
      let message = resumeWith(
        ~storedEnvioInfo=None,
        ~current=JSON.parseOrThrow(`{"name": "demo"}`),
      )
      t.expect(message, ~message="full incompat message with older-version bullet").toEqual(
        Some(`The following config changes are incompatible with the existing indexer data:

    - storage was initialized by an older envio version

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
      )
    },
  )

  Async.it("Throws on resume when stored envio_info diverges from the current config", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "evm": {}}`)
    let current = JSON.parseOrThrow(`{"name": "new", "evm": {}}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="full incompat message naming the diverged path").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it("Throws naming chains.<id> when a new chain is added", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="full incompat message naming the new chain key").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.10

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it("Throws naming chains.<id> when an existing chain is removed", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="full incompat message naming the removed chain key").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.10

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it("Priority: name+entities diff → only name bullet shown", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "entities": [{"name": "A"}]}`)
    let current = JSON.parseOrThrow(`{"name": "new", "entities": [{"name": "B"}]}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="entities tier suppressed when name differs").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it("Priority: storage+evm diff → only storage bullets shown", async t => {
    let stored = JSON.parseOrThrow(`{"storage": {"a": 1}, "evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"storage": {"a": 2}, "evm": {"chains": {"1": {"id": 2}}}}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="evm tier suppressed when storage differs").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - storage.a

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it("Priority: evm+entities diff → only evm bullets shown", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}, "entities": [{"name": "A"}]}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 2}}}, "entities": [{"name": "B"}]}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(message, ~message="entities tier suppressed when evm differs").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.1.id

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it(
    "Priority: version bump with otherwise disjoint shape → only version bullet shown",
    async t => {
      let stored = JSON.parseOrThrow(`{
        "version": "1.0",
        "name": "old",
        "storage": {"a": 1},
        "evm": {"chains": {"1": {"id": 1}}},
        "entities": [{"name": "A"}]
      }`)
      let current = JSON.parseOrThrow(`{
        "version": "2.0",
        "name": "new",
        "storage": {"b": 2},
        "fuel": {"chains": {"1": {"id": 1}}},
        "entities": [{"name": "B"}, {"name": "C"}]
      }`)
      let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
      t.expect(
        message,
        ~message="lower tiers (name/storage/ecosystem/entities) suppressed by version diff",
      ).toEqual(
        Some(`The following config changes are incompatible with the existing indexer data:

    - version

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
      )
    },
  )

  Async.it("Fallback: unknown top-level keys are rendered when no known tier differs", async t => {
    let stored = JSON.parseOrThrow(`{"name": "x", "customA": 1, "customB": {"k": 1}}`)
    let current = JSON.parseOrThrow(`{"name": "x", "customA": 2, "customB": {"k": 2}}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="extras fallback lists unknown top-level keys in sorted order",
    ).toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - customA
    - customB.k

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
    )
  })

  Async.it("Migrate flow: option 3 hidden, option 2 shows db-migrate setup", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old"}`)
    let current = JSON.parseOrThrow(`{"name": "new"}`)
    let message = resumeWith(
      ~storedEnvioInfo=Some(stored),
      ~current,
      ~resetCommand="envio local db-migrate setup",
      ~runCommand=None,
    )
    t.expect(message, ~message="migrate context: no option 3, option 2 is setup command").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above      # resume indexing where it left off
  2. envio local db-migrate setup  # delete all indexed data and start over`),
    )
  })

  Async.it("Clickhouse: option 3 includes ENVIO_CLICKHOUSE_DATABASE line", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old"}`)
    let current = JSON.parseOrThrow(`{"name": "new"}`)
    let message = resumeWith(~storedEnvioInfo=Some(stored), ~current, ~hasClickhouse=true)
    t.expect(message, ~message="clickhouse env var line shown when storage.clickhouse set").toEqual(
      Some(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`),
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
    t.expect(
      resumeWith(~storedEnvioInfo=Some(stored), ~current),
      ~message="rpc/hypersync edits should not throw",
    ).toEqual(None)
  })
})
