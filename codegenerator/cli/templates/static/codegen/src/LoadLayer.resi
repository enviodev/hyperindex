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

let makeLoader: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'entity),
  ~inMemoryStore: InMemoryStore.t,
  ~logger: Pino.t,
) => string => promise<option<'entity>>

let makeWhereLoader: (
  t,
  ~operator: TableIndices.Operator.t,
  ~entityMod: module(Entities.Entity with type t = 'entity),
  ~inMemoryStore: InMemoryStore.t,
  ~logger: Pino.t,
  ~fieldName: string,
  ~fieldValueSchema: RescriptSchema.S.t<'fieldValue>,
) => 'fieldValue => promise<array<'entity>>
