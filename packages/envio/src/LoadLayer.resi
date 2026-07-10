let loadById: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~ecosystem: Ecosystem.t,
  ~entityId: string,
) => promise<option<Internal.entity>>

let loadByFilter: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~ecosystem: Ecosystem.t,
  ~filter: EntityFilter.t,
) => promise<array<Internal.entity>>

let loadEffect: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~ecosystem: Ecosystem.t,
) => promise<Internal.effectOutput>
