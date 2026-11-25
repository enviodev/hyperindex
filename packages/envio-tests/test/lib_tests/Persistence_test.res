open Vitest

let resetCmd = "envio dev -r"
let runCmd = Some("envio dev")

let freshState: Persistence.initialState = {
  cleanRun: true,
  contractMapping: ContractMapping.empty,
  chains: [],
  cache: Dict.make(),
  reorgCheckpoints: [],
  checkpointFrontier: Frontier.empty(),
}

let prepareEmpty = (storage, ~reset=?) =>
  storage->Persistence.prepare(
    ~logger=Logger.makeInMemory(),
    ~reset?,
    ~chainConfigs=[],
    ~contractMapping=ContractMapping.empty,
    ~envioInfo=JSON.Encode.object(Dict.make()),
    ~resetCommand=resetCmd,
    ~runCommand=runCmd,
  )

describe("Persistence.prepare", () => {
  Async.it("Builds a storage holding nothing, and a reset builds it over again", async t => {
    let storageMock = MockStorage.make([#holding, #initialize])

    let created = storageMock.storage->prepareEmpty
    storageMock.resolveHolding(Nothing)
    // Resolving "latest" start blocks (a no-op here, chainConfigs is empty)
    // runs between the holding check and the storage.initialize call; drain
    // the microtask queue rather than counting its awaits.
    await Utils.delay(0)
    storageMock.resolveInitialize(freshState)
    let first = await created

    let recreated = storageMock.storage->prepareEmpty(~reset=true)
    await Utils.delay(0)
    storageMock.resolveInitialize(freshState)
    let second = await recreated

    t.expect(
      (first, second, storageMock.holdingCalls->Array.length, storageMock.initializeCalls),
      ~message="A reset builds without asking what the storage holds",
    ).toEqual((
      Persistence.Created(freshState),
      Persistence.Created(freshState),
      1,
      [
        {"chainConfigs": [], "envioInfo": JSON.Encode.object(Dict.make())},
        {"chainConfigs": [], "envioInfo": JSON.Encode.object(Dict.make())},
      ],
    ))
  })

  // Resolving a `latest` start block waits on the chain's RPC for as long as it
  // takes to answer, and another indexer can set the storage up meanwhile.
  Async.it("Refuses storage another indexer set up while a start block resolved", async t => {
    let storageMock = MockStorage.make([#holding, #initialize])
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
      storageMock.storage->Persistence.prepare(
        ~logger=Logger.makeInMemory(),
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
    | _ => None
    | exception JsExn(error) => error->JsExn.message
    }

    t.expect((refusal, storageMock.initializeCalls->Array.length)).toEqual((
      Some(Config.setUpMeanwhileMessage),
      0,
    ))
  })

  // Resuming trims ClickHouse past what Postgres committed, so a storage found
  // in use is left for the process that indexes its chains to resume.
  Async.it("Builds nothing over a storage it finds, and resumes none of it", async t => {
    // The stored snapshot matches the running one, so the compat gate no-ops.
    // A resume would throw: the mock leaves it unimplemented.
    let storageMock = MockStorage.make([#holding, #readStoredConfig])

    let prepared = storageMock.storage->prepareEmpty
    storageMock.resolveHolding(Initialized)

    t.expect((await prepared, storageMock.initializeCalls->Array.length)).toEqual((
      Persistence.Existing({contractMapping: ContractMapping.empty}),
      0,
    ))
  })

  // Prepare against a storage holding `~storedEnvioInfo`, then capture whatever
  // it throws.
  let resumeWith = async (
    ~storedEnvioInfo: option<JSON.t>,
    ~current: JSON.t,
    ~resetCommand=resetCmd,
    ~runCommand=runCmd,
    ~backfillAddedEventsCommand=?,
  ) => {
    let storageMock = MockStorage.make(
      [#holding, #readStoredConfig],
      ~stored={
        envioInfo: storedEnvioInfo,
        chains: [],
        contractMapping: ContractMapping.empty,
        addedEventsChainIds: [],
      },
    )
    // Attach before resolving the mock: an incompatible config rejects this
    // promise, and an unattached rejection would surface as unhandled.
    let settled = (
      async () =>
        switch await storageMock.storage->Persistence.prepare(
          ~logger=Logger.makeInMemory(),
          ~chainConfigs=[],
          ~contractMapping=ContractMapping.empty,
          ~envioInfo=current,
          ~resetCommand,
          ~runCommand,
          ~backfillAddedEventsCommand?,
        ) {
        | _ => None
        | exception exn => Some(exn)
        }
    )()
    storageMock.resolveHolding(Initialized)

    let raised = await settled
    let message = switch raised {
    | Some(JsExn(e)) => e->JsExn.message->Option.getOr("")
    | _ => ""
    }
    (raised, message, storageMock)
  }

  // https://github.com/enviodev/hyperindex/issues/1878
  Async.it(
    "Offers --backfill-added-events when added events are the whole of the change",
    async t => {
      let withEvents = events =>
        JSON.parseOrThrow(
          `{"name": "demo", "evm": {"contracts": {"Token": {"abi": [], "events": [${events
            ->Array.map(name => `{"name": "${name}"}`)
            ->Array.join(", ")}]}}}}`,
        )
      let (_, message, _) = await resumeWith(
        ~storedEnvioInfo=Some(withEvents(["Transfer"])),
        ~current=withEvents(["Approval", "Transfer"]),
        ~resetCommand="envio start -r",
        ~runCommand=Some("envio start"),
        ~backfillAddedEventsCommand="envio start --backfill-added-events",
      )
      t.expect(
        message,
      ).toBe(`The following config changes are incompatible with the existing indexer data:

    - evm.contracts.Token.events.Approval

Pick one:
  1. Index only the added events, keeping what's already indexed. Only if their handlers write rows of their own event and read nothing other events write:
       envio start --backfill-added-events
  2. Revert the changes above  # resume indexing where it left off
  3. envio start -r            # delete all indexed data and start over
  4. Run a second indexer alongside this one to keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio start`)
    },
  )

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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
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
  3. Run a second indexer alongside this one to keep both datasets:
       ENVIO_PG_SCHEMA=<new_schema> \\
       ENVIO_CLICKHOUSE_DATABASE=<new_db> \\
       ENVIO_INDEXER_PORT=<new_port> \\
       envio dev`)
  })
})
