//! Chunked columnar storage shared by the per-chain field stores. A chunk is
//! one fetch response's rows: a sorted key vector plus one column per field the
//! chain's config selected. Chunks are immutable except for a tail truncate
//! (rollback) and a start watermark (prune of a partially-processed chunk), so
//! the store's lifecycle is "append a chunk, drop a chunk" — no per-row map and
//! no compaction. Reads resolve per field, newest chunk first, which both
//! deduplicates identical rows re-fetched by overlapping partitions and unions
//! rows that arrived with different field subsets.

use hypersync_client::format;

/// Validity bitmap: one bit per row, set when the row's cell holds a value.
pub(crate) struct BitVec {
    words: Vec<u64>,
    len: usize,
}

impl BitVec {
    fn new() -> Self {
        Self {
            words: Vec::new(),
            len: 0,
        }
    }

    fn push(&mut self, v: bool) {
        if self.len.is_multiple_of(64) {
            self.words.push(0);
        }
        if v {
            let w = self.words.last_mut().unwrap();
            *w |= 1 << (self.len % 64);
        }
        self.len += 1;
    }

    fn get(&self, i: usize) -> bool {
        (self.words[i / 64] >> (i % 64)) & 1 == 1
    }

    fn truncate(&mut self, len: usize) {
        if len >= self.len {
            return;
        }
        self.words.truncate(len.div_ceil(64));
        if !len.is_multiple_of(64) {
            let w = self.words.last_mut().unwrap();
            *w &= (1u64 << (len % 64)) - 1;
        }
        self.len = len;
    }

    fn any(&self) -> bool {
        self.words.iter().any(|&w| w != 0)
    }
}

pub(crate) struct NumCol<T> {
    data: Vec<T>,
    validity: BitVec,
}

impl<T: Copy + Default> NumCol<T> {
    fn new() -> Self {
        Self {
            data: Vec::new(),
            validity: BitVec::new(),
        }
    }

    pub(crate) fn push(&mut self, v: Option<T>) {
        self.data.push(v.unwrap_or_default());
        self.validity.push(v.is_some());
    }

    pub(crate) fn get(&self, i: usize) -> Option<T> {
        self.validity.get(i).then(|| self.data[i])
    }

    fn truncate(&mut self, len: usize) {
        self.data.truncate(len);
        self.validity.truncate(len);
    }
}

/// Fixed-width byte cells stored flat; a missing cell still reserves its slot
/// (zero-filled) so row offsets stay `row * width`.
pub(crate) struct FixedCol {
    width: usize,
    data: Vec<u8>,
    validity: BitVec,
}

impl FixedCol {
    fn new(width: usize) -> Self {
        Self {
            width,
            data: Vec::new(),
            validity: BitVec::new(),
        }
    }

    pub(crate) fn push(&mut self, v: Option<&[u8]>) {
        match v {
            Some(b) => {
                debug_assert_eq!(b.len(), self.width);
                self.data.extend_from_slice(b);
            }
            None => self.data.resize(self.data.len() + self.width, 0),
        }
        self.validity.push(v.is_some());
    }

    pub(crate) fn get(&self, i: usize) -> Option<&[u8]> {
        self.validity
            .get(i)
            .then(|| &self.data[i * self.width..(i + 1) * self.width])
    }

    fn truncate(&mut self, len: usize) {
        self.data.truncate(len * self.width);
        self.validity.truncate(len);
    }
}

/// Variable-width byte cells: offsets index into one shared byte buffer.
pub(crate) struct VarCol {
    offsets: Vec<u32>,
    data: Vec<u8>,
    validity: BitVec,
}

impl VarCol {
    fn new() -> Self {
        Self {
            offsets: vec![0],
            data: Vec::new(),
            validity: BitVec::new(),
        }
    }

    pub(crate) fn push(&mut self, v: Option<&[u8]>) {
        if let Some(b) = v {
            self.data.extend_from_slice(b);
        }
        self.offsets.push(self.data.len() as u32);
        self.validity.push(v.is_some());
    }

    pub(crate) fn get(&self, i: usize) -> Option<&[u8]> {
        self.validity
            .get(i)
            .then(|| &self.data[self.offsets[i] as usize..self.offsets[i + 1] as usize])
    }

    fn truncate(&mut self, len: usize) {
        if len + 1 < self.offsets.len() {
            self.offsets.truncate(len + 1);
            self.data.truncate(*self.offsets.last().unwrap() as usize);
            self.validity.truncate(len);
        }
    }
}

