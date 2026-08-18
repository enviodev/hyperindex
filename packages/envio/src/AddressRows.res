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

let emptySeedRows = (): seedRows => {
  addresses: NodeJs.Buffer.empty,
  lengths: Null.null,
  contractIds: [],
  registrationBlocks: [],
}

// A config address: registered by no event, so no rollback can reach it.
let configCheckpointId: Internal.checkpointId = 0n
let configRegistrationBlock = -1
