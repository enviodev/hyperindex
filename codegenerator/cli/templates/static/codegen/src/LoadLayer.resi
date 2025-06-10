type t

type fieldValue

let make: (
  ~loadEntitiesByIds: (
    array<Types.id>,
    ~entityConfig: Internal.entityConfig,
    ~logger: Pino.t=?,
  ) => promise<array<Internal.entity>>,
  ~loadEntitiesByField: (
    ~operator: TableIndices.Operator.t,
    ~entityConfig: Internal.entityConfig,
    ~fieldName: string,
    ~fieldValue: fieldValue,
    ~fieldValueSchema: S.t<fieldValue>,
    ~logger: Pino.t=?,
  ) => promise<array<Internal.entity>>,
) => t

let makeWithDbConnection: (~persistence: Persistence.t=?) => t

let loadById: (
  t,
  ~entityConfig: Internal.entityConfig,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~eventItem: Internal.eventItem,
  ~entityId: string,
) => promise<option<Internal.entity>>

let loadByField: (
  t,
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
  t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
) => promise<Internal.effectOutput>
