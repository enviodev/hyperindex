open Vitest

let resetCmd = "envio dev -r"
let runCmd = Some("envio dev")

describe("Test Persistence layer init", () => {
  Async.it("Should initialize the persistence layer without the user entities", async t => {
    let storageMock = MockStorage.make([#holding, #resumeInitialState, #initialize])

    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)

    t.expect(
      persistence.allEntities,
      ~message=`The indexer's own tables aren't entities, so the user's list is untouched`,
    ).toEqual([])
    t.expect(persistence.storageStatus, ~message=`Intial storage status should be unknown`).toEqual(
      Persistence.Unknown,
    )

    t.expect(storageMock.holdingCalls, ~message=`Storage should not be initialized`).toEqual([])
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
      storageMock.holdingCalls,
      ~message=`Should check whether storage is initialized`,
    ).toEqual([true])
    t.expect(
      storageMock.initializeCalls,
      ~message=`Shouldn't call initialize before init check`,
    ).toEqual([])

    storageMock.resolveHolding(Nothing)
    let _ = await Promise.resolve()

    t.expect(
      switch persistence.storageStatus {
      | Persistence.Initializing(_) => true
      | _ => false
      },
      ~message=`Storage status should be initializing`,
    ).toEqual(true)

    // Resolving "latest" start blocks (a no-op here, chainConfigs is empty)
    // runs between the holding check and the storage.initialize call;
    // drain the microtask queue rather than counting its awaits.
    await Utils.delay(0)

    t.expect(
      (
        storageMock.holdingCalls->Array.length,
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
        storageMock.holdingCalls->Array.length,
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
        storageMock.holdingCalls->Array.length,
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

  // Resolving a `latest` start block waits on the chain's RPC for as long as it
  // takes to answer, and another indexer can set the storage up meanwhile.
  Async.it("Refuses storage another indexer set up while a start block resolved", async t => {
    let storageMock = MockStorage.make([#holding, #initialize])
    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    let config = Scenario.make(
      ~configYaml=`
name: set-up-meanwhile
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: latest
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
    ).config->Scenario.withMockSources(
      ~sources=[(1, MockSource.make(Scenario.defaultMethods, ~chainId=1, ~autoHeight=500))],
    )

    let initialized =
      persistence->Persistence.init(
        ~chainConfigs=config.chainMap->ChainMap.values,
        ~contractMapping=ContractMapping.empty,
        ~envioInfo=JSON.Encode.object(Dict.make()),
        ~resetCommand=resetCmd,
        ~runCommand=runCmd,
      )
    storageMock.resolveHolding(Nothing)
    await Scenario.waitUntil(
      () => storageMock.holdingCalls->Array.length === 2,
      ~message="the storage to be checked again",
    )
    storageMock.resolveHolding(Stranded)
    let refusal = switch await initialized {
    | () => None
    | exception JsExn(error) => error->JsExn.message
    }

    t.expect((refusal, storageMock.initializeCalls->Array.length)).toEqual((
      Some(Config.setUpMeanwhileMessage),
      0,
    ))
  })

  Async.it("Should skip initialization when storage is already initialized", async t => {
    let envioInfo = JSON.Encode.object(Dict.make())
    // The stored snapshot matches the running one, so the compat gate no-ops.
    let storageMock = MockStorage.make([#holding, #readStoredConfig, #resumeInitialState])

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

    storageMock.resolveHolding(Initialized)
    // Let resumeInitialState register its resolver.
    await Utils.delay(0)

    let initialState: Persistence.initialState = {
      cleanRun: false,
      contractMapping: ContractMapping.empty,
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
        storageMock.holdingCalls->Array.length,
        storageMock.initializeCalls->Array.length,
        storageMock.resumeInitialStateCalls->Array.length,
      ),
      ~message=`Storage should be already initialized without additional initialize calls.
Although it should load effect caches metadata.`,
    ).toEqual((1, 0, 1))
  })

  // Drive a single resume against a storage holding `~storedEnvioInfo`, then
  // capture whatever Persistence.init throws.
  let resumeWith = async (
    ~storedEnvioInfo: option<JSON.t>,
    ~current: JSON.t,
    ~resetCommand=resetCmd,
    ~runCommand=runCmd,
  ) => {
    let storageMock = MockStorage.make(
      [#holding, #readStoredConfig, #resumeInitialState],
      ~stored={envioInfo: storedEnvioInfo, chains: [], contractMapping: ContractMapping.empty},
    )
    let persistence = Persistence.make(~userEntities=[], ~allEnums=[], ~storage=storageMock.storage)
    // Attach before resolving the mock: an incompatible config rejects this
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
    storageMock.resolveHolding(Initialized)
    await Utils.delay(0)
    let initialState: Persistence.initialState = {
      cleanRun: false,
      contractMapping: ContractMapping.empty,
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
    let stored = JSON.parseOrThrow(`{"evm": {"addressFormat": "checksum"}, "entities": [{"name": "A"}]}`)
    let current = JSON.parseOrThrow(`{"evm": {"addressFormat": "lowercase"}, "entities": [{"name": "B"}]}`)
    let (_, message, _) = await resumeWith(~storedEnvioInfo=Some(stored), ~current)
    t.expect(
      message,
      ~message="entities tier suppressed when evm differs",
    ).toBe(`The following config changes are incompatible with the existing indexer data:

    - evm.addressFormat

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
})
