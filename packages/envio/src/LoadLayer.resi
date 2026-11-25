let loadById: (
  ~loadManager: LoadManager.t,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~entityId: string,
) => promise<option<Internal.entity>>

let loadByFilter: (
  ~loadManager: LoadManager.t,
  ~entityConfig: Internal.entityConfig,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
  ~filter: dict<dict<unknown>>,
) => promise<array<Internal.entity>>

let loadEffect: (
  ~loadManager: LoadManager.t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~scope: Internal.chainScope,
  ~indexerState: IndexerState.t,
  ~shouldGroup: bool,
) => promise<Internal.effectOutput>
