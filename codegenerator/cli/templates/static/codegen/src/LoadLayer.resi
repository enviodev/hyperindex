let loadById: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~eventItem: Internal.eventItem,
  ~entityId: string,
) => promise<option<Internal.entity>>

let loadByField: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~operator: TableIndices.Operator.t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore: InMemoryStore.t,
  ~fieldName: string,
  ~fieldValueSchema: RescriptSchema.S.t<'fieldValue>,
  ~shouldGroup: bool,
  ~eventItem: Internal.eventItem,
  ~fieldValue: 'fieldValue,
) => promise<array<Internal.entity>>

let loadEffect: (
  ~loadManager: LoadManager.t,
  ~persistence: Persistence.t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~eventItem: Internal.eventItem,
) => promise<Internal.effectOutput>