/// Per-row boxed lists, for rare fields whose cells are collections.
pub(crate) struct ListCol<T> {
    rows: Vec<Option<Vec<T>>>,
}

impl<T: Clone> ListCol<T> {
    fn new() -> Self {
        Self { rows: Vec::new() }
    }

    pub(crate) fn push(&mut self, v: Option<Vec<T>>) {
        self.rows.push(v);
    }

    pub(crate) fn get(&self, i: usize) -> Option<&Vec<T>> {
        self.rows[i].as_ref()
    }

    fn truncate(&mut self, len: usize) {
        self.rows.truncate(len);
    }
}

/// One field's column. The variant is fixed per field by the fill code and
/// relied upon by the decode code; `copy_cell` panics on a variant mismatch
/// since both sides are written together.
pub(crate) enum AnyCol {
    U64(NumCol<u64>),
    I64(NumCol<i64>),
    F64(NumCol<f64>),
    Bool(NumCol<bool>),
    Fixed(FixedCol),
    Var(VarCol),
    StrList(ListCol<String>),
    HashList(ListCol<[u8; 32]>),
    AccessLists(ListCol<format::AccessList>),
    AuthLists(ListCol<format::Authorization>),
}

impl AnyCol {
    pub(crate) fn new_u64() -> Self {
        AnyCol::U64(NumCol::new())
    }
    pub(crate) fn new_i64() -> Self {
        AnyCol::I64(NumCol::new())
    }
    pub(crate) fn new_f64() -> Self {
        AnyCol::F64(NumCol::new())
    }
    pub(crate) fn new_bool() -> Self {
        AnyCol::Bool(NumCol::new())
    }
    pub(crate) fn new_fixed(width: usize) -> Self {
        AnyCol::Fixed(FixedCol::new(width))
    }
    pub(crate) fn new_var() -> Self {
        AnyCol::Var(VarCol::new())
    }
    pub(crate) fn new_str_list() -> Self {
        AnyCol::StrList(ListCol::new())
    }
    pub(crate) fn new_hash_list() -> Self {
        AnyCol::HashList(ListCol::new())
    }
    pub(crate) fn new_access_lists() -> Self {
        AnyCol::AccessLists(ListCol::new())
    }
    pub(crate) fn new_auth_lists() -> Self {
        AnyCol::AuthLists(ListCol::new())
    }

    /// An empty column of the same kind (and width), for gather/coalesce output.
    fn new_like(&self) -> Self {
        match self {
            AnyCol::U64(_) => Self::new_u64(),
            AnyCol::I64(_) => Self::new_i64(),
            AnyCol::F64(_) => Self::new_f64(),
            AnyCol::Bool(_) => Self::new_bool(),
            AnyCol::Fixed(c) => Self::new_fixed(c.width),
            AnyCol::Var(_) => Self::new_var(),
            AnyCol::StrList(_) => Self::new_str_list(),
            AnyCol::HashList(_) => Self::new_hash_list(),
            AnyCol::AccessLists(_) => Self::new_access_lists(),
            AnyCol::AuthLists(_) => Self::new_auth_lists(),
        }
    }

    fn is_valid(&self, i: usize) -> bool {
        match self {
            AnyCol::U64(c) => c.validity.get(i),
            AnyCol::I64(c) => c.validity.get(i),
            AnyCol::F64(c) => c.validity.get(i),
            AnyCol::Bool(c) => c.validity.get(i),
            AnyCol::Fixed(c) => c.validity.get(i),
            AnyCol::Var(c) => c.validity.get(i),
            AnyCol::StrList(c) => c.rows[i].is_some(),
            AnyCol::HashList(c) => c.rows[i].is_some(),
            AnyCol::AccessLists(c) => c.rows[i].is_some(),
            AnyCol::AuthLists(c) => c.rows[i].is_some(),
        }
    }

    pub(crate) fn any_valid(&self) -> bool {
        match self {
            AnyCol::U64(c) => c.validity.any(),
            AnyCol::I64(c) => c.validity.any(),
            AnyCol::F64(c) => c.validity.any(),
            AnyCol::Bool(c) => c.validity.any(),
            AnyCol::Fixed(c) => c.validity.any(),
            AnyCol::Var(c) => c.validity.any(),
            AnyCol::StrList(c) => c.rows.iter().any(|r| r.is_some()),
            AnyCol::HashList(c) => c.rows.iter().any(|r| r.is_some()),
            AnyCol::AccessLists(c) => c.rows.iter().any(|r| r.is_some()),
            AnyCol::AuthLists(c) => c.rows.iter().any(|r| r.is_some()),
        }
    }

