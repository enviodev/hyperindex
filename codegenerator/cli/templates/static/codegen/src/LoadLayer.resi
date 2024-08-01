type t

type fieldValue

let make: (
  ~loadEntitiesByIds: (
    array<Types.id>,
    ~entityMod: module(Entities.InternalEntity),
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

let setInMemoryStore: (t, ~inMemoryStore: InMemoryStore.t) => unit

let makeLoader: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'a),
  ~logger: Pino.t,
) => Js.Dict.key => promise<option<'a>>

let makeWhereEqLoader: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'a),
  ~logger: Pino.t,
  ~fieldName: string,
  ~fieldValueSchema: RescriptSchema.S.t<'b>,
) => 'b => promise<array<'a>>
