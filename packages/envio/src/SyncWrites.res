// The writes one round of a synchronous handler has made. A round that
// suspends is replayed from the top, so its writes are held here rather than
// applied: the replay has to see the store exactly as the first round did, or a
// read-modify-write lands once per round.

type table = {
  entityConfig: Internal.entityConfig,
  scope: Internal.chainScope,
  changes: dict<Change.t<Internal.entity>>,
}

// A handler runs on one chain, so an entity's scope is fixed for the whole
// round and the entity name is enough to key its table.
type t = dict<table>

let make = (): t => Dict.make()

let record = (writes: t, ~entityConfig: Internal.entityConfig, ~scope, change) => {
  let table = switch writes->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) {
  | Some(table) => table
  | None =>
    let table = {entityConfig, scope, changes: Dict.make()}
    writes->Dict.set(entityConfig.name, table)
    table
  }
  table.changes->Dict.set(change->Change.getEntityId->EntityId.toKey, change)
}

let changesOf = (writes: t, ~entityConfig: Internal.entityConfig) =>
  switch writes->Utils.Dict.dangerouslyGetNonOption(entityConfig.name) {
  | Some({changes}) => Some(changes)
  | None => None
  }

// `Some(None)` is a delete this round made: the entity is known not to exist.
let getById = (writes: t, ~entityConfig, ~entityId: string) =>
  switch writes->changesOf(~entityConfig) {
  | Some(changes) =>
    changes
    ->Utils.Dict.dangerouslyGetNonOption(entityId)
    ->Option.map(InMemoryTable.Entity.mapChangeToEntity)
  | None => None
  }

// What the store answered, as it reads once this round's writes land: a row
// the round rewrote is re-tested against the filter, and one it created joins.
let overlayFilter = (
  writes: t,
  entities: array<Internal.entity>,
  ~entityConfig: Internal.entityConfig,
  ~filter: EntityFilter.t,
) =>
  switch writes->changesOf(~entityConfig) {
  | None => entities
  | Some(changes) =>
    let matches = filter->EntityFilter.makeMatcher(~table=entityConfig.table)
    let untouched =
      entities->Array.filter(entity =>
        !(changes->Dict.has(entity->InMemoryTable.Entity.getEntityIdUnsafe))
      )
    let written =
      changes
      ->Dict.valuesToArray
      ->Array.filterMap(change =>
        switch change->InMemoryTable.Entity.mapChangeToEntity {
        | Some(entity) if matches(entity) => Some(entity)
        | _ => None
        }
      )
    untouched->Array.concat(written)
  }

// How a change lands in the in-memory store, whether written directly or
// committed at the end of a round.
let write = (indexerState, ~entityConfig, ~scope, change) =>
  indexerState
  ->InMemoryStore.getInMemTable(~entityConfig, ~scope)
  ->InMemoryTable.Entity.set(
    ~committedCheckpointId=indexerState->IndexerState.committedCheckpointIdFor(~scope),
    change,
  )

let commit = (writes: t, ~indexerState) =>
  writes->Utils.Dict.forEach(({entityConfig, scope, changes}) =>
    changes->Utils.Dict.forEach(change => indexerState->write(~entityConfig, ~scope, change))
  )
