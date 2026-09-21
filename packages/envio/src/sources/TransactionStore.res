// Binding to the Rust `TransactionStore` napi class. Transactions are kept in
// Rust as raw structs (their large fields never enter JS until read) keyed by
// (blockNumber, transactionIndex). One store lives per chain on `ChainState`;
// each fetch response contributes a page that is merged in. At batch
// preparation the selected fields are materialised in bulk, off the JS thread,
// in columnar form and zipped into plain JS objects on the main thread.
type t

@send external newEvm: Core.transactionStoreCtor => t = "newEvm"
@send external newSvm: Core.transactionStoreCtor => t = "newSvm"
@send external newFuel: Core.transactionStoreCtor => t = "newFuel"

// The store's ecosystem is fixed here, from the chain's config.
let make = (~ecosystem: Ecosystem.name): t => {
  let ctor = Core.getAddon().transactionStore
  switch ecosystem {
  | Evm => ctor->newEvm
  | Svm => ctor->newSvm
  | Fuel => ctor->newFuel
  }
}

// One event's selected transaction fields → store selection bitmask, built from
// the ecosystem's ordered field-name array (the bit index is the field code
// shared with the Rust store, `EvmTxField`/`SvmTxField`).
let makeMaskFn = FieldMask.makeMaskFn
let orMask = FieldMask.orMask
let fieldCodes = FieldMask.fieldCodes

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

type svmTxInput = {
  slot: int,
  transactionIndex: int,
  signature?: string,
  allSignatures?: array<string>,
  feePayer?: string,
  success?: bool,
  err?: string,
  fee?: bigint,
  computeUnitsConsumed?: bigint,
  accountKeys?: array<string>,
  recentBlockhash?: string,
  version?: string,
}

type svmActivityInput = {
  slot: int,
  transactionIndex: int,
  account: string,
  accountIndex?: int,
  isSigner?: bool,
  isWritable?: bool,
  preBalance?: bigint,
  postBalance?: bigint,
  mint?: string,
  owner?: string,
  decimals?: int,
  preAmount?: bigint,
  postAmount?: bigint,
}

@send
external fromJsSvm: (Core.transactionStoreCtor, array<svmTxInput>, array<svmActivityInput>) => t =
  "fromJsSvm"

let fromSvmJs = (transactions: array<svmTxInput>, activities: array<svmActivityInput>): t =>
  Core.getAddon().transactionStore->fromJsSvm(transactions, activities)

// Bulk-materialise transactions off the JS thread, one row per
// (blockNumbers[i], transactionIndices[i]) key, decoding only the fields set in
// that row's own masks[i]. Result is aligned with the input. `shouldChecksum` is
// the caller's spelling for the addresses decoded out of the store: the rows
// themselves are raw bytes, so a page merged from a differently configured store
// can't fix it in.
@send
external materialize: (
  t,
  ~blockNumbers: array<int>,
  ~transactionIndices: array<int>,
  ~masks: array<float>,
  ~shouldChecksum: bool,
) => promise<array<Internal.eventTransaction>> = "materialize"

// Drop transactions for blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop transactions for blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"
