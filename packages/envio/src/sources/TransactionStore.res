// Binding to the Rust `TransactionStore` napi class. Transactions are kept in
// Rust (their large fields never enter JS until read) and materialised one
// field at a time via `getTransactionField`, keyed by (blockNumber,
// transactionId). One store lives per chain on `ChainState`; each fetch
// response contributes a page that is merged in.
type t

@send external classNew: Core.transactionStoreCtor => t = "new"
let make = (): t => Core.getAddon().transactionStore->classNew

// Drain another store (a fetch-response page) into this one.
@send external merge: (t, t) => unit = "merge"

// Store a transaction assembled in JS (RPC / simulate).
@send external pushEvm: (t, ~blockNumber: int, ~transactionId: string, ~tx: 'tx) => unit = "pushEvm"

// Drop transactions for blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop transactions for blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"
