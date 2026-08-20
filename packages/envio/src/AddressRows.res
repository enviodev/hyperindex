// The persisted form of an indexed address, shared by the address store, the
// storage layer and the fetch state. Addresses cross as the raw store key the
// Rust address store encodes — never as a rendered string, so the bytes a row
// holds and the bytes the store keys on can't fork.

// A row on its way to storage.
type row = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
  registrationBlock: int,
  // The checkpoint a rollback deletes this row with, or 0 for a row no rollback
  // can reach (config addresses, and batches written without history).
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

// A stored row as a reader hands it back: the write-side row without the
// checkpoint, which only the storage that wrote it cares about.
type storedRow = {
  chainId: ChainId.t,
  address: NodeJs.Buffer.t,
  contractId: int,
  registrationBlock: int,
}

let emptySeedRows = (): seedRows => {
  addresses: NodeJs.Buffer.empty,
  lengths: Null.null,
  contractIds: [],
  registrationBlocks: [],
}

// A config address: registered by no event, so no rollback can reach it.
let configCheckpointId: Internal.checkpointId = 0n
let configRegistrationBlock = -1

// The checkpoint a stored row is stamped with. A row's own checkpoint is only
// persisted when the batch saves history, and the in-memory id sequence
// restarts from the last persisted one — so stamping an id that never reached
// storage would let an unrelated later rollback delete the row. A batch written
// without history is final anyway, so its rows are stamped 0: no rollback can
// reach them, and none needs to. The stamp outlives the checkpoint it names
// (checkpoint pruning doesn't rewrite these rows), which costs nothing: a
// rollback target is always at or above the pruning boundary.
let finalizeCheckpoint = (rows: array<row>, ~shouldSaveHistory) =>
  shouldSaveHistory ? rows : rows->Array.map(row => {...row, checkpointId: configCheckpointId})

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
let group = (rows: array<storedRow>, ~isFixedWidth: bool): dict<seedRows> => {
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

// The in-memory storages mirror the (chain, address, contract) primary key with
// this as a lookup key. Base64 is how a Buffer becomes a set key here, nothing
// to do with how an address is stored.
let storageKey = (~chainId: ChainId.t, ~contractId: int, ~address: NodeJs.Buffer.t) =>
  `${chainId->ChainId.toString}|${contractId->Int.toString}|${address->NodeJs.Buffer.toBase64}`
