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

// The columnar form the address store seeds from. `isFixedWidth` is false only
// for SVM, whose base58 keys vary in width and so need their lengths carried
// alongside.
let seedRowsOf = (rows: array<row>, ~isFixedWidth: bool): seedRows => {
  addresses: NodeJs.Buffer.concat(rows->Array.map(row => row.address)),
  lengths: isFixedWidth
    ? Null.null
    : Null.make(rows->Array.map(row => row.address->NodeJs.Buffer.length)),
  contractIds: rows->Array.map(row => row.contractId),
  registrationBlocks: rows->Array.map(row => row.registrationBlock),
}

// Groups stored rows per chain, keyed by the normalized chain id string.
let group = (rows: array<row>, ~isFixedWidth: bool): dict<seedRows> => {
  let rowsByChain: dict<array<row>> = Dict.make()
  rows->Array.forEach(row => {
    let key = row.chainId->ChainId.normalizeOrThrow->ChainId.toString
    switch rowsByChain->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(chainRows) => chainRows->Array.push(row)->ignore
    | None => rowsByChain->Dict.set(key, [row])
    }
  })
  let seedRowsByChain = Dict.make()
  rowsByChain->Utils.Dict.forEachWithKey((chainRows, key) =>
    seedRowsByChain->Dict.set(key, chainRows->seedRowsOf(~isFixedWidth))
  )
  seedRowsByChain
}

// The in-memory storages index rows by their primary key with this. Base64 is
// how a Buffer becomes a set key here, nothing to do with how an address is
// stored.
let storageKey = (key: key) =>
  `${key.chainId->ChainId.toString}|${key.contractId->Int.toString}|${key.address->NodeJs.Buffer.toBase64}`

// Rows rendered back to user-facing addresses, one napi crossing for the lot.
let render = (rows: array<row>, ~ecosystem: string, ~shouldChecksum: bool) =>
  Core.getAddon().renderAddresses(
    ~ecosystem,
    ~shouldChecksum,
    ~bytes=NodeJs.Buffer.concat(rows->Array.map(row => row.address)),
    ~lengths=Null.make(rows->Array.map(row => row.address->NodeJs.Buffer.length)),
  )
