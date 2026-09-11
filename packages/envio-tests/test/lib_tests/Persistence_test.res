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

    // Resolving "latest" start blocks (a no-op here, chainConfigs is empty)
    // runs between the isInitialized check and the storage.initialize call;
    // drain the microtask queue rather than counting its awaits.
    await Utils.delay(0)

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
      checkpointFrontier: Frontier.empty(),
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
    // Resolving "latest" start blocks (a no-op here, chainConfigs is empty)
    // runs between the reset check and the storage.initialize call; drain
    // the microtask queue rather than counting its awaits.
    await Utils.delay(0)
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
      checkpointFrontier: Frontier.empty(),
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
  let resumeWith = async (
    ~storedEnvioInfo: option<JSON.t>,
    ~current: JSON.t,
    ~resetCommand=resetCmd,
    ~runCommand=runCmd,
  ) => {
    let storageMock = MockStorage.make([#isInitialized, #resumeInitialState])
    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    // Attach before resolving the mock: throwIfIncompatible rejects this
    // promise, and an unattached rejection would surface as unhandled.
    let settled = (
      async () =>
        switch await persistence->Persistence.init(
          ~chainConfigs=[],
          ~contractMapping=ContractMapping.empty,
          ~envioInfo=current,
          ~resetCommand,
          ~runCommand,
        ) {
        | () => None
        | exception exn => Some(exn)
        }
    )()
    storageMock.resolveIsInitialized(true)
    await Utils.delay(0)
    let initialState: Persistence.initialState = {
      cleanRun: false,
      contractMapping: ContractMapping.empty,
      envioInfo: storedEnvioInfo,
      chains: [],
      cache: Dict.make(),
      reorgCheckpoints: [],
      checkpointFrontier: Frontier.empty(),
    }
    storageMock.resolveLoadInitialState(initialState)

    let raised = await settled
    let message = switch raised {
    | Some(JsExn(e)) => e->JsExn.message->Option.getOr("")
    | _ => ""
    }
    (raised, message, storageMock)
  }

  Async.it(
    "Throws version-mismatch incompat error when the stored config is unreadable",
    async t => {
      let (_, message, _) = await resumeWith(
        ~storedEnvioInfo=None,
        ~current=JSON.parseOrThrow(`{"name": "demo"}`),
      )
      t.expect(
        message,
        ~message="full incompat message with older-version bullet",
      ).toBe(`The following config changes are incompatible with the existing indexer data:

    - storage was initialized by an older envio version

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
    },
  )

  Async.it("Throws on resume when stored envio_info diverges from the current config", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "evm": {}}`)
    let current = JSON.parseOrThrow(`{"name": "new", "evm": {}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="full incompat message naming the diverged path",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Points at db-migrate up when the only change is an added chain", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="the added chain has a repair, so it gets the migrate recipe instead of the reset menu",
    ).toBe(`The config declares chains the indexer database doesn't have yet:

    - evm.chains.10

Pick one:
  1. envio local db-migrate up  # add them to the database, then backfill
  2. Revert the changes above   # resume indexing where it left off
  3. envio dev -r               # delete all indexed data and start over`)
  })

  Async.it("Points at db-migrate up when the added chain brings a new contract", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}, "contracts": {"A": {}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}, "contracts": {"A": {}, "B": {}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="a contract only the new chain can reference is part of the same repair",
    ).toBe(`The config declares chains the indexer database doesn't have yet:

    - evm.chains.10

Pick one:
  1. envio local db-migrate up  # add them to the database, then backfill
  2. Revert the changes above   # resume indexing where it left off
  3. envio dev -r               # delete all indexed data and start over`)
  })

  Async.it("Points at db-migrate up when the snapshot had no contracts map at all", async t => {
    // An onBlock-only project serializes no `contracts` key, so the added
    // chain's first contract diffs as the bare `evm.contracts` path.
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}, "contracts": {"A": {}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="a group the snapshot omitted is as new as one it lists",
    ).toBe(`The config declares chains the indexer database doesn't have yet:

    - evm.chains.10

Pick one:
  1. envio local db-migrate up  # add them to the database, then backfill
  2. Revert the changes above   # resume indexing where it left off
  3. envio dev -r               # delete all indexed data and start over`)
  })

  Async.it("Falls back to the reset menu when an added chain comes with other changes", async t => {
    // The tiered `diffPaths` would render only the ecosystem tier here, hiding
    // the entity change behind the added chain — so the additive check reads the
    // untiered diff, and this stays an incompatible change.
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}, "entities": ["a"]}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}, "entities": ["b"]}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="an entity change alongside the new chain is not something adding a chain repairs",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.10

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Falls back to the reset menu when an existing chain changed too", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1, "startBlock": 1}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1, "startBlock": 5}, "10": {"id": 10, "startBlock": 1}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="chain 1 is already indexed from its old start block, which no migration undoes",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.1.startBlock
    - evm.chains.10

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Throws naming chains.<id> when an existing chain is removed", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}, "10": {"id": 10}}}}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="full incompat message naming the removed chain key",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.10

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Priority: name+entities diff → only name bullet shown", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "entities": [{"name": "A"}]}`)
    let current = JSON.parseOrThrow(`{"name": "new", "entities": [{"name": "B"}]}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="entities tier suppressed when name differs",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Priority: storage+evm diff → only storage bullets shown", async t => {
    let stored = JSON.parseOrThrow(`{"storage": {"a": 1}, "evm": {"chains": {"1": {"id": 1}}}}`)
    let current = JSON.parseOrThrow(`{"storage": {"a": 2}, "evm": {"chains": {"1": {"id": 2}}}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="evm tier suppressed when storage differs",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - storage.a

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Priority: evm+entities diff → only evm bullets shown", async t => {
    let stored = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 1}}}, "entities": [{"name": "A"}]}`)
    let current = JSON.parseOrThrow(`{"evm": {"chains": {"1": {"id": 2}}}, "entities": [{"name": "B"}]}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="entities tier suppressed when evm differs",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - evm.chains.1.id

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
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
      let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
      t.expect(
        message,
        ~message="lower tiers (name/storage/ecosystem/entities) suppressed by version diff",
      ).toBe(`The following config changes are incompatible with the existing indexer data:

    - version

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
    },
  )

  Async.it("Fallback: unknown top-level keys are rendered when no known tier differs", async t => {
    let stored = JSON.parseOrThrow(`{"name": "x", "customA": 1, "customB": {"k": 1}}`)
    let current = JSON.parseOrThrow(`{"name": "x", "customA": 2, "customB": {"k": 2}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="extras fallback lists unknown top-level keys in sorted order",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - customA
    - customB.k

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("Migrate flow: option 3 hidden, option 2 shows db-migrate setup", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old"}`)
    let current = JSON.parseOrThrow(`{"name": "new"}`)
    let (_, message, _) = await resumeWith(
      ~storedEnvioInfo=Some(stored),
      ~current,
      ~resetCommand="envio local db-migrate setup",
      ~runCommand=None,
    )
    t.expect(
      message,
      ~message="migrate context: no option 3, option 2 is setup command",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above      # resume indexing where it left off
  2. envio local db-migrate setup  # delete all indexed data and start over`)
  })

  Async.it("Clickhouse: option 3 includes ENVIO_CLICKHOUSE_DATABASE line", async t => {
    let stored = JSON.parseOrThrow(`{"name": "old", "storage": {"clickhouse": true}}`)
    let current = JSON.parseOrThrow(`{"name": "new", "storage": {"clickhouse": true}}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="clickhouse env var line shown when storage.clickhouse set",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - name

Pick one:
  1. Revert the changes above  # resume indexing where it left off
  2. envio dev -r              # delete all indexed data and start over
  3. Run a second indexer alongside this one — keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })

  Async.it("db-migrate up detects the added chain, migrates it, then re-resumes", async t => {
    let before = TestConfig.multiChain(~chains=[(1, "Gravatar")])
    let after = TestConfig.multiChain(~chains=[(1, "Gravatar"), (137, "Poster")])
    let storageMock = MockStorage.make([#isInitialized, #resumeInitialState, #addChains])
    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    let settled =
      persistence->Persistence.init(
        ~chainConfigs=after.config.chainMap->ChainMap.values,
        ~contractMapping=after.config.contractMapping,
        ~envioInfo=after.envioInfo,
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
        ~addedChainsPolicy=Add,
      )
    storageMock.resolveIsInitialized(true)

    // Resolve each resume as its call lands: the first with what the database
    // holds — a chain behind the config — the second with what the migration
    // left, which the real compatibility check then has to accept.
    let resolveResumeWhenCalled = async (~count, ~snapshot: TestConfig.parsed) => {
      let deadline = Date.now() +. 2000.
      while storageMock.resumeInitialStateCalls->Array.length < count && Date.now() < deadline {
        await Utils.delay(0)
      }
      storageMock.resolveLoadInitialState({
        cleanRun: false,
        contractMapping: snapshot.config.contractMapping,
        envioInfo: Some(snapshot.envioInfo),
        chains: [],
        cache: Dict.make(),
        reorgCheckpoints: [],
        checkpointFrontier: Frontier.empty(),
      })
    }
    await resolveResumeWhenCalled(~count=1, ~snapshot=before)
    await resolveResumeWhenCalled(~count=2, ~snapshot=after)
    await settled

    t.expect({
      "migrated": storageMock.addChainsCalls->Array.map(
        call => call["chainIds"]->Array.map(ChainId.toString),
      ),
      // The second resume is the point: the caller ends up holding what the
      // database says, read back after the migration rather than patched up.
      "resumes": storageMock.resumeInitialStateCalls->Array.length,
      "envioInfo": switch persistence.storageStatus {
      | Ready({envioInfo}) => envioInfo
      | _ => None
      },
    }).toEqual({
      "migrated": [["137"]],
      "resumes": 2,
      "envioInfo": Some(after.envioInfo),
    })
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
    let (raised, _message, storageMock) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      (raised, storageMock.resumeInitialStateCalls->Array.length),
      ~message="rpc/hypersync edits should not throw and resumeInitialState runs once",
    ).toEqual((None, 1))
  })
})
