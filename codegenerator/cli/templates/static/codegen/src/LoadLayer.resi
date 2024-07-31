type t

let make: (
  ~loadEntitiesByIds: (array<Types.id>, ~entityMod: module(Entities.InternalEntity)) => promise<array<Entities.internalEntity>>,
) => t

let setInMemoryStore: (t, ~inMemoryStore: InMemoryStore.t) => unit

let makeLoader: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'a),
) => Js.Dict.key => promise<option<'a>>

let makeWhereEqLoader: (
  t,
  ~entityMod: module(Entities.Entity with type t = 'a),
  ~fieldName: string,
  ~fieldValueSchema: RescriptSchema.S.t<'b>,
  ~logger: Pino.t,
) => 'b => promise<array<'a>>
