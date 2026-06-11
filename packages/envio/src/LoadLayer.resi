let loadById: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~entityId: string,
) => promise<option<Internal.entity>>

let loadByFilter: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~filter: EntityFilter.t,
) => promise<array<Internal.entity>>

let loadEffect: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
) => promise<Internal.effectOutput>
