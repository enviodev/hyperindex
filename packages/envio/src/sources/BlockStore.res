// Binding to the Rust `BlockStore` napi class. Blocks are kept in Rust as raw
// structs (their large fields never enter JS until read) keyed by block number.
// One store lives per chain on `ChainState`; each fetch response contributes a
// page that is merged in. At batch preparation the selected fields are
// materialised in bulk, off the JS thread, in columnar form and zipped into
// plain JS objects on the main thread.
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

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

// Bulk-materialise blocks off the JS thread, one row per `blockNumbers[i]` key,
// decoding only the fields set in that row's own `masks[i]`. Result is aligned
// with the input.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~masks: array<float>,
) => promise<array<Internal.eventBlock>> = "materialize"

// Drop blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"
