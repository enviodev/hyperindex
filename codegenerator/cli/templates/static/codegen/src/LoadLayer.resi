type t

type fieldValue

let make: (
  ~loadEntitiesByIds: (
    array<Types.id>,
    ~entityMod: module(Entities.InternalEntity),
    ~logger: Pino.t=?,
  ) => promise<array<Entities.internalEntity>>,
  ~makeLoadEntitiesByField: (
    ~entityMod: module(Entities.InternalEntity),
  ) => (
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
  ~inMemTable: InMemoryTable.Entity.t<'entity>,
  ~logger: Pino.t,
) => Js.Dict.key => promise<option<'entity>>

let makeWhereEqLoader: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'entity),
  ~inMemTable: InMemoryTable.Entity.t<'entity>,
  ~logger: Pino.t,
  ~fieldName: string,
  ~fieldValueSchema: RescriptSchema.S.t<'fieldValue>,
) => 'fieldValue => promise<array<'entity>>