    pub(crate) fn push_missing(&mut self) {
        match self {
            AnyCol::U64(c) => c.push(None),
            AnyCol::I64(c) => c.push(None),
            AnyCol::F64(c) => c.push(None),
            AnyCol::Bool(c) => c.push(None),
            AnyCol::Fixed(c) => c.push(None),
            AnyCol::Var(c) => c.push(None),
            AnyCol::StrList(c) => c.push(None),
            AnyCol::HashList(c) => c.push(None),
            AnyCol::AccessLists(c) => c.push(None),
            AnyCol::AuthLists(c) => c.push(None),
        }
    }

    fn copy_cell(&mut self, src: &AnyCol, row: usize) {
        match (self, src) {
            (AnyCol::U64(d), AnyCol::U64(s)) => d.push(s.get(row)),
            (AnyCol::I64(d), AnyCol::I64(s)) => d.push(s.get(row)),
            (AnyCol::F64(d), AnyCol::F64(s)) => d.push(s.get(row)),
            (AnyCol::Bool(d), AnyCol::Bool(s)) => d.push(s.get(row)),
            (AnyCol::Fixed(d), AnyCol::Fixed(s)) => d.push(s.get(row)),
            (AnyCol::Var(d), AnyCol::Var(s)) => d.push(s.get(row)),
            (AnyCol::StrList(d), AnyCol::StrList(s)) => d.push(s.get(row).cloned()),
            (AnyCol::HashList(d), AnyCol::HashList(s)) => d.push(s.get(row).cloned()),
            (AnyCol::AccessLists(d), AnyCol::AccessLists(s)) => d.push(s.get(row).cloned()),
            (AnyCol::AuthLists(d), AnyCol::AuthLists(s)) => d.push(s.get(row).cloned()),
            _ => panic!("column kind mismatch for one field across chunks"),
        }
    }

    fn truncate(&mut self, len: usize) {
        match self {
            AnyCol::U64(c) => c.truncate(len),
            AnyCol::I64(c) => c.truncate(len),
            AnyCol::F64(c) => c.truncate(len),
            AnyCol::Bool(c) => c.truncate(len),
            AnyCol::Fixed(c) => c.truncate(len),
            AnyCol::Var(c) => c.truncate(len),
            AnyCol::StrList(c) => c.truncate(len),
            AnyCol::HashList(c) => c.truncate(len),
            AnyCol::AccessLists(c) => c.truncate(len),
            AnyCol::AuthLists(c) => c.truncate(len),
        }
    }
}

/// One response's rows. `keys` is sorted ascending; `start` is the prune
/// watermark (rows below it are logically dead but not reclaimed until the
/// whole chunk drops). `cols[field_ordinal]` is `Some` only for fields that had
/// any value in this response.
pub(crate) struct Chunk<K> {
    pub(crate) keys: Vec<K>,
    start: usize,
    pub(crate) cols: Vec<Option<AnyCol>>,
}

impl<K: Ord + Copy> Chunk<K> {
    pub(crate) fn new(keys: Vec<K>, cols: Vec<Option<AnyCol>>) -> Self {
        debug_assert!(keys.windows(2).all(|w| w[0] <= w[1]));
        Self {
            keys,
            start: 0,
            cols,
        }
    }

    fn live_len(&self) -> usize {
        self.keys.len() - self.start
    }

    fn min(&self) -> K {
        self.keys[self.start]
    }

    fn max(&self) -> K {
        *self.keys.last().unwrap()
    }

    /// Absolute row of `key` among live rows (first match for stores that allow
    /// duplicate keys).
    pub(crate) fn find(&self, key: K) -> Option<usize> {
        if self.live_len() == 0 || key < self.min() || key > self.max() {
            return None;
        }
        let live = &self.keys[self.start..];
        let i = live.partition_point(|&k| k < key);
        (i < live.len() && live[i] == key).then_some(self.start + i)
    }

    /// Absolute row range holding `key` among live rows (for duplicate-key
    /// stores).
    pub(crate) fn find_range(&self, key: K) -> Option<(usize, usize)> {
        let lo = self.find(key)?;
        let live = &self.keys[self.start..];
        let hi = self.start + live.partition_point(|&k| k <= key);
        Some((lo, hi))
    }

    fn truncate_rows(&mut self, len: usize) {
        self.keys.truncate(len);
        for col in self.cols.iter_mut().flatten() {
            col.truncate(len);
        }
    }
}

