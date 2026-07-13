// In-memory entity tables keyed by entity name. Extracted so both IndexerState
// (cross-chain entities) and ChainState (per-chain isolated entities) can hold
// them without a circular module dependency.
type t = dict<InMemoryTable.Entity.t>

exception UndefinedEntity({entityName: string})

let make = (entities: array<Internal.entityConfig>): t => {
  let init = Dict.make()
  entities->Array.forEach(entityConfig => {
    init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
  })
  init
}

let get = (self: t, ~entityName: string) => {
  switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
  | Some(table) => table
  | None =>
    UndefinedEntity({entityName: entityName})->ErrorHandling.mkLogAndRaise(
      ~msg="Unexpected, entity InMemoryTable is undefined",
    )
  }
}
