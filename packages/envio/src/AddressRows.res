// Addresses cross as the raw store key the Rust address store encodes — never
// as a rendered string, so the bytes a row holds and the bytes the store keys
// on can't fork.

// The primary key of a stored address: what a rollback deletes by.
type key = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
}

type row = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
  registrationBlock: int,
}

// A row on its way to storage, tagged with the checkpoint whose event
// registered it. That checkpoint decides which write covers the row, and which
// change the test indexer reports it under; it is never stored, because a
// rollback deletes by primary key.
type staged = {
  row: row,
  checkpointId: Internal.checkpointId,
}

// The shape the address store seeds from. A resume reads millions of rows, so
// nothing here is a per-row object or string.
type seedRows = {
  // Store keys packed back to back.
  addresses: NodeJs.Buffer.t,
  lengths: Null.t<array<int>>,
  contractIds: array<int>,
  registrationBlocks: array<int>,
}

let emptySeedRows = (): seedRows => {
  addresses: NodeJs.Buffer.empty,
  lengths: Null.null,
  contractIds: [],
  registrationBlocks: [],
}

// A config address: registered by no event, so no rollback ever reaches it —
// every rollback target is at or above the block it claims to be registered at.
let configRegistrationBlock = -1

let keyOf = (row: row): key => {
  chainId: row.chainId,
  address: row.address,
  contractId: row.contractId,
}

// The columnar form the address store seeds from. Lengths are always carried:
// key widths are the Rust codec's knowledge, so no caller ever answers that
// question for it.
let seedRowsOf = (rows: array<row>): seedRows => {
  addresses: NodeJs.Buffer.concat(rows->Array.map(row => row.address)),
  lengths: Null.make(rows->Array.map(row => row.address->NodeJs.Buffer.length)),
  contractIds: rows->Array.map(row => row.contractId),
  registrationBlocks: rows->Array.map(row => row.registrationBlock),
}

// Groups stored rows per chain, keyed by the normalized chain id string.
let group = (rows: array<row>): dict<seedRows> => {
  let rowsByChain: dict<array<row>> = Dict.make()
  rows->Array.forEach(row =>
    rowsByChain->Utils.Dict.push(row.chainId->ChainId.normalizeOrThrow->ChainId.toString, row)
  )
  rowsByChain->Utils.Dict.mapValues(seedRowsOf)
}

// The in-memory storages index rows by their primary key with this. Base64 is
// how a Buffer becomes a set key here, nothing to do with how an address is
// stored.
let storageKey = (key: key) =>
  `${key.chainId->ChainId.toString}|${key.contractId->Int.toString}|${key.address->NodeJs.Buffer.toBase64}`

// The in-memory twin of the envio_addresses table, shared by every storage
// that fakes it: rows keyed by their primary key, so an insert is idempotent
// (Postgres' ON CONFLICT DO NOTHING) and a rollback deletes by key.
module Table = {
  type t = dict<row>

  let make = (): t => Dict.make()

  // Returns whether the row was new — a re-inserted primary key is a no-op.
  let insert = (table: t, row: row): bool => {
    let key = row->keyOf->storageKey
    switch table->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(_) => false
    | None =>
      table->Dict.set(key, row)
      true
    }
  }

  let delete = (table: t, key: key) => table->Utils.Dict.deleteInPlace(key->storageKey)

  let rows = (table: t): array<row> => table->Dict.valuesToArray
}

// Rows rendered back to user-facing addresses, one napi crossing for the lot.
let render = (rows: array<row>, ~ecosystem: string, ~shouldChecksum: bool) =>
  Core.getAddon().renderAddresses(
    ~ecosystem,
    ~shouldChecksum,
    ~bytes=NodeJs.Buffer.concat(rows->Array.map(row => row.address)),
    ~lengths=Null.make(rows->Array.map(row => row.address->NodeJs.Buffer.length)),
  )