pub(crate) const COALESCE_CHUNK_COUNT: usize = 64;

/// Chunks in insertion order (newest last). `unique_keys` distinguishes the
/// one-row-per-key stores (blocks, transactions) from the duplicate-key
/// token-balance table, which changes both lookup (row vs range) and how
/// coalescing deduplicates.
pub(crate) struct ChunkStore<K> {
    pub(crate) chunks: Vec<Chunk<K>>,
    n_fields: usize,
    unique_keys: bool,
}

impl<K: Ord + Copy> ChunkStore<K> {
    pub(crate) fn new(n_fields: usize, unique_keys: bool) -> Self {
        Self {
            chunks: Vec::new(),
            n_fields,
            unique_keys,
        }
    }

    pub(crate) fn push_chunk(&mut self, chunk: Chunk<K>) {
        if chunk.keys.is_empty() {
            return;
        }
        debug_assert_eq!(chunk.cols.len(), self.n_fields);
        self.chunks.push(chunk);
        self.coalesce_if_needed();
    }

    pub(crate) fn append_from(&mut self, other: &mut ChunkStore<K>) {
        self.chunks.append(&mut other.chunks);
        self.coalesce_if_needed();
    }

    /// Drop rows with keys <= `up_to` (processed). Whole chunks are freed;
    /// a chunk straddling the boundary just advances its watermark.
    pub(crate) fn prune(&mut self, up_to: K) {
        self.chunks.retain_mut(|chunk| {
            if chunk.live_len() == 0 || chunk.max() <= up_to {
                return false;
            }
            if chunk.min() <= up_to {
                let live = &chunk.keys[chunk.start..];
                chunk.start += live.partition_point(|&k| k <= up_to);
            }
            true
        });
    }

    /// Drop rows with keys > `target` (rolled back). Whole chunks are freed; a
    /// chunk straddling the boundary truncates its tail.
    pub(crate) fn rollback(&mut self, target: K) {
        self.chunks.retain_mut(|chunk| {
            if chunk.live_len() == 0 || chunk.min() > target {
                return false;
            }
            if chunk.max() > target {
                let cut = chunk.keys.partition_point(|&k| k <= target);
                chunk.truncate_rows(cut);
            }
            chunk.live_len() > 0
        });
    }

    pub(crate) fn clear(&mut self) {
        self.chunks.clear();
    }

    /// Newest-first (chunk, row) hits per requested key. Usually one hit; more
    /// when overlapping partition responses duplicated a key.
    pub(crate) fn hit_lists(&self, keys: &[Option<K>]) -> Vec<Vec<(u32, u32)>> {
        keys.iter()
            .map(|key| match key {
                None => Vec::new(),
                Some(key) => {
                    let mut hits = Vec::new();
                    for (ci, chunk) in self.chunks.iter().enumerate().rev() {
                        if let Some(row) = chunk.find(*key) {
                            hits.push((ci as u32, row as u32));
                        }
                    }
                    hits
                }
            })
            .collect()
    }

    /// Copy one field's cells for the requested rows into a fresh column,
    /// resolving each row from the newest chunk that has a value for it.
    /// `None` when no chunk carries the field at all. Rows whose `selected`
    /// is false (or with no hit) come out missing.
    pub(crate) fn gather(
        &self,
        hit_lists: &[Vec<(u32, u32)>],
        field: usize,
        selected: impl Fn(usize) -> bool,
    ) -> Option<AnyCol> {
        let template = self
            .chunks
            .iter()
            .rev()
            .find_map(|c| c.cols[field].as_ref())?;
        let mut out = template.new_like();
        for (i, hits) in hit_lists.iter().enumerate() {
            let mut copied = false;
            if selected(i) {
                for &(ci, row) in hits {
                    if let Some(col) = &self.chunks[ci as usize].cols[field] {
                        if col.is_valid(row as usize) {
                            out.copy_cell(col, row as usize);
                            copied = true;
                            break;
                        }
                    }
                }
            }
            if !copied {
                out.push_missing();
            }
        }
        Some(out)
    }

    fn coalesce_if_needed(&mut self) {
        if self.chunks.len() <= COALESCE_CHUNK_COUNT {
            return;
        }
        let mut sizes: Vec<usize> = self.chunks.iter().map(|c| c.live_len()).collect();
        sizes.sort_unstable();
        let median = sizes[sizes.len() / 2];

        let old = std::mem::take(&mut self.chunks);
        let mut run: Vec<Chunk<K>> = Vec::new();
        for chunk in old {
            if chunk.live_len() <= median {
                run.push(chunk);
            } else {
                self.flush_run(&mut run);
                self.chunks.push(chunk);
            }
        }
        self.flush_run(&mut run);
    }

