let loadById: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
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
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~ecosystem: Ecosystem.t,
  ~filter: dict<dict<unknown>>,
) => promise<array<Internal.entity>>

let loadByParsedFilter: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~ecosystem: Ecosystem.t,
  ~filter: EntityFilter.t,
) => promise<array<Internal.entity>>

// What a get or getWhere answers without a load, or None when it would need
// one. The sync context reads through these and suspends on None.
let getByIdInMemory: (
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~entityId: string,
) => option<option<Internal.entity>>

let getByFilterInMemory: (
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~filter: EntityFilter.t,
) => option<array<Internal.entity>>

let loadEffect: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~item: Internal.item,
  ~ecosystem: Ecosystem.t,
) => promise<Internal.effectOutput>
