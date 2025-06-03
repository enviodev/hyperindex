// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

type storage = {
  // Should return true if we already have persisted data
  // and we can skip initialization
  isInitialized: unit => promise<bool>,
  // Should initialize the storage so we can start interacting with it
  // Eg create connection, schema, tables, etc.
  initialize: (
    ~entities: array<Internal.entityConfig>,
    ~staticTables: array<Table.table>,
    ~enums: array<Internal.enumConfig<Internal.enum>>,
    // If true, the storage should clear existing data
    ~reset: bool,
  ) => promise<unit>,
}

type storageStatus =
  | Unknown
  | Initializing(promise<unit>)
  | Ready({cleanRun: bool})

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

let init = async (
  persistence,
  // There are not much sense in the option,
  // but this is how the runUpMigration used to work
  // and we want to keep the upsert behavior without breaking changes.
  ~skipIsInitializedCheck=false,
  ~reset=false,
) => {
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
      if !(reset || skipIsInitializedCheck) && (await persistence.storage.isInitialized()) {
        persistence.storageStatus = Ready({cleanRun: false})
      } else {
        let resolveRef = ref(%raw(`null`))
        let promise = Promise.make((resolve, _) => {
          resolveRef := resolve
        })
        persistence.storageStatus = Initializing(promise)

        let _ = await persistence.storage.initialize(
          ~entities=persistence.allEntities,
          ~staticTables=persistence.staticTables,
          ~enums=persistence.allEnums,
          ~reset=reset || !skipIsInitializedCheck,
        )
        persistence.storageStatus = Ready({cleanRun: true})
        switch persistence.onStorageInitialize {
        | Some(onStorageInitialize) => await onStorageInitialize()
        | None => ()
        }
        resolveRef.contents()
      }
    }
  } catch {
  | exn => exn->ErrorHandling.mkLogAndRaise(~msg=`EE800: Failed to initialize the indexer storage.`)
  }
}