    fn flush_run(&mut self, run: &mut Vec<Chunk<K>>) {
        match run.len() {
            0 => (),
            1 => self.chunks.push(run.pop().unwrap()),
            _ => {
                let merged = self.merge_run(run);
                run.clear();
                self.chunks.push(merged);
            }
        }
    }

    /// Merge an adjacent run of chunks (given oldest-first) into one, unioning
    /// fields per key with newest-wins. For duplicate-key stores the newest
    /// chunk holding a key contributes all of its rows for that key and older
    /// chunks' rows for it are dropped.
    fn merge_run(&self, run: &[Chunk<K>]) -> Chunk<K> {
        let mut entries: Vec<(K, usize, usize)> = Vec::new();
        for (pos, chunk) in run.iter().enumerate() {
            for row in chunk.start..chunk.keys.len() {
                entries.push((chunk.keys[row], pos, row));
            }
        }
        entries.sort_by(|a, b| a.0.cmp(&b.0).then(b.1.cmp(&a.1)).then(a.2.cmp(&b.2)));

        let mut cols: Vec<Option<AnyCol>> = (0..self.n_fields)
            .map(|f| {
                run.iter()
                    .rev()
                    .find_map(|c| c.cols[f].as_ref())
                    .map(|c| c.new_like())
            })
            .collect();
        let mut keys: Vec<K> = Vec::new();

        let mut i = 0;
        while i < entries.len() {
            let key = entries[i].0;
            let mut j = i;
            while j < entries.len() && entries[j].0 == key {
                j += 1;
            }
            let group = &entries[i..j];
            if self.unique_keys {
                keys.push(key);
                for (f, col) in cols.iter_mut().enumerate() {
                    if let Some(out) = col {
                        let cell = group.iter().find_map(|&(_, pos, row)| {
                            run[pos].cols[f]
                                .as_ref()
                                .filter(|c| c.is_valid(row))
                                .map(|c| (c, row))
                        });
                        match cell {
                            Some((src, row)) => out.copy_cell(src, row),
                            None => out.push_missing(),
                        }
                    }
                }
            } else {
                let newest_pos = group[0].1;
                for &(_, pos, row) in group.iter().filter(|&&(_, pos, _)| pos == newest_pos) {
                    keys.push(key);
                    for (f, col) in cols.iter_mut().enumerate() {
                        if let Some(out) = col {
                            match run[pos].cols[f].as_ref().filter(|c| c.is_valid(row)) {
                                Some(src) => out.copy_cell(src, row),
                                None => out.push_missing(),
                            }
                        }
                    }
                }
            }
            i = j;
        }

        Chunk::new(keys, cols)
    }

    /// The per-field scratch a `materialize` call decodes from: one gathered
    /// column per field whose bit is set in any row's mask, each already
    /// respecting the per-row masks. Built under the store lock; decoding then
    /// runs on the caller's own copy.
    pub(crate) fn gather_scratch(&self, keys: &[Option<K>], masks: &[u64]) -> Vec<Option<AnyCol>> {
        let hits = self.hit_lists(keys);
        let union = masks.iter().fold(0u64, |acc, &m| acc | m);
        (0..self.n_fields)
            .map(|f| {
                let bit = 1u64 << f;
                if union & bit == 0 {
                    None
                } else {
                    self.gather(&hits, f, |i| masks[i] & bit != 0)
                }
            })
            .collect()
    }
}

// ---- Fill: build one column from a response's rows. `None` when no row has a
// value, so absent fields cost nothing. ----

fn built(col: AnyCol) -> Option<AnyCol> {
    col.any_valid().then_some(col)
}

pub(crate) fn var_from<R>(rows: &[R], f: impl Fn(&R) -> Option<&[u8]>) -> Option<AnyCol> {
    let mut col = VarCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::Var(col))
}

pub(crate) fn fixed_from<R>(
    rows: &[R],
    width: usize,
    f: impl Fn(&R) -> Option<&[u8]>,
) -> Option<AnyCol> {
    let mut col = FixedCol::new(width);
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::Fixed(col))
}

pub(crate) fn u64_from<R>(rows: &[R], f: impl Fn(&R) -> Option<u64>) -> Option<AnyCol> {
    let mut col = NumCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::U64(col))
}

