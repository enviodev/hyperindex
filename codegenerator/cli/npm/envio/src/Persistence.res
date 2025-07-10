// A module for the persistence layer
// This is currently in a WIP state
// but in the future we should make all DB and in-memory state
// interactions to this layer with DI and easy for testing.
// Currently there are quite many code spread across
// DbFunctions, Db, Migrations, InMemoryStore modules which use codegen code directly.

// The type reflects an cache table in the db
// It might be present even if the effect is not used in the application
type cache = {
  // Name of the cache (usuall effect name without "envio_cache_" prefix)
  name: string,
  // Number of rows in the table
  mutable size: int,
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
  loadCaches: unit => promise<array<cache>>,
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
  setCacheOrThrow: 'item. (
    ~name: string,
    ~keys: array<string>,
    ~values: array<'item>,
    ~valueSchema: S.t<'item>,
    ~initialize: bool,
  ) => promise<unit>,
}

exception StorageError({message: string, reason: exn})

type storageStatus =
  | Unknown
  | Initializing(promise<unit>)
  | Ready({cleanRun: bool, caches: dict<cache>})

type t = {
  userEntities: array<Internal.entityConfig>,
  staticTables: array<Table.table>,
  allEntities: array<Internal.entityConfig>,
  allEnums: array<Internal.enumConfig<Internal.enum>>,
  mutable storageStatus: storageStatus,
  storage: storage,
  onStorageInitialize: option<unit => promise<unit>>,
  onTableInitialize: option<{"tableName": string} => promise<unit>>,
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
  ~onTableInitialize=?,
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
    onTableInitialize,
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
          caches: Js.Dict.empty(),
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
        let caches = Js.Dict.empty()
        (await persistence.storage.loadCaches())->Js.Array2.forEach(cache => {
          caches->Js.Dict.set(cache.name, cache)
        })
        persistence.storageStatus = Ready({
          cleanRun: false,
          caches,
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

let setCache = async (persistence, ~keys, ~values, ~valueSchema, ~name) => {
  switch persistence.storageStatus {
  | Unknown
  | Initializing(_) =>
    Js.Exn.raiseError(`Failed to access the indexer storage. The Persistence layer is not initialized.`)
  | Ready({caches}) => {
      let storage = persistence.storage
      let cache = switch caches->Utils.Dict.dangerouslyGetNonOption(name) {
      | Some(cache) => cache
      | None => {
          let c = {name, size: 0}
          caches->Js.Dict.set(name, c)
          c
        }
      }
      let initialize = cache.size === 0
      await storage.setCacheOrThrow(~name, ~keys, ~values, ~valueSchema, ~initialize)
      if initialize {
        switch persistence.onTableInitialize {
        | Some(onTableInitialize) => await onTableInitialize({"tableName": `envio_cache_${name}`})
        | None => ()
        }
      }
      cache.size = cache.size + keys->Js.Array2.length
    }
  }
}
