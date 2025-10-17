// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

// The type reflects an cache table in the db
// It might be present even if the effect is not used in the application
type effectCacheRecord = {
  effectName: string,
  // Number of rows in the table
  mutable count: int,
}

type initialChainState = {
  id: int,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
  progressBlockNumber: int,
  numEventsProcessed: int,
  firstEventBlockNumber: option<int>,
  timestampCaughtUpToHeadOrEndblock: option<Js.Date.t>,
  dynamicContracts: array<Internal.indexingContract>,
}

type initialState = {
  cleanRun: bool,
  cache: dict<effectCacheRecord>,
  chains: array<initialChainState>,
  checkpointId: int,
  // Needed to keep reorg detection logic between restarts
  reorgCheckpoints: array<Internal.reorgCheckpoint>,
}

type operator = [#">" | #"="]

type storage = {
  // Should return true if we already have persisted data
  // and we can skip initialization
  isInitialized: unit => promise<bool>,
  // Should initialize the storage so we can start interacting with it
  // Eg create connection, schema, tables, etc.
  initialize: (
    ~chainConfigs: array<InternalConfig.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Internal.enumConfig<Internal.enum>>=?,
  ) => promise<initialState>,
  resumeInitialState: unit => promise<initialState>,
  @raises("StorageError")
  loadByIdsOrThrow: 'item. (
    ~ids: array<string>,
    ~table: Table.table,
    ~rowsSchema: S.t<array<'item>>,
  ) => promise<array<'item>>,
  @raises("StorageError")
  loadByFieldOrThrow: 'item 'value. (
    ~fieldName: string,
    ~fieldSchema: S.t<'value>,
    ~fieldValue: 'value,
    ~operator: operator,
    ~table: Table.table,
    ~rowsSchema: S.t<array<'item>>,
  ) => promise<array<'item>>,
  @raises("StorageError")
  setOrThrow: 'item. (
    ~items: array<'item>,
    ~table: Table.table,
    ~itemSchema: S.t<'item>,
  ) => promise<unit>,
  @raises("StorageError")
  setEffectCacheOrThrow: (
    ~effect: Internal.effect,
    ~items: array<Internal.effectCacheItem>,
    ~initialize: bool,
  ) => promise<unit>,
  // This is to download cache from the database to .envio/cache
  dumpEffectCache: unit => promise<unit>,
}

exception StorageError({message: string, reason: exn})

type storageStatus =
  | Unknown
  | Initializing(promise<unit>)
  | Ready(initialState)

type t = {
  userEntities: array<Internal.entityConfig>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Internal.enumConfig<Internal.enum>>,
  mutable storageStatus: storageStatus,
  storage: storage,
}

let entityHistoryActionEnumConfig: Internal.enumConfig<EntityHistory.RowAction.t> = {
  name: EntityHistory.RowAction.name,
  variants: EntityHistory.RowAction.variants,
  schema: EntityHistory.RowAction.schema,
  default: SET,
}

let make = (
  ~userEntities,
  // TODO: Should only pass userEnums and create internal config in runtime
  ~allEnums,
  ~storage,
) => {
  let allEntities = userEntities->Js.Array2.concat([InternalTable.DynamicContractRegistry.config])
  let allEnums =
    allEnums->Js.Array2.concat([entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig])
  {
    userEntities,
    allEntities,
    allEnums,
    storageStatus: Unknown,
    storage,
  }
}

let init = {
  async (persistence, ~chainConfigs, ~reset=false) => {
    try {
      let shouldRun = switch persistence.storageStatus {
      | Unknown => true
      | Initializing(promise) => {
          await promise
          reset
        }
      | Ready(_) => reset
      }
      if shouldRun {
        let resolveRef = ref(%raw(`null`))
        let promise = Promise.make((resolve, _) => {
          resolveRef := resolve
        })
        persistence.storageStatus = Initializing(promise)
        if reset || !(await persistence.storage.isInitialized()) {
          Logging.info(`Initializing the indexer storage...`)
          let initialState = await persistence.storage.initialize(
            ~entities=persistence.allEntities,
            ~enums=persistence.allEnums,
            ~chainConfigs,
          )
          Logging.info(`The indexer storage is ready. Starting indexing!`)
          persistence.storageStatus = Ready(initialState)
        } else if (
          // In case of a race condition,
          // we want to set the initial status to Ready only once.
          switch persistence.storageStatus {
          | Initializing(_) => true
          | _ => false
          }
        ) {
          Logging.info(`Found existing indexer storage. Resuming indexing state...`)
          let initialState = await persistence.storage.resumeInitialState()
          persistence.storageStatus = Ready(initialState)
          let progress = Js.Dict.empty()
          initialState.chains->Js.Array2.forEach(c => {
            progress->Utils.Dict.setByInt(c.id, c.progressBlockNumber)
          })
          Logging.info({
            "msg": `Successfully resumed indexing state! Continuing from the last checkpoint.`,
            "progress": progress,
          })
        }
        resolveRef.contents()
      }
    } catch {
    | exn =>
      exn->ErrorHandling.mkLogAndRaise(~msg=`EE800: Failed to initialize the indexer storage.`)
    }
  }
}

let getInitializedStorageOrThrow = persistence => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready(_) => persistence.storage
  }
}

let getInitializedState = persistence => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the initial state. The Persistence layer is not initialized.`)
  | Ready(initialState) => initialState
  }
}

let setEffectCacheOrThrow = async (persistence, ~effect: Internal.effect, ~items) => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({cache}) => {
      let storage = persistence.storage
      let effectName = effect.name
      let effectCacheRecord = switch cache->Utils.Dict.dangerouslyGetNonOption(effectName) {
      | Some(c) => c
      | None => {
          let c = {effectName, count: 0}
          cache->Js.Dict.set(effectName, c)
          c
        }
      }
      let initialize = effectCacheRecord.count === 0
      await storage.setEffectCacheOrThrow(~effect, ~items, ~initialize)
      effectCacheRecord.count = effectCacheRecord.count + items->Js.Array2.length
      Prometheus.EffectCacheCount.set(~count=effectCacheRecord.count, ~effectName)
    }
  }
}