pub(crate) fn i64_from<R>(rows: &[R], f: impl Fn(&R) -> Option<i64>) -> Option<AnyCol> {
    let mut col = NumCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::I64(col))
}

pub(crate) fn f64_from<R>(rows: &[R], f: impl Fn(&R) -> Option<f64>) -> Option<AnyCol> {
    let mut col = NumCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::F64(col))
}

pub(crate) fn bool_from<R>(rows: &[R], f: impl Fn(&R) -> Option<bool>) -> Option<AnyCol> {
    let mut col = NumCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::Bool(col))
}

pub(crate) fn str_list_from<R>(
    rows: &[R],
    f: impl Fn(&R) -> Option<Vec<String>>,
) -> Option<AnyCol> {
    let mut col = ListCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::StrList(col))
}

pub(crate) fn hash_list_from<R>(
    rows: &[R],
    f: impl Fn(&R) -> Option<Vec<[u8; 32]>>,
) -> Option<AnyCol> {
    let mut col = ListCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::HashList(col))
}

pub(crate) fn access_lists_from<R>(
    rows: &[R],
    f: impl Fn(&R) -> Option<Vec<format::AccessList>>,
) -> Option<AnyCol> {
    let mut col = ListCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::AccessLists(col))
}

pub(crate) fn auth_lists_from<R>(
    rows: &[R],
    f: impl Fn(&R) -> Option<Vec<format::Authorization>>,
) -> Option<AnyCol> {
    let mut col = ListCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::AuthLists(col))
}

// ---- Decode: turn a gathered scratch column into per-row cells. A `None`
// column (field absent from every chunk) yields all-missing rows. The variant
// checks panic on mismatch since fill and decode for a field are written
// together. ----

pub(crate) fn bytes_cells<T>(
    col: Option<&AnyCol>,
    len: usize,
    f: impl Fn(&[u8]) -> anyhow::Result<Option<T>>,
) -> anyhow::Result<Vec<Option<T>>> {
    match col {
        None => Ok((0..len).map(|_| None).collect()),
        Some(AnyCol::Var(c)) => (0..len).map(|i| c.get(i).map_or(Ok(None), &f)).collect(),
        Some(AnyCol::Fixed(c)) => (0..len).map(|i| c.get(i).map_or(Ok(None), &f)).collect(),
        Some(_) => panic!("expected a byte column"),
    }
}

pub(crate) fn u64_cells<T>(
    col: Option<&AnyCol>,
    len: usize,
    f: impl Fn(u64) -> anyhow::Result<Option<T>>,
) -> anyhow::Result<Vec<Option<T>>> {
    match col {
        None => Ok((0..len).map(|_| None).collect()),
        Some(AnyCol::U64(c)) => (0..len).map(|i| c.get(i).map_or(Ok(None), &f)).collect(),
        Some(_) => panic!("expected a u64 column"),
    }
}

pub(crate) fn i64_cells(col: Option<&AnyCol>, len: usize) -> Vec<Option<i64>> {
    match col {
        None => vec![None; len],
        Some(AnyCol::I64(c)) => (0..len).map(|i| c.get(i)).collect(),
        Some(_) => panic!("expected an i64 column"),
    }
}

pub(crate) fn f64_cells(col: Option<&AnyCol>, len: usize) -> Vec<Option<f64>> {
    match col {
        None => vec![None; len],
        Some(AnyCol::F64(c)) => (0..len).map(|i| c.get(i)).collect(),
        Some(_) => panic!("expected an f64 column"),
    }
}

pub(crate) fn bool_cells(col: Option<&AnyCol>, len: usize) -> Vec<Option<bool>> {
    match col {
        None => vec![None; len],
        Some(AnyCol::Bool(c)) => (0..len).map(|i| c.get(i)).collect(),
        Some(_) => panic!("expected a bool column"),
    }
}

pub(crate) fn str_list_cells(col: Option<&AnyCol>, len: usize) -> Vec<Option<Vec<String>>> {
    match col {
        None => vec![None; len],
        Some(AnyCol::StrList(c)) => (0..len).map(|i| c.get(i).cloned()).collect(),
        Some(_) => panic!("expected a string-list column"),
    }
}

pub(crate) fn hash_list_cells<T>(
    col: Option<&AnyCol>,
    len: usize,
    f: impl Fn(&[u8; 32]) -> T,
) -> Vec<Option<Vec<T>>> {
    match col {
        None => (0..len).map(|_| None).collect(),
        Some(AnyCol::HashList(c)) => (0..len)
            .map(|i| c.get(i).map(|v| v.iter().map(&f).collect()))
            .collect(),
        Some(_) => panic!("expected a hash-list column"),
    }
}

