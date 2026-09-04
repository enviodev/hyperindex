let config = TestConfig.default

// The store requires a persistence even when the cycle never runs; reuse one.
// Lazy so importing the helper doesn't open a pg client for tests that never use
// it. Its schema is never created — a query through this persistence means a
// test is wired wrong, and pointing it at a real schema would hide that.
let defaultPersistenceRef = ref(None)
let defaultPersistence = (~config=config) =>
  switch defaultPersistenceRef.contents {
  | Some((memoizedConfig, persistence)) if memoizedConfig === config => persistence
  | _ =>
    let persistence = PgStorage.makePersistenceFromConfig(
      ~config,
      ~storage=PgStorage.makeStorageFromEnv(
        ~config,
        ~sql=PgStorage.makeClient(),
        ~pgSchema=TestPgSchema.make(),
        ~isHasuraEnabled=false,
      ),
    )
    defaultPersistenceRef := Some((config, persistence))
    persistence
  }

// A persistence over `storage` that reports itself already initialized, so the
// state writes through it instead of stalling on the init handshake.
let readyPersistence = (~config=config, ~storage) => {
  ...PgStorage.makePersistenceFromConfig(~config, ~storage),
  storageStatus: Persistence.Ready({
    cleanRun: false,
    contractMapping: config.contractMapping,
    envioInfo: Some(JSON.Encode.object(Dict.make())),
    cache: Dict.make(),
    chains: [],
    reorgCheckpoints: [],
    checkpointId: 0n,
  }),
}

let setEntity = (
  indexerState,
  ~entityConfig: Internal.entityConfig,
  ~scope=Internal.CrossChain,
  entity,
) => {
  let inMemTable = indexerState->InMemoryStore.getInMemTable(~entityConfig, ~scope)
  let entity = entity->(Utils.magic: 'a => Internal.entity)
  inMemTable->InMemoryTable.Entity.set(
    ~committedCheckpointId=indexerState->IndexerState.committedCheckpointId,
    Set({
      entityId: (entity: Internal.entity).id->EntityId.unsafeOfString,
      checkpointId: 0n,
      entity,
    }),
  )
}

let make = (~config=config, ~persistence=?, ~entities=[]) => {
  let indexerState = IndexerState.make(
    ~config,
    ~persistence=switch persistence {
    | Some(persistence) => persistence
    | None => defaultPersistence(~config)
    },
    // A trivial chain state map for store-only tests that never run the loop.
    ~chainStates=Dict.make(),
    ~isInReorgThreshold=false,
    ~isRealtime=false,
    // The cycle never runs here, so a write only means a test is wired wrong.
    ~onError=errHandler => errHandler->ErrorHandling.raiseExn,
  )
  entities->Array.forEach(((entityConfig, items)) => {
    items->Array.forEach(entity => {
      indexerState->setEntity(~entityConfig, entity)
    })
  })
  indexerState
}
