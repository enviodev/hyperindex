# Plan — Merge-on-insert field table

Replace the unique-key chunk stores with a single flat columnar table that
**dedups on insert**, so a transaction's `input` (and every other cell) is stored
once instead of duplicated across chunks until coalesce/prune. Retire
`chunk_store.rs`.

## Why

`input` is a `VarCol` (packed bytes). Overlapping partitions / re-fetches put the
same tx in multiple chunks, so its `input` blob is stored once per chunk until
coalescing (>64 chunks) or prune reclaims it. Merge-on-insert stores each key
once and overwrites in place → no duplication, no coalescing.

## Decisions (locked)

1. No `chunk_store.rs`; one `Table` type covers blocks, transactions, token balances.
2. Variable/large columns are boxed per cell (`Vec<Option<Box<[u8]>>>`) → O(1) overwrite, immediate reclaim.
3. Two indexes: `HashMap` for point lookup + insert dedup, `BTreeMap` for range (prune/rollback/token-balance read). Index memory not a concern.
4. Columns always-present once a field is seen (cells are small — no per-field sparse skip).
5. Capacity reclaim: free-list only in v1; leave a compaction seam (see Open items).
6. Nothing relies on chunk insertion order.
7. **Token balances are unique per account.** Key = `(slot, tx_index, account)`; `account` is force-added to the selection whenever token balances are requested, so it is always present → safe key component. Removes the old duplicate-key path entirely.

## Design — `field_table.rs`

Refactor `chunk_store.rs` → `field_table.rs`: **keep** the interchange layer
(`AnyCol`, the `*_from` fills, the `*_cells` decoders, `hex_*`/`utf8` helpers —
consumed unchanged by the block/tx decoders); **replace** `Chunk`/`ChunkStore`/
coalescing with `Table` + `StoreCol`.

### `StoreCol` — slot-addressable columns

- `Num<T>(Vec<T>)`, `Fixed { width, Vec<u8> }` — in-place overwrite.
- `Var(Vec<Option<Box<[u8]>>>)`, `*List(Vec<Option<Box<[_]>>>)` — boxed; overwrite frees old blob.
- `push_empty()`, `set_from(slot, &AnyCol, row)`, `clear(slot)`, `copy_to(&self, &mut AnyCol, slot)`, `get(slot)` raw accessors.

### `Table<K: Ord + Clone>`

```
by_key: HashMap<K, u32>       // point lookup (blocks/txs) + insert dedup (all)
order:  BTreeMap<K, u32>      // range: prune, rollback, token-balance read
masks:  Vec<u64>             // per-slot field presence = sole validity
cols:   Vec<Option<StoreCol>> // lazily created, backfilled to len on first sighting
free:   Vec<u32>             // reusable slots
len, n_fields
```

Key bound is `Ord + Clone` (not `Copy`) so the token-balance key can carry the
account string. Blocks (`u64`) and txs (`(u64, u32)`) satisfy it unchanged.

- `merge_batch(keys, cols: Vec<Option<AnyCol>>)` — one path for all stores: per
  row `slot = by_key.get(k)` else alloc from `free`/grow (+ insert into both
  indexes); for each field the batch provides and is valid at that row →
  `cols[f].set_from(slot, …)`, `masks[slot] |= 1<<f`. Per-field union,
  newest-wins. Keys need not be sorted.
- `append_from(&mut other)` — iterate `other` live rows, merge (page→persistent).
- `prune(up_to: K)` — `dead = order` range `..= up_to`; per dead key: free slot
  (`clear` drops `input` boxes now, `mask = 0`, push `free`), remove from both
  indexes. `O(D·log n)`, no scan.
- `rollback(target: K)` — mirror on `> target`.
- `clear()`.
- `gather_scratch(keys, masks) -> Vec<Option<AnyCol>>` — unchanged output shape
  → block/tx decoders untouched.
- `range_slots(prefix) -> impl Iterator<u32>` — token-balance read: iterate
  `order.range((slot, tx, "")..)`, break when `(slot, tx)` changes.

## Wiring

- `lib.rs`: `mod chunk_store;` → `mod field_table;`.
- `block_store.rs`: `ChunkStore<u64>` → `Table<u64>`; `insert_*` keep building via
  `*_col`, call `merge_batch` instead of `push_chunk`; drop `sort_unstable`;
  `merge` → `append_from`; prune/rollback/gather signatures unchanged.
- `transaction_store.rs`:
  - `txs` → `Table<(u64, u32)>`; `input` now stored once.
  - `token_balances` → `Table<(u64, u32, Box<str>)>` keyed by account.
    `insert_svm_token_balances` builds the account into the key; rewrite
    `gather_token_balances` to `range_slots((slot, tx))` and build rows via
    `token_balance_row_by_slot`. `account` column optional (derivable from key).
  - `prune`/`rollback` pass the block/slot with max trailing components.
- `svm_hypersync_source/query.rs` (+ query prep): force-add
  `TokenBalanceField::Account` to `field_selection.token_balance` whenever token
  balances are requested — same pattern as EVM `REQUIRED_BLOCK_FIELDS` /
  `ensure_required_log_fields`. Guarantees decision 7's invariant.
- Delete `chunk_store.rs`.

## Phases

1. `field_table.rs`: `StoreCol` + `Table` + tests. Self-contained, testable before wiring. Port + extend `chunk_store` tests: roundtrip, prune, rollback, per-field union newest-wins, **`input` stored once on overlap**, **var overwrite frees old box**, token-balance range read.
2. Force-add `account` in the SVM query; assert in a query-prep test.
3. Wire `block_store.rs`.
4. Wire `transaction_store.rs` (txs + account-keyed token balances).
5. Delete `chunk_store.rs`; drop `COALESCE_*`.
6. (optional) criterion bench: overlapping-partition `input`, merge-on-insert vs old chunk — memory + insert/prune latency.

## Verify (finish by running tests)

1. `cd packages/cli && cargo test --no-default-features` — `field_table` unit + block/tx store tests green (decoders unchanged).
2. Rebuild napi addon; `pnpm rescript`; run store-integration vitest only.

## Open items

- **Q5 capacity reclaim.** Free-list bounds capacity to the catch-up high-water
  slot count; `input` boxes freed on prune, but fixed-size slot arrays (~68 B/tx
  slot) stay allocated after the catch-up→head drop (~34 MB at 500k high-water).
  v1 ships free-list only; add compaction-on-prune (`free.len() > 8×live &&
  len > 10k` → rebuild without holes, `O(live)`, rare) as a follow-up if a
  profile shows idle retention matters. Confirm: v1 free-list only, or include
  compaction now?