pub(crate) fn access_lists_cells<T>(
    col: Option<&AnyCol>,
    len: usize,
    f: impl Fn(&format::AccessList) -> T,
) -> Vec<Option<Vec<T>>> {
    match col {
        None => (0..len).map(|_| None).collect(),
        Some(AnyCol::AccessLists(c)) => (0..len)
            .map(|i| c.get(i).map(|v| v.iter().map(&f).collect()))
            .collect(),
        Some(_) => panic!("expected an access-list column"),
    }
}

pub(crate) fn auth_lists_cells<T>(
    col: Option<&AnyCol>,
    len: usize,
    f: impl Fn(&format::Authorization) -> anyhow::Result<T>,
) -> anyhow::Result<Vec<Option<Vec<T>>>> {
    match col {
        None => Ok((0..len).map(|_| None).collect()),
        Some(AnyCol::AuthLists(c)) => (0..len)
            .map(|i| c.get(i).map(|v| v.iter().map(&f).collect()).transpose())
            .collect(),
        Some(_) => panic!("expected an authorization-list column"),
    }
}

/// Full-bytes hex, matching `Data`/`FixedSizeData::encode_hex` ("0x" when empty).
pub(crate) fn hex_full(b: &[u8]) -> String {
    if b.is_empty() {
        return "0x".into();
    }
    format!("0x{}", faster_hex::hex_string(b))
}

/// Quantity hex, matching `Quantity::encode_hex`: leading zeros trimmed, zero
/// itself is "0x0".
pub(crate) fn hex_quantity(b: &[u8]) -> String {
    let hex = faster_hex::hex_string(b);
    match hex.find(|c| c != '0') {
        Some(idx) => format!("0x{}", &hex[idx..]),
        None => "0x0".into(),
    }
}

