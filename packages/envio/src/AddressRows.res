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
  lengths: array<int>,
  contractIds: array<int>,
  registrationBlocks: array<int>,
}

let emptySeedRows = (): seedRows => {
  addresses: NodeJs.Buffer.empty,
  lengths: [],
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

// The form every napi crossing takes the keys in: packed back to back with the
// length of each, so the Rust codec owns every question about how wide a key is.
let packKeys = (rows: array<row>) => (
  NodeJs.Buffer.concat(rows->Array.map(row => row.address)),
  rows->Array.map(row => row.address->NodeJs.Buffer.length),
)

let seedRowsOf = (rows: array<row>): seedRows => {
  let (addresses, lengths) = rows->packKeys
  {
    addresses,
    lengths,
    contractIds: rows->Array.map(row => row.contractId),
    registrationBlocks: rows->Array.map(row => row.registrationBlock),
  }
}

// Groups stored rows per chain, keyed by the normalized chain id string. Rows
// arrive clustered per chain, so each run of one chain's rows normalizes its id
// once — normalizing is a schema parse, and a resume reads millions of rows.
let group = (rows: array<row>): dict<seedRows> => {
  let rowsByChain: dict<array<row>> = Dict.make()
  let runChainId = ref(None)
  let runKey = ref("")
  rows->Array.forEach(row => {
    if runChainId.contents !== Some(row.chainId) {
      runChainId := Some(row.chainId)
      runKey := row.chainId->ChainId.normalizeOrThrow->ChainId.toString
    }
    rowsByChain->Utils.Dict.push(runKey.contents, row)
  })
  rowsByChain->Utils.Dict.mapValues(seedRowsOf)
}

// The in-memory twin of envio_addresses.
module Table = {
  type t = dict<row>

  // Base64 is how a Buffer becomes a dict key here, nothing to do with how an
  // address is stored.
  let storageKey = (key: key) =>
    `${key.chainId->ChainId.toString}|${key.contractId->Int.toString}|${key.address->NodeJs.Buffer.toBase64}`

  let make = (): t => Dict.make()

  let clear = (table: t) => table->Utils.Dict.clearInPlace

  // Keeps the row already stored under the key, exactly as the write path's
  // ON CONFLICT DO NOTHING does — a replayed insert must not restate the
  // registration block a rollback would then delete by.
  let insert = (table: t, row: row) => {
    let key = row->keyOf->storageKey
    switch table->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(_) => ()
    | None => table->Dict.set(key, row)
    }
  }

  let insertMany = (table: t, rows: array<row>) => rows->Array.forEach(row => table->insert(row))

  let delete = (table: t, key: key) => table->Utils.Dict.deleteInPlace(key->storageKey)

  let rows = (table: t): array<row> => table->Dict.valuesToArray

  let groupByChain = (table: t) => table->rows->group
}

// Rows rendered back to user-facing addresses, one napi crossing for the lot.
let render = (rows: array<row>, ~ecosystem: string, ~shouldChecksum: bool) => {
  let (bytes, lengths) = rows->packKeys
  Core.getAddon().renderAddresses(~ecosystem, ~shouldChecksum, ~bytes, ~lengths)
}
