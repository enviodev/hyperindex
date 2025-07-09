// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

// The type reflects an effect cache table in the db
// It might be present even if the effect is not used in the application
type effectCache = {
  name: string,
  // Number of rows in the table
  mutable size: int,
  // Lazily attached table definition when effect is used in the application
  mutable table: option<Table.table>,
}

type operator = [#">" | #"="]

type storage = {
  // Should return true if we already have persisted data
  // and we can skip initialization
  isInitialized: unit => promise<bool>,
  // Should initialize the storage so we can start interacting with it
  // Eg create connection, schema, tables, etc.
  initialize: (
    ~entities: array<Internal.entityConfig>=?,
    ~generalTables: array<Table.table>=?,
    ~enums: array<Internal.enumConfig<Internal.enum>>=?,
  ) => promise<unit>,
  loadEffectCaches: unit => promise<array<effectCache>>,
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
}

exception StorageError({message: string, reason: exn})

type storageStatus =
  | Unknown
  | Initializing(promise<unit>)
  | Ready({cleanRun: bool, effectCaches: dict<effectCache>})

type t = {
  userEntities: array<Internal.entityConfig>,
  staticTables: array<Table.table>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Internal.enumConfig<Internal.enum>>,
  mutable storageStatus: storageStatus,
  storage: storage,
  onStorageInitialize: option<unit => promise<unit>>,
}

let entityHistoryActionEnumConfig: Internal.enumConfig<EntityHistory.RowAction.t> = {
  name: EntityHistory.RowAction.name,
  variants: EntityHistory.RowAction.variants,
  schema: EntityHistory.RowAction.schema,
  default: SET,
}

let make = (
  ~userEntities,
  ~dcRegistryEntityConfig,
  // TODO: Should only pass userEnums and create internal config in runtime
  ~allEnums,
  ~staticTables,
  ~storage,
  ~onStorageInitialize=?,
) => {
  let allEntities = userEntities->Js.Array2.concat([dcRegistryEntityConfig])
  let allEnums =
    allEnums->Js.Array2.concat([entityHistoryActionEnumConfig->Internal.fromGenericEnumConfig])
  {
    userEntities,
    staticTables,
    allEntities,
    allEnums,
    storageStatus: Unknown,
    storage,
    onStorageInitialize,
  }
}

let init = async (persistence, ~reset=false) => {
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
        let _ = await persistence.storage.initialize(
          ~entities=persistence.allEntities,
          ~generalTables=persistence.staticTables,
          ~enums=persistence.allEnums,
        )

        persistence.storageStatus = Ready({
          cleanRun: true,
          effectCaches: Js.Dict.empty(),
        })
        switch persistence.onStorageInitialize {
        | Some(onStorageInitialize) => await onStorageInitialize()
        | None => ()
        }
      } else if (
        // In case of a race condition,
        // we want to set the initial status to Ready only once.
        switch persistence.storageStatus {
        | Initializing(_) => true
        | _ => false
        }
      ) {
        let effectCaches = Js.Dict.empty()
        (await persistence.storage.loadEffectCaches())->Js.Array2.forEach(effectCache => {
          effectCaches->Js.Dict.set(effectCache.name, effectCache)
        })
        persistence.storageStatus = Ready({
          cleanRun: false,
          effectCaches,
        })
      }
      resolveRef.contents()
    }
  } catch {
  | exn => exn->ErrorHandling.mkLogAndRaise(~msg=`EE800: Failed to initialize the indexer storage.`)
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