/// UTF-8 cell back to the `String` it was stored from.
pub(crate) fn utf8(b: &[u8]) -> String {
    String::from_utf8_lossy(b).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestRow<'a> = (u64, Option<u64>, Option<&'a [u8]>);

    fn u64_chunk(rows: &[TestRow]) -> Chunk<u64> {
        let mut num = NumCol::new();
        let mut var = VarCol::new();
        for &(_, n, v) in rows {
            num.push(n);
            var.push(v);
        }
        Chunk::new(
            rows.iter().map(|&(k, ..)| k).collect(),
            vec![Some(AnyCol::U64(num)), Some(AnyCol::Var(var))],
        )
    }

    fn gathered_u64(store: &ChunkStore<u64>, keys: &[u64]) -> Vec<Option<u64>> {
        let keys: Vec<Option<u64>> = keys.iter().map(|&k| Some(k)).collect();
        let hits = store.hit_lists(&keys);
        match store.gather(&hits, 0, |_| true) {
            Some(AnyCol::U64(c)) => (0..keys.len()).map(|i| c.get(i)).collect(),
            Some(_) => panic!("wrong column kind"),
            None => vec![None; keys.len()],
        }
    }

    #[test]
    fn bitvec_push_get_truncate() {
        let mut bv = BitVec::new();
        for i in 0..130 {
            bv.push(i % 3 == 0);
        }
        assert_eq!(
            (bv.get(0), bv.get(1), bv.get(63), bv.get(64), bv.get(129)),
            (true, false, true, false, true)
        );
        bv.truncate(65);
        bv.push(true);
        assert_eq!((bv.len, bv.get(64), bv.get(65)), (66, false, true));
    }

    #[test]
    fn var_col_roundtrip_and_truncate() {
        let mut col = VarCol::new();
        col.push(Some(b"abc"));
        col.push(None);
        col.push(Some(b""));
        col.push(Some(b"xy"));
        assert_eq!(
            (col.get(0), col.get(1), col.get(2), col.get(3)),
            (
                Some(b"abc".as_slice()),
                None,
                Some(b"".as_slice()),
                Some(b"xy".as_slice())
            )
        );
        col.truncate(2);
        assert_eq!((col.offsets.len(), col.data.len()), (3, 3));
    }

    #[test]
    fn prune_drops_whole_chunks_and_watermarks_bisected() {
        let mut store = ChunkStore::new(2, true);
        store.push_chunk(u64_chunk(&[(1, Some(10), None), (2, Some(20), None)]));
        store.push_chunk(u64_chunk(&[(3, Some(30), None), (4, Some(40), None)]));

        store.prune(2);
        assert_eq!(
            (store.chunks.len(), gathered_u64(&store, &[1, 3])),
            (1, vec![None, Some(30)])
        );

        store.prune(3);
        assert_eq!(gathered_u64(&store, &[3, 4]), vec![None, Some(40)]);
    }

    #[test]
    fn rollback_truncates_tails_and_drops_above() {
        let mut store = ChunkStore::new(2, true);
        store.push_chunk(u64_chunk(&[(1, Some(10), None), (5, Some(50), None)]));
        store.push_chunk(u64_chunk(&[(6, Some(60), None)]));

        store.rollback(4);
        assert_eq!(
            (store.chunks.len(), gathered_u64(&store, &[1, 5, 6])),
            (1, vec![Some(10), None, None])
        );
    }

    #[test]
    fn field_union_resolves_newest_wins_per_field() {
        let mut store = ChunkStore::new(2, true);
        // Older chunk carries only the var field; newer chunk only the num field.
        let mut var = VarCol::new();
        var.push(Some(b"hash"));
        store.push_chunk(Chunk::new(vec![7], vec![None, Some(AnyCol::Var(var))]));
        let mut num = NumCol::new();
        num.push(Some(70));
        store.push_chunk(Chunk::new(vec![7], vec![Some(AnyCol::U64(num)), None]));

        let hits = store.hit_lists(&[Some(7)]);
        let num_cell = match store.gather(&hits, 0, |_| true) {
            Some(AnyCol::U64(c)) => c.get(0),
            _ => panic!("expected num column"),
        };
        let var_cell = match store.gather(&hits, 1, |_| true) {
            Some(AnyCol::Var(c)) => c.get(0).map(|b| b.to_vec()),
            _ => panic!("expected var column"),
        };
        assert_eq!((num_cell, var_cell), (Some(70), Some(b"hash".to_vec())));
    }

    #[test]
    fn gather_respects_selection_and_misses() {
        let mut store = ChunkStore::new(2, true);
        store.push_chunk(u64_chunk(&[(1, Some(10), None), (2, Some(20), None)]));
        let hits = store.hit_lists(&[Some(1), Some(2), Some(9)]);
        match store.gather(&hits, 0, |i| i != 1) {
            Some(AnyCol::U64(c)) => {
                assert_eq!((c.get(0), c.get(1), c.get(2)), (Some(10), None, None))
            }
            _ => panic!("expected num column"),
        }
    }

    #[test]
    fn coalesce_merges_small_runs_and_dedups_newest_wins() {
        let mut store = ChunkStore::new(2, true);
        // One large chunk keeps the median meaningful.
        let large: Vec<TestRow> =
            (1000..1200).map(|k| (k, Some(k), None)).collect();
        store.push_chunk(u64_chunk(&large));
        for i in 0..COALESCE_CHUNK_COUNT {
            let k = i as u64;
            store.push_chunk(u64_chunk(&[(k, Some(k * 10), None)]));
        }
        // Duplicate of key 0 with a different value: the newest must win.
        store.push_chunk(u64_chunk(&[(0, Some(999), None)]));

        assert!(store.chunks.len() <= 4);
        assert_eq!(
            gathered_u64(&store, &[0, 5, 1100]),
            vec![Some(999), Some(50), Some(1100)]
        );
    }

    #[test]
    fn duplicate_key_store_keeps_newest_chunks_rows_on_merge() {
        let mut store = ChunkStore::new(1, false);
        let make = |rows: &[(u64, u64)]| {
            let mut num = NumCol::new();
            for &(_, v) in rows {
                num.push(Some(v));
            }
            Chunk::new(
                rows.iter().map(|&(k, _)| k).collect(),
                vec![Some(AnyCol::U64(num))],
            )
        };
        let mut run = vec![make(&[(1, 10), (1, 11), (2, 20)]), make(&[(1, 12)])];
        let merged = store.merge_run(&std::mem::take(&mut run));
        store.push_chunk(merged);

        let chunk = &store.chunks[0];
        let vals: Vec<Option<u64>> = match &chunk.cols[0] {
            Some(AnyCol::U64(c)) => (0..chunk.keys.len()).map(|i| c.get(i)).collect(),
            _ => panic!("expected num column"),
        };
        // Key 1 resolves to the newest chunk's single row; key 2 survives.
        assert_eq!(
            (chunk.keys.clone(), vals),
            (vec![1, 2], vec![Some(12), Some(20)])
        );
    }
}
