// The contract name <-> id mapping every stored address row references: a
// name's position in `names` is the id `envio_contracts` holds and
// `envio_addresses.contract_id` points at. Ids must mean the same thing on
// every chain and across restarts, so a mapping is built once — from the whole
// config, never from a filtered subset — and read everywhere else.
type t = {
  // Id order. Index i is the name of contract id i.
  names: array<string>,
  idByName: dict<int>,
}

let indexNames = (names: array<string>): t => {
  let idByName = Dict.make()
  names->Array.forEachWithIndex((name, id) => idByName->Dict.set(name, id))
  {names, idByName}
}

// Ids are 0-based positions in a smallint column, so 32768 contracts fit.
let maxContracts = 32768

// Names in any order; the codec puts them in byte order so the ids never depend
// on the order contracts happen to be declared in.
let make = (~names: array<string>): t => {
  let canonical = Core.getAddon().canonicalContractNames(names)
  if canonical->Array.length > maxContracts {
    JsError.throwWithMessage(
      `The indexer declares ${canonical
        ->Array.length
        ->Int.toString} contracts, more than the ${maxContracts->Int.toString} a smallint contract id can hold.`,
    )
  }
  indexNames(canonical)
}

// What a storage holds before it has been initialized: no contract has an id
// yet, so every lookup fails rather than resolving against a stale mapping.
let empty = indexNames([])

// A mapping read back from storage. Taken verbatim: the stored order *is* the
// id order the stored rows were written against, so re-canonicalizing it would
// paper over a mapping that no longer matches those rows.
let fromStoredNames = indexNames

let names = (mapping: t) => mapping.names

let idOfOrThrow = (mapping: t, name, ~context="") =>
  switch mapping.idByName->Utils.Dict.dangerouslyGetNonOption(name) {
  | Some(id) => id
  | None =>
    JsError.throwWithMessage(
      `Contract "${name}"${context} is missing from the indexer's contract list.`,
    )
  }

let nameOfOrThrow = (mapping: t, id) =>
  switch mapping.names->Array.get(id) {
  | Some(name) => name
  | None =>
    JsError.throwWithMessage(
      `Contract id ${id->Int.toString} is outside the indexer's contract list.`,
    )
  }

let isEqual = (a: t, b: t) =>
  a.names->Array.length === b.names->Array.length &&
    a.names->Array.everyWithIndex((name, idx) => b.names->Array.getUnsafe(idx) === name)

let has = (mapping: t, name) =>
  mapping.idByName->Utils.Dict.dangerouslyGetNonOption(name)->Option.isSome

// Every contract `other` declares already has an id here. That, not equality, is
// what a resume needs: the stored order is the one every lookup resolves
// through, so a mapping carrying the same names in a different order still
// answers every question the run asks.
let covers = (mapping: t, other: t) => other.names->Array.every(name => mapping->has(name))

// The names `mapping` lacks, in canonical order. `extend` appends exactly these,
// so an id a stored address row references never moves.
let missingFrom = (mapping: t, ~names: array<string>) =>
  Core.getAddon().canonicalContractNames(names)->Array.filter(name => !(mapping->has(name)))

let extend = (mapping: t, ~names: array<string>) =>
  switch mapping->missingFrom(~names) {
  | [] => mapping
  | missing => indexNames(mapping.names->Array.concat(missing))
  }
