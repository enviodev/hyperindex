// Binding to the Rust `BlockStore` napi class. Blocks are kept in Rust as raw
// structs (their large fields never enter JS until read) keyed by block number.
// One store lives per chain on `ChainState`; each fetch response contributes a
// page that is merged in. At batch preparation the selected fields are
// materialised in bulk, off the JS thread, in columnar form and zipped into
// plain JS objects on the main thread.
//
// The store also owns response validation and reorg detection. A response page
// records conflicts found while it is built; SourceManager rejects those pages
// before the persistent store is touched. Merging a validated page compares
// only persistent-vs-response hashes, and pruning keeps the hash of processed
// blocks still inside the reorg threshold.
type t

@send external newEvm: (Core.blockStoreCtor, ~shouldChecksum: bool) => t = "newEvm"
@send external newSvm: Core.blockStoreCtor => t = "newSvm"
@send external newFuel: Core.blockStoreCtor => t = "newFuel"

// The store's ecosystem is fixed here, from the chain's config. EVM carries the
// chain's address-checksumming setting; SVM/Fuel need no extra data.
let make = (~ecosystem: Ecosystem.name, ~shouldChecksum: bool): t => {
  let ctor = Core.getAddon().blockStore
  switch ecosystem {
  | Evm => ctor->newEvm(~shouldChecksum)
  | Svm => ctor->newSvm
  | Fuel => ctor->newFuel
  }
}

// One event's selected block fields → store selection bitmask, built from the
// ecosystem's ordered field-name array (the bit index is the field code shared
// with the Rust store, `EvmBlockField`).
let makeMaskFn = FieldMask.makeMaskFn

// Sparse JS blocks accepted by the `fromJs*` page constructors. Every field is
// optional except the key, so a page can carry anything from a full block to a
// hash-only reorg observation. The Rust side re-encodes them through the same
// column fill as fetched blocks.
type evmBlockInput = {number: int, hash?: string, timestamp?: int}
type svmBlockInput = {slot: int, hash?: string, time?: int}
type fuelBlockInput = {height: int, id?: string, time?: int}

@send
external fromJsEvm: (Core.blockStoreCtor, array<evmBlockInput>, bool) => t = "fromJsEvm"
@send
external fromJsSvm: (Core.blockStoreCtor, array<svmBlockInput>) => t = "fromJsSvm"
@send
external fromJsFuel: (Core.blockStoreCtor, array<fuelBlockInput>) => t = "fromJsFuel"

// An ecosystem-agnostic (number, hash, timestamp) observation, mapped onto the
// ecosystem's own field names when the page is built.
type inputBlock = {blockNumber: int, blockHash?: string, blockTimestamp?: int}

// Build a page from JS-observed blocks (RPC responses, stored reorg
// checkpoints) for merging into the per-chain store.
let fromJs = (blocks: array<inputBlock>, ~ecosystem: Ecosystem.name, ~shouldChecksum): t => {
  let ctor = Core.getAddon().blockStore
  switch ecosystem {
  | Evm =>
    ctor->fromJsEvm(
      blocks->Array.map(b => {
        number: b.blockNumber,
        hash: ?b.blockHash,
        timestamp: ?b.blockTimestamp,
      }),
      shouldChecksum,
    )
  | Svm =>
    ctor->fromJsSvm(
      blocks->Array.map(b => {
        slot: b.blockNumber,
        hash: ?b.blockHash,
        time: ?b.blockTimestamp,
      }),
    )
  | Fuel =>
    ctor->fromJsFuel(
      blocks->Array.map(b => {
        height: b.blockNumber,
        id: ?b.blockHash,
        time: ?b.blockTimestamp,
      }),
    )
  }
}

// The lowest merged block at or above the reorg threshold whose received hash
// differed from the stored one.
type hashMismatch = {
  blockNumber: int,
  storedHash: string,
  receivedHash: string,
}

// Drain another store (a fetch-response page) into this one, comparing hashes
// on the way. Blocks below `fromBlock` (outside the reorg threshold) or without
// a hash on either side are merged without comparison. On a mismatch the page
// is discarded — the stored hashes stay for the rollback comparison — unless
// `reportOnly` is set (detect-only mode), which merges anyway so the same
// mismatch doesn't re-report on every response.
@send
external merge: (t, t, ~fromBlock: int, ~reportOnly: bool) => Null.t<hashMismatch> = "merge"

// Append a backend page to a logical response store. This always appends rows;
// any conflict is retained as response metadata for SourceManager to validate.
@send
external appendPage: (t, t) => unit = "appendPage"

// A conflict observed within the response itself. Such a response is
// discarded and retried, rather than treated as a chain reorg.
@send external responseConflict: t => Null.t<hashMismatch> = "responseConflict"

// Requested block numbers not covered by this response. SVM gaps count as
// covered when HyperSync's cursor has fully processed their half-open range;
// parent slot/hash links are validated separately as response consistency.
@send external missingHashes: (t, array<int>) => array<int> = "missingHashes"

// Compare a validated response store against the persistent store in ascending
// block order and stop at the first mismatch.
@send
external latestValidBlockFromStore: (t, t, array<int>) => Null.t<int> = "latestValidBlockFromStore"

// Bulk-materialise blocks off the JS thread, one row per `blockNumbers[i]` key,
// decoding only the fields set in that row's own `masks[i]`. Result is aligned
// with the input.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~masks: array<float>,
) => promise<array<Internal.eventBlock>> = "materialize"

// Drop blocks at or below the given block (already processed), keeping the
// hashes of blocks at or above `keepHashesFrom` for reorg detection.
@send external prune: (t, int, ~keepHashesFrom: int) => unit = "prune"

// Drop blocks above the given block (rolled back), hashes included. The
// rolled-back range is refetched, so its stale hashes must not linger for
// reorg detection.
@send external rollback: (t, int) => unit = "rollback"

// Hash of a stored block, if the store still holds it.
@send external getHash: (t, int) => Null.t<string> = "getHash"

// Block numbers in `[fromBlock, belowBlock)` with a stored hash, ascending.
@send
external getHashedBlockNumbers: (t, ~fromBlock: int, ~belowBlock: int) => array<int> =
  "getHashedBlockNumbers"
