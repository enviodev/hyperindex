# Chunk store: memory & performance analysis

Scope: the per-chain field stores in `packages/cli/src` — `chunk_store.rs`
(shared core), `block_store.rs`, `transaction_store.rs`. Compares three designs:

1. **main** — row-oriented `BTreeMap<block, HashMap<idx, Arc<RawStruct>>>`.
2. **PR (#1378, on this branch)** — chunk-columnar `Vec<Chunk>` with sorted keys,
   one typed column per selected field, per-column validity bitmaps.
3. **Proposed alt** — one unordered columnar table + a per-row field-mask column +
   a `HashMap<key, position>` index.

TL;DR: **PR ≪ alt < main on memory; PR wins the steady-state operations**
(insert, prune, rollback) that the alt's *unordered* layout turns back into
`O(n)` scans. The alt's only real win — `O(1)` point lookup — is a case the PR
already handles in `O(1)` on the hot path, and the alt pays for it with a whole
hashmap of per-row overhead plus a rollback-correctness problem it cannot solve
without reintroducing chunks.

---

## 1. What each design actually stores

### main (`origin/main:transaction_store.rs`)

```
BTreeMap<u64 /*block*/, HashMap<u32 /*tx_index*/, StoredTx>>
StoredTx = EvmRaw { tx: Arc<simple_types::Transaction> } | Svm { rec: Arc<SvmStored> }
```

The **entire raw upstream struct** is retained per row — all ~32 EVM tx fields
(`input`, `logs_bloom`, `access_list`, …) whether or not the chain selected them.
Selected fields are decoded to columns only at `materialize` time via
`fill_masked`. Prune/rollback are `BTreeMap::split_off` (cheap range splits).

### PR — chunk-columnar (`chunk_store.rs`)

```
ChunkStore<K> { chunks: Vec<Chunk<K>>, n_fields, unique_keys }
Chunk<K>      { keys: Vec<K> /*sorted*/, start: usize, cols: Vec<Option<AnyCol>> }
```

Each fetch response becomes **one immutable chunk**. Columns are built at insert
time (`evm_tx_col`/`evm_block_col`/…); `built()` drops a column to `None` when no
row carries the field (`col.any_valid()`), so **unselected fields cost zero
bytes** — hypersync never returns them, so their column is `None`. Validity is a
bit-packed `BitVec` (1 bit/row) *per column*. Lifecycle is "append a chunk, drop
a chunk": prune advances a per-chunk `start` watermark, rollback truncates a
chunk tail, both `O(#chunks)`. Coalescing merges small runs once chunk count
passes `COALESCE_CHUNK_COUNT = 64`.

Concrete instances on this branch: blocks `ChunkStore<u64>`, transactions
`ChunkStore<(u64,u32)>` (`unique_keys=true`), SVM token balances
`ChunkStore<(u64,u32)>` (`unique_keys=false`, duplicate-key table).

### Proposed alt — unordered table + hashmap + row-mask

```
cols:  Vec<AnyCol>            // same compact columns as the PR
mask:  Vec<u64>              // one row-mask column: bit f = "field f present for this row"
index: HashMap<K, usize>    // key -> row position; rows appended in arbitrary order
```

Same compact column *data* as the PR. Two structural differences: (a) the PR's
*N per-column* validity bitmaps collapse into *one per-row* `u64` mask column;
(b) the PR's sorted `Vec<K>` + newest-first chunk scan is replaced by a hashmap
index over an unordered row vector.

---

## 2. Memory

Worked example: an EVM chain whose events select transaction `hash` (32 B fixed)
and `from` (20 B fixed); `N` transactions live in the store between prunes. Key
is `(u64,u32)` = 12 B (16 B padded).

| Design | Per-row cost (hash+from selected) | Notes |
|---|---|---|
| **main** | **~300–600 B** | Full `Arc<Transaction>`: `input` (tens→thousands of B), `logs_bloom`, gas fields, `to`, `value`, … all retained though unused. Plus `Arc` control block, a **whole `HashMap` allocation per block**, BTreeMap node share. |
| **PR** | **~64 B** | 32 (hash) + 20 (from) + 12 (key in sorted `Vec<K>`, once/chunk) + 2 bits validity + amortised Vec headers. |
| **alt** | **~90–100 B** | 52 (data) + **8 (row-mask)** + **~28–36 (`HashMap<(u64,u32),usize>`: key + `usize` + control bytes at ~87.5% load)** + key. |

Ranking: **PR (~64 B) < alt (~95 B) < main (~300–600 B).** Both columnar designs
crush main because main pays for every unselected raw field; the store commonly
holds `input`/`logs_bloom`-class fields that nobody reads.

The alt is **~40–50% heavier than the PR**, for two structural reasons:

- **The hashmap is pure overhead.** The PR already needs `Vec<K>` for range
  prune/rollback; the alt keeps *that key material inside* a hashmap **and** adds
  the bucket/control/`usize` overhead on top (~28–36 B/row) — the single largest
  line in its budget.
- **The row-mask is a strictly worse validity encoding.** One `u64`/row = 8 B
  regardless of how many fields are selected. The PR's per-column bitmaps cost
  `F/8` B/row (`F` = selected fields): 0.25 B for `F=2`, ~1.25 B for `F=10`. The
  row-mask only breaks even near `F=64` — the ceiling of a `u64` mask. For every
  realistic selection the transposed row-mask loses.

The alt's one memory win: **no transient key duplication.** Overlapping partition
re-fetches put the same key in multiple PR chunks until coalesce; the alt
overwrites in place. But steady-state PR duplication is small (1–2 copies, reaped
at coalesce) and — see §4 — in-place overwrite is exactly what breaks the alt's
correctness.

---

## 3. Performance by operation

Let `N` = live rows, `C` = live chunks (`≤ 64`, pruned continuously so usually
single digits), `R` = rows in one response.

| Operation | main | PR | alt |
|---|---|---|---|
| **Insert response** | `O(R·log B)`, a `HashMap` alloc per new block | **`O(R)` column build + `O(1)` `Vec::append`** | `O(R)` but every row must probe the global hashmap to dedup; no bulk append |
| **materialize / lookup** | `O(log B)+O(1)` per key, pointer-chasing | `O(C)` per key, `O(1)` on the newest-chunk hot path; cache-friendly sorted keys | **`O(1)`** per key, but random-bucket cache miss + hash |
| **prune** (drop `key ≤ wm`) | `split_off`, cheap | **`O(C)`: free whole chunks, bump one `start`** | **`O(N)` scan + compact every column + rebuild the whole hashmap** |
| **rollback** (drop `key > t`) | `split_off`, cheap | **`O(C)`: drop/tail-truncate chunks** | **`O(N)` scan + compact + reindex** |
| **compaction** | — | amortised `O(N)` coalesce past 64 chunks | none (paid on every prune instead) |

The decisive row is **prune** (and rollback). In a live indexer prune is the
steady-state hot path — every processed batch drops its blocks. The PR's sorted,
immutable chunks make it drop-a-Vec-and-bump-a-pointer (`prune` in
`chunk_store.rs:426`). The alt's **unordered** vector has no range to split: it
must scan all `N` rows, compact each column to remove pruned rows, and **rebuild
every entry of the hashmap** because compaction shifts positions. That is the
core tension — "vec should not necessarily be ordered" is precisely what makes
the most frequent operation `O(N)`.

The alt could instead *tombstone* (clear pruned rows' mask bits, defer
compaction), but then reclamation lags and memory grows unbounded between
compactions — the wrong trade for a long-running streaming indexer.

The alt's genuine edge: lookup is `O(1)` irrespective of `C`, with no coalesce.
But the PR's lookup is already `O(1)` on the hot path (freshly-fetched keys hit
the newest chunk first), coalesce caps `C ≤ 64`, and prune keeps `C` tiny in
practice — so the alt is buying down a cost the PR mostly doesn't pay.

