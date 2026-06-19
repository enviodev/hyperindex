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
@send
external pushEvmUnsafe: (t, ~blockNumber: int, ~transactionId: string, ~tx: 'tx) => unit = "pushEvm"

// napi reads each struct field by key: a present-but-null array field (e.g.
// `accessList`) is coerced to an array and throws, whereas an absent key maps to
// `None`. JS-built transactions default such fields to null, so drop nullish
// keys before crossing the boundary.
let stripNullish: 'a => 'a = %raw(`tx => {
  var out = {}
  for (var k in tx) {
    var v = tx[k]
    if (v !== null && v !== undefined) out[k] = v
  }
  return out
}`)

let pushEvm = (store: t, ~blockNumber: int, ~transactionId: string, ~tx: 'tx) =>
  store->pushEvmUnsafe(~blockNumber, ~transactionId, ~tx=stripNullish(tx))

// Drop transactions for blocks at or below the given block (already processed).
@send external prune: (t, int) => unit = "prune"

// Drop transactions for blocks above the given block (rolled back).
@send external rollback: (t, int) => unit = "rollback"
