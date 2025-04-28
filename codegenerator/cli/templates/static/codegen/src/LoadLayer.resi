type t

type fieldValue

let make: (
  ~loadEntitiesByIds: (
    array<Types.id>,
    ~entityMod: module(Entities.InternalEntity),
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
  ~loadEntitiesByField: (
    ~operator: TableIndices.Operator.t,
    ~entityMod: module(Entities.InternalEntity),
    ~fieldName: string,
    ~fieldValue: fieldValue,
    ~fieldValueSchema: S.t<fieldValue>,
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
) => t

let makeWithDbConnection: unit => t

let loadById: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'entity),
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
  ~eventItem: Internal.eventItem,
  ~entityId: string,
) => promise<option<'entity>>

let loadByField: (
  t,
  ~operator: TableIndices.Operator.t,
  ~entityMod: module(Entities.Entity with type t = 'entity),
  ~inMemoryStore: InMemoryStore.t,
  ~fieldName: string,
  ~fieldValueSchema: RescriptSchema.S.t<'fieldValue>,
  ~shouldGroup: bool,
  ~eventItem: Internal.eventItem,
  ~fieldValue: 'fieldValue,
) => promise<array<'entity>>

let loadEffect: (
  t,
  ~effect: Internal.effect,
  ~effectArgs: Internal.effectArgs,
  ~inMemoryStore: InMemoryStore.t,
  ~shouldGroup: bool,
) => promise<Internal.effectOutput>