---

## 4. Correctness: in-place mutation vs immutable chunks

Two problems the alt inherits from mutating an unordered table in place — both
absent from the PR:

1. **Variable-width columns can't be overwritten in place.** `VarCol` packs bytes
   into one shared buffer with `u32` offsets (`chunk_store.rs:127`). Overwriting a
   row whose new value differs in length would shift every later offset — an
   `O(N)` rewrite, not an in-place poke. So "overwrite the row for a re-fetched
   key" only works for fixed-width columns; `input`, hash lists, access lists
   force append-and-tombstone anyway.

2. **In-place overwrite destroys the history rollback needs.** The PR keeps each
   response as its own immutable chunk and resolves reads newest-first, so a
   rollback that drops recent chunks makes an earlier chunk's value for a key
   resurface automatically. Once the alt overwrites key *k*'s row, the prior value
   is gone; a subsequent rollback cannot restore it without a version log — i.e.
   without reintroducing chunks. The immutable-chunk design gets correct reorg
   semantics *for free* from the same structure that makes rollback `O(C)`.

---

## 5. Verdict

- **PR vs main:** unambiguous win. Memory drops ~5–10× (only selected fields, bit-
  packed validity, no per-block hashmaps, no retained raw structs) and the
  steady-state ops move from per-row map work to per-chunk Vec work. Cost paid:
  a bounded newest-first read scan (`≤ C`) and an amortised coalesce.

- **Proposed alt vs PR:** worse on the axes that matter. The hashmap adds the
  single biggest per-row memory line while the PR already carries the key
  material it needs; the row-mask is a strictly heavier validity encoding than
  per-column bitmaps below `F=64`; and making the vector unordered turns prune and
  rollback — the hottest lifecycle operations — into `O(N)` compact-and-reindex
  passes. Its `O(1)` lookup duplicates a fast path the PR already has, and its
  in-place dedup is undercut by the variable-width and rollback-history problems.

**Recommendation:** keep the PR's sorted-key immutable chunks with per-column
validity bitmaps. If the row-mask idea is attractive for clarity, note it is just
the transpose of the existing per-column bitmaps — worth adopting only if a future
selection needs `> 64` fields or the mask is read row-at-a-time far more than
column-at-a-time, neither of which holds today. The unordered-vec + hashmap index
should not replace the chunk layout: it trades the store's cheapest operations for
its rarest one.
