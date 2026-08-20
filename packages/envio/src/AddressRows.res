// The persisted form of an indexed address, shared by the address store, the
// storage layer and the fetch state. Addresses cross as the raw store key the
// Rust address store encodes — never as a rendered string, so the bytes a row
// holds and the bytes the store keys on can't fork.

// The primary key of a stored address: what a rollback deletes by.
type key = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
}

// A stored address, as the table holds it.
type row = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
  registrationBlock: int,
}

// A row on its way to storage, tagged with the checkpoint that decides which
// write covers it. Never stored: a rollback deletes by primary key.
type staged = {
  row: row,
  checkpointId: Internal.checkpointId,
}

// Rows as they come back from storage, columnar per chain — the shape the
// address store seeds from. A resume reads millions of them, so nothing here is
// a per-row object or string.
type seedRows = {
  // Store keys packed back to back.
  addresses: NodeJs.Buffer.t,
  // Only SVM's base58 keys vary in width; the others are a fixed stride.
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

type mutableGroup = {
  chunks: array<NodeJs.Buffer.t>,
  lengths: Null.t<array<int>>,
  contractIds: array<int>,
  registrationBlocks: array<int>,
}

// Groups stored rows into the per-chain columnar form the address store seeds
// from, keyed by the normalized chain id string. `isFixedWidth` is false only
// for SVM, whose base58 keys vary in width and so need their lengths carried
// alongside.
let group = (rows: array<row>, ~isFixedWidth: bool): dict<seedRows> => {
  let groups: dict<mutableGroup> = Dict.make()
  rows->Array.forEach(row => {
    let key = row.chainId->ChainId.normalizeOrThrow->ChainId.toString
    let group = switch groups->Utils.Dict.dangerouslyGetNonOption(key) {
    | Some(group) => group
    | None =>
      let group = {
        chunks: [],
        lengths: isFixedWidth ? Null.null : Null.make([]),
        contractIds: [],
        registrationBlocks: [],
      }
      groups->Dict.set(key, group)
      group
    }
    group.chunks->Array.push(row.address)->ignore
    switch group.lengths->Null.toOption {
    | Some(lengths) => lengths->Array.push(row.address->NodeJs.Buffer.length)->ignore
    | None => ()
    }
    group.contractIds->Array.push(row.contractId)->ignore
    group.registrationBlocks->Array.push(row.registrationBlock)->ignore
  })
  let seedRowsByChain = Dict.make()
  groups->Utils.Dict.forEachWithKey((group, key) => {
    seedRowsByChain->Dict.set(
      key,
      {
        addresses: NodeJs.Buffer.concat(group.chunks),
        lengths: group.lengths,
        contractIds: group.contractIds,
        registrationBlocks: group.registrationBlocks,
      },
    )
  })
  seedRowsByChain
}

// The in-memory storages index rows by their primary key with this. Base64 is
// how a Buffer becomes a set key here, nothing to do with how an address is
// stored.
let storageKey = (key: key) =>
  `${key.chainId->ChainId.toString}|${key.contractId->Int.toString}|${key.address->NodeJs.Buffer.toBase64}`
