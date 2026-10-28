// One in-memory table per entity, for a single chain scope. The indexer holds
// the cross-chain partition; each ChainState holds the per-chain one.

type t = dict<InMemoryTable.Entity.t>

let make = (entities: array<Internal.entityConfig>): t => {
  let init = Dict.make()
  entities->Array.forEach(entityConfig => {
    init->Dict.set((entityConfig.name :> string), InMemoryTable.Entity.make())
  })
  init
}

// Fresh tables that keep each entity's existence filter, which has seen every
// set the replaced ones did.
let reset = (self: t): t =>
  self->Dict.mapValues(table => InMemoryTable.Entity.make(~existence=table.existence))

let get = (self: t, ~entityName: string) => {
  switch self->Utils.Dict.dangerouslyGetNonOption(entityName) {
  | Some(table) => table
  | None =>
    JsError.throwWithMessage(`Unexpected, entity InMemoryTable is undefined for ${entityName}`)
  }
}

// Entities whose rows are shared by every chain, so their tables live on the
// indexer rather than on a ChainState.
let crossChain = (entities: array<Internal.entityConfig>) =>
  entities->Array.filter((entityConfig: Internal.entityConfig) => entityConfig.crossChain)

let perChain = (entities: array<Internal.entityConfig>) =>
  entities->Array.filter((entityConfig: Internal.entityConfig) => !entityConfig.crossChain)
