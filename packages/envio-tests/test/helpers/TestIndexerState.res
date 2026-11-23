let config = TestConfig.default

// The store requires a storage even when the cycle never runs; reuse one.
// Lazy so importing the helper doesn't open a pg client for tests that never use
// it. Its schema is never created — a query through this storage means a test
// is wired wrong, and pointing it at a real schema would hide that.
let defaultStorageRef = ref(None)
let defaultStorage = (~config=config) =>
  switch defaultStorageRef.contents {
  | Some((memoizedConfig, storage)) if memoizedConfig === config => storage
  | _ =>
    let storage = Storage.makeStorageFromEnv(
      ~logger=Logger.makeInMemory(),
      ~config,
      ~pgSchema=TestPgSchema.make(),
      ~isHasuraEnabled=false,
    )
    defaultStorageRef := Some((config, storage))
    storage
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
    ~committedCheckpointId=indexerState->IndexerState.committedCheckpointIdFor(~scope),
    Set({
      entityId: (entity: Internal.entity).id->EntityId.unsafeOfString,
      checkpointId: 0n,
      entity,
    }),
  )
}

let make = (~config=config, ~storage=?, ~entities=[]) => {
  let indexerState = IndexerState.make(
    ~logger=Logger.makeInMemory(),
    ~config,
    ~storage=switch storage {
    | Some(storage) => storage
    | None => defaultStorage(~config)
    },
    // A trivial chain state map for store-only tests that never run the loop.
    ~chainStates=Dict.make(),
    ~isRealtime=false,
    // The cycle never runs here, so a write only means a test is wired wrong.
    ~onError=errHandler => errHandler->ErrorHandling.toExn->throw,
  )
  entities->Array.forEach(((entityConfig, items)) => {
    items->Array.forEach(entity => {
      indexerState->setEntity(~entityConfig, entity)
    })
  })
  indexerState
}
