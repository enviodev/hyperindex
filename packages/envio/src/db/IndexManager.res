// Decides what has to happen for a desired index to exist, serialises the work
// so two builds never fight over the same table, and refuses to record an index
// as present until Postgres has been asked again what it actually built.

// A build the catalog doesn't already cover. `isRebuild` means an unusable
// index holds the generated name with exactly our identity, so it can only be
// one of ours — dropped and built again rather than left to block the name.
type prepared = {
  definition: IndexDefinition.t,
  name: string,
  isRebuild: bool,
  queries: array<string>,
}

type t = {
  mutable catalog: IndexCatalog.t,
  // Keyed by index identity and coverage so concurrent identical requests
  // await one build.
  inflight: dict<promise<unit>>,
  // Tail of the build chain per table, so two different indexes on the same
  // table are built one after the other rather than at once.
  tableQueue: dict<promise<unit>>,
}

let make = () => {
  catalog: IndexCatalog.make(),
  inflight: Dict.make(),
  tableQueue: Dict.make(),
}

let reload = (manager, ~rows) => {
  manager.catalog = IndexCatalog.fromRows(~rows)
  manager.catalog
}

let catalog = manager => manager.catalog

let isSatisfied = (manager, definition, ~coverage) =>
  manager.catalog->IndexCatalog.find(definition, ~coverage)->Option.isSome

// The name is derived from a hash of the full identity, so an index holding it
// was generated for this exact identity. Anything else under that name is
// someone else's, and guessing which is worse than stopping.
let conflictError = (~entry: IndexCatalog.entry, ~definition, ~pgSchema) =>
  Utils.Error.make(
    `Cannot create the index "${entry.name}" in schema "${pgSchema}" for ${definition->IndexDefinition.describe}. A different index already holds that name and the indexer can't safely replace it: ${entry
      ->IndexCatalog.rejectReason(definition, ~coverage=IndexCatalog.Exact)
      ->Option.getOr("it is unique")}. Drop that index by hand, then restart the indexer.`,
  )

let verificationError = (~name, ~definition, ~pgSchema, ~reason) =>
  Utils.Error.make(
    `The index "${name}" in schema "${pgSchema}" is not usable after its DDL ran: ${reason}. It was meant to cover ${definition->IndexDefinition.describe}. Drop it by hand, then restart the indexer.`,
  )

// `None` when the catalog already covers the definition. Resolving this before
// any DDL runs means a name held by an unrelated index fails while nothing is
// half-built.
let prepare = (manager, ~definition, ~coverage, ~pgSchema): option<prepared> =>
  switch manager.catalog->IndexCatalog.find(definition, ~coverage) {
  | Some(_) => None
  | None =>
    let name = definition->IndexDefinition.name
    let create = definition->IndexDefinition.makeCreateQuery(~pgSchema)
    switch manager.catalog->IndexCatalog.getByName(name) {
    | None => Some({definition, name, isRebuild: false, queries: [create]})
    | Some(entry) if entry->IndexCatalog.isExactly(definition) =>
      Some({
        definition,
        name,
        isRebuild: true,
        queries: [IndexDefinition.makeDropQuery(~pgSchema, ~indexName=name), create],
      })
    | Some(entry) => throw(conflictError(~entry, ~definition, ~pgSchema))
    }
  }

// The DDL succeeding is not proof the index exists in a form the planner will
// use: a build can leave an index INVALID, and a name we assumed free would
// have made it a no-op. `rows` is a fresh read of that one index from
// pg_catalog — inside the same transaction when there is one, so a failure
// rolls the DDL back with it.
let verifyOrThrow = (prepared, ~rows, ~pgSchema): IndexCatalog.entry => {
  let {definition, name} = prepared
  switch rows->Array.map(IndexCatalog.fromRow)->Array.find(entry => entry.name === name) {
  | None =>
    throw(verificationError(~name, ~definition, ~pgSchema, ~reason="PostgreSQL has no such index"))
  | Some(entry) =>
    // The build is verified against `Exact` whatever the request asked for: we
    // just created this index from the definition, so anything short of a
    // byte-for-byte match means Postgres built something else.
    switch entry->IndexCatalog.rejectReason(definition, ~coverage=IndexCatalog.Exact) {
    | Some(reason) => throw(verificationError(~name, ~definition, ~pgSchema, ~reason))
    | None => entry
    }
  }
}

// Applied only once the DDL is durable — inside a transaction that means after
// the commit, so a rollback can't leave the catalog claiming an index the
// schema doesn't have.
let record = (manager, entry) => manager.catalog->IndexCatalog.set(entry)

// Puts one index back in step with the database. A build that commits its DDL
// and then fails to read it back would otherwise leave the catalog claiming the
// name is free, and every later attempt would replan a create and hit
// "relation already exists" for the rest of the run.
let resync = (manager, ~name, ~rows) =>
  switch rows->Array.map(IndexCatalog.fromRow)->Array.find(entry => entry.name === name) {
  | Some(entry) => manager.catalog->IndexCatalog.set(entry)
  | None => manager.catalog->IndexCatalog.remove(name)
  }

// Runs `build` unless the catalog already covers the definition. Nothing is
// recorded here: `build` owns the verification, so a failed or unverified build
// leaves the manager untouched and the next request retries.
let ensure = (manager, ~definition: IndexDefinition.t, ~coverage, ~build) =>
  if manager->isSatisfied(definition, ~coverage) {
    Promise.resolve()
  } else {
    // Keyed by coverage as well as identity: an `Exact` request joining an
    // in-flight `LeadingColumns` one would resolve as soon as that build
    // decided a leading composite already served it, and the declared index
    // would never be created.
    let key = `${coverage->IndexCatalog.coverageKey}${definition->IndexDefinition.key}`
    switch manager.inflight->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(promise) => promise
    | None =>
      let tail = switch manager.tableQueue->Utils.Dict.dangerouslyGetNonOption(
        definition.tableName,
      ) {
      | Some(tail) => tail
      | None => Promise.resolve()
      }
      let promise = tail
      // The queued build may have been satisfied while waiting behind another
      // one on the same table (eg a finalize pass created it).
      ->Promise.then(() =>
        manager->isSatisfied(definition, ~coverage) ? Promise.resolve() : build()
      )
      manager.inflight->Dict.set(key, promise)
      manager.tableQueue->Dict.set(definition.tableName, promise->Utils.Promise.silentCatch)
      promise->Promise.finally(() => manager.inflight->Utils.Dict.deleteInPlace(key))
    }
  }
