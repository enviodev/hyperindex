// Which ids of one entity, in one chain scope, storage could hold — so a get by
// an id it can't hold skips the round trip. And, per String field a getWhere
// has filtered on, which values storage could hold, so a getWhere naming only
// values it can't skips its round trip too.
//
// A filter is a superset of what storage holds only once seeded with what
// storage held when it was created: everything since passes through `add`,
// since every row this process writes is set in an in-memory table first.
// Until then it answers nothing. The id filter is created with the indexer;
// a field's on the first getWhere filtering on it, seeded from the in-memory
// table as well, since rows set before it existed may not be written yet.
// Both outlive the in-memory tables (a rollback replaces them, once the
// writes in flight are flushed), so no set is ever missed. Deletes and
// overwritten values leave their bits behind, which only costs a query.

type seeding = Unseeded | Seeding | Seeded

type filter = {bloom: BloomFilter.t, mutable seeding: seeding}

type t = {
  ids: filter,
  fields: dict<filter>,
  // Lets a set skip the field walk when no getWhere has created a filter.
  mutable hasFields: bool,
}

let makeFilter = () => {bloom: BloomFilter.make(), seeding: Unseeded}

let make = () => {ids: makeFilter(), fields: Dict.make(), hasFields: false}

// A clean run's tables start empty, so there is nothing to seed from.
let markSeeded = (self: t) => self.ids.seeding = Seeded

let isKnownAbsent = (filter: filter, key: string) =>
  filter.seeding === Seeded && !(filter.bloom->BloomFilter.mightContain(key))

let add = (self: t, ~id: string, ~entity: Internal.entity) => {
  self.ids.bloom->BloomFilter.add(id)
  if self.hasFields {
    let row = entity->(Utils.magic: Internal.entity => dict<Nullable.t<string>>)
    self.fields->Utils.Dict.forEachWithKey((filter, fieldName) =>
      switch row->Utils.Dict.dangerouslyGetNonOption(fieldName)->Option.flatMap(Nullable.toOption) {
      | Some(value) => filter.bloom->BloomFilter.add(value)
      | None => ()
      }
    )
  }
}

let fieldFilter = (self: t, ~fieldName) =>
  self.fields->Utils.Dict.dangerouslyGetNonOption(fieldName)

let addFieldFilter = (self: t, ~fieldName) => {
  let filter = makeFilter()
  self.fields->Dict.set(fieldName, filter)
  self.hasFields = true
  filter
}

// Starts filling the filter with what storage holds, once. Loads issued
// meanwhile go to storage as they would without a filter.
let seedOnce = (filter: filter, ~seed: BloomFilter.t => promise<unit>, ~onError) =>
  switch filter.seeding {
  | Unseeded =>
    filter.seeding = Seeding
    seed(filter.bloom)
    ->Promise.thenResolve(() => filter.seeding = Seeded)
    ->Promise.catch(exn => {
      // Left seeding forever: the filter stays one that never answers.
      onError(exn)
      Promise.resolve()
    })
    ->ignore
  | Seeding | Seeded => ()
  }
