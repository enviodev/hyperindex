//! Flat columnar storage shared by the per-chain field stores, deduping on
//! insert: each key owns one slot, and a batch merges into existing slots
//! field-by-field rather than appending immutable chunks. A key re-fetched by
//! overlapping partitions overwrites in place instead of accumulating a copy
//! per response, and a batch that only carries a subset of fields unions it
//! into whatever the key already has (newest write per field wins).

use std::collections::{BTreeMap, HashMap};

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
}

/// Variable-width UTF-8 string cells: like `VarCol`, but the shared buffer is a
/// `String` rather than raw bytes. A cell is always pushed from a `&str`, so
/// the buffer's UTF-8 validity is an invariant maintained by construction —
/// `get` slices it directly with no re-validation, unlike round-tripping a
/// string through a byte column and `String::from_utf8_lossy` on every read.
pub(crate) struct StrCol {
    offsets: Vec<u32>,
    data: String,
    validity: BitVec,
}

impl StrCol {
    fn new() -> Self {
        Self {
            offsets: vec![0],
            data: String::new(),
            validity: BitVec::new(),
        }
    }

    pub(crate) fn push(&mut self, v: Option<&str>) {
        if let Some(s) = v {
            self.data.push_str(s);
        }
        self.offsets.push(self.data.len() as u32);
        self.validity.push(v.is_some());
    }

    pub(crate) fn get(&self, i: usize) -> Option<&str> {
        self.validity
            .get(i)
            .then(|| &self.data[self.offsets[i] as usize..self.offsets[i + 1] as usize])
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
}

/// One field's column. The variant is fixed per field by the fill code and
/// relied upon by the decode code and `StoreCol`.
pub(crate) enum AnyCol {
    U64(NumCol<u64>),
    I64(NumCol<i64>),
    F64(NumCol<f64>),
    Bool(NumCol<bool>),
    Fixed(FixedCol),
    Var(VarCol),
    Str(StrCol),
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
    pub(crate) fn new_str() -> Self {
        AnyCol::Str(StrCol::new())
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

    fn is_valid(&self, i: usize) -> bool {
        match self {
            AnyCol::U64(c) => c.validity.get(i),
            AnyCol::I64(c) => c.validity.get(i),
            AnyCol::F64(c) => c.validity.get(i),
            AnyCol::Bool(c) => c.validity.get(i),
            AnyCol::Fixed(c) => c.validity.get(i),
            AnyCol::Var(c) => c.validity.get(i),
            AnyCol::Str(c) => c.validity.get(i),
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
            AnyCol::Str(c) => c.validity.any(),
            AnyCol::StrList(c) => c.rows.iter().any(|r| r.is_some()),
            AnyCol::HashList(c) => c.rows.iter().any(|r| r.is_some()),
            AnyCol::AccessLists(c) => c.rows.iter().any(|r| r.is_some()),
            AnyCol::AuthLists(c) => c.rows.iter().any(|r| r.is_some()),
        }
    }

    /// Raw bytes of a byte-backed cell (hash comparison); `None` when the row
    /// is invalid. Panics on a non-byte-backed column.
    pub(crate) fn cell_bytes(&self, row: usize) -> Option<&[u8]> {
        if !self.is_valid(row) {
            return None;
        }
        match self {
            AnyCol::Fixed(c) => c.get(row),
            AnyCol::Var(c) => c.get(row),
            AnyCol::Str(c) => c.get(row).map(str::as_bytes),
            _ => panic!("expected a byte-backed column"),
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
            AnyCol::Str(c) => c.push(None),
            AnyCol::StrList(c) => c.push(None),
            AnyCol::HashList(c) => c.push(None),
            AnyCol::AccessLists(c) => c.push(None),
            AnyCol::AuthLists(c) => c.push(None),
        }
    }
}

/// One field's column, addressed by table slot. Variable-width and list cells
/// are individually boxed so overwriting a slot frees the old allocation
/// immediately rather than leaking until some later compaction.
pub(crate) enum StoreCol {
    U64(Vec<u64>),
    I64(Vec<i64>),
    F64(Vec<f64>),
    Bool(Vec<bool>),
    Fixed { width: usize, data: Vec<u8> },
    Var(Vec<Option<Box<[u8]>>>),
    Str(Vec<Option<Box<str>>>),
    StrList(Vec<Option<Box<[String]>>>),
    HashList(Vec<Option<Box<[[u8; 32]]>>>),
    AccessLists(Vec<Option<Box<[format::AccessList]>>>),
    AuthLists(Vec<Option<Box<[format::Authorization]>>>),
}

impl StoreCol {
    /// An empty column matching `template`'s kind (and width, for `Fixed`).
    fn new_like(template: &AnyCol) -> Self {
        match template {
            AnyCol::U64(_) => StoreCol::U64(Vec::new()),
            AnyCol::I64(_) => StoreCol::I64(Vec::new()),
            AnyCol::F64(_) => StoreCol::F64(Vec::new()),
            AnyCol::Bool(_) => StoreCol::Bool(Vec::new()),
            AnyCol::Fixed(c) => StoreCol::Fixed {
                width: c.width,
                data: Vec::new(),
            },
            AnyCol::Var(_) => StoreCol::Var(Vec::new()),
            AnyCol::Str(_) => StoreCol::Str(Vec::new()),
            AnyCol::StrList(_) => StoreCol::StrList(Vec::new()),
            AnyCol::HashList(_) => StoreCol::HashList(Vec::new()),
            AnyCol::AccessLists(_) => StoreCol::AccessLists(Vec::new()),
            AnyCol::AuthLists(_) => StoreCol::AuthLists(Vec::new()),
        }
    }

    /// A fresh `AnyCol` of the same kind, to gather cells back into for the
    /// interchange (decode) layer.
    fn new_scratch(&self) -> AnyCol {
        match self {
            StoreCol::U64(_) => AnyCol::new_u64(),
            StoreCol::I64(_) => AnyCol::new_i64(),
            StoreCol::F64(_) => AnyCol::new_f64(),
            StoreCol::Bool(_) => AnyCol::new_bool(),
            StoreCol::Fixed { width, .. } => AnyCol::new_fixed(*width),
            StoreCol::Var(_) => AnyCol::new_var(),
            StoreCol::Str(_) => AnyCol::new_str(),
            StoreCol::StrList(_) => AnyCol::new_str_list(),
            StoreCol::HashList(_) => AnyCol::new_hash_list(),
            StoreCol::AccessLists(_) => AnyCol::new_access_lists(),
            StoreCol::AuthLists(_) => AnyCol::new_auth_lists(),
        }
    }

    /// Grow by one empty slot (a just-allocated table row).
    fn push_empty(&mut self) {
        match self {
            StoreCol::U64(v) => v.push(0),
            StoreCol::I64(v) => v.push(0),
            StoreCol::F64(v) => v.push(0.0),
            StoreCol::Bool(v) => v.push(false),
            StoreCol::Fixed { width, data } => data.resize(data.len() + *width, 0),
            StoreCol::Var(v) => v.push(None),
            StoreCol::Str(v) => v.push(None),
            StoreCol::StrList(v) => v.push(None),
            StoreCol::HashList(v) => v.push(None),
            StoreCol::AccessLists(v) => v.push(None),
            StoreCol::AuthLists(v) => v.push(None),
        }
    }

    /// Reset a freed slot, dropping any boxed cell it held.
    fn clear(&mut self, slot: usize) {
        match self {
            StoreCol::U64(v) => v[slot] = 0,
            StoreCol::I64(v) => v[slot] = 0,
            StoreCol::F64(v) => v[slot] = 0.0,
            StoreCol::Bool(v) => v[slot] = false,
            StoreCol::Fixed { width, data } => data[slot * *width..(slot + 1) * *width].fill(0),
            StoreCol::Var(v) => v[slot] = None,
            StoreCol::Str(v) => v[slot] = None,
            StoreCol::StrList(v) => v[slot] = None,
            StoreCol::HashList(v) => v[slot] = None,
            StoreCol::AccessLists(v) => v[slot] = None,
            StoreCol::AuthLists(v) => v[slot] = None,
        }
    }

    /// Overwrite `slot` from `src`'s row `row`. Caller must check
    /// `src.is_valid(row)` first.
    fn set_from(&mut self, slot: usize, src: &AnyCol, row: usize) {
        match (self, src) {
            (StoreCol::U64(v), AnyCol::U64(s)) => v[slot] = s.get(row).unwrap(),
            (StoreCol::I64(v), AnyCol::I64(s)) => v[slot] = s.get(row).unwrap(),
            (StoreCol::F64(v), AnyCol::F64(s)) => v[slot] = s.get(row).unwrap(),
            (StoreCol::Bool(v), AnyCol::Bool(s)) => v[slot] = s.get(row).unwrap(),
            (StoreCol::Fixed { width, data }, AnyCol::Fixed(s)) => {
                let b = s.get(row).unwrap();
                debug_assert_eq!(b.len(), *width);
                data[slot * *width..(slot + 1) * *width].copy_from_slice(b);
            }
            (StoreCol::Var(v), AnyCol::Var(s)) => {
                v[slot] = Some(s.get(row).unwrap().to_vec().into_boxed_slice())
            }
            (StoreCol::Str(v), AnyCol::Str(s)) => v[slot] = Some(s.get(row).unwrap().into()),
            (StoreCol::StrList(v), AnyCol::StrList(s)) => {
                v[slot] = Some(s.get(row).unwrap().clone().into_boxed_slice())
            }
            (StoreCol::HashList(v), AnyCol::HashList(s)) => {
                v[slot] = Some(s.get(row).unwrap().clone().into_boxed_slice())
            }
            (StoreCol::AccessLists(v), AnyCol::AccessLists(s)) => {
                v[slot] = Some(s.get(row).unwrap().clone().into_boxed_slice())
            }
            (StoreCol::AuthLists(v), AnyCol::AuthLists(s)) => {
                v[slot] = Some(s.get(row).unwrap().clone().into_boxed_slice())
            }
            _ => panic!("column kind mismatch for one field across batches"),
        }
    }

    /// Append `slot`'s current value onto `dst`, an `AnyCol` of matching kind
    /// built by `new_scratch`.
    fn copy_to(&self, dst: &mut AnyCol, slot: usize) {
        match (self, dst) {
            (StoreCol::U64(v), AnyCol::U64(d)) => d.push(Some(v[slot])),
            (StoreCol::I64(v), AnyCol::I64(d)) => d.push(Some(v[slot])),
            (StoreCol::F64(v), AnyCol::F64(d)) => d.push(Some(v[slot])),
            (StoreCol::Bool(v), AnyCol::Bool(d)) => d.push(Some(v[slot])),
            (StoreCol::Fixed { width, data }, AnyCol::Fixed(d)) => {
                d.push(Some(&data[slot * *width..(slot + 1) * *width]))
            }
            (StoreCol::Var(v), AnyCol::Var(d)) => d.push(v[slot].as_deref()),
            (StoreCol::Str(v), AnyCol::Str(d)) => d.push(v[slot].as_deref()),
            (StoreCol::StrList(v), AnyCol::StrList(d)) => {
                d.push(v[slot].as_deref().map(<[String]>::to_vec))
            }
            (StoreCol::HashList(v), AnyCol::HashList(d)) => {
                d.push(v[slot].as_deref().map(<[[u8; 32]]>::to_vec))
            }
            (StoreCol::AccessLists(v), AnyCol::AccessLists(d)) => {
                d.push(v[slot].as_deref().map(<[format::AccessList]>::to_vec))
            }
            (StoreCol::AuthLists(v), AnyCol::AuthLists(d)) => {
                d.push(v[slot].as_deref().map(<[format::Authorization]>::to_vec))
            }
            _ => panic!("column kind mismatch for one field"),
        }
    }

    /// Raw byte cell, for the token-balance table's direct-by-slot reads
    /// (bypassing the `AnyCol` interchange layer since there's no per-row
    /// decode step there). Panics on a non-`Var` column.
    fn var_cell(&self, slot: usize) -> Option<&[u8]> {
        match self {
            StoreCol::Var(v) => v[slot].as_deref(),
            _ => panic!("expected a var column"),
        }
    }

    /// Raw bytes of a byte-backed cell (hash comparison). `Fixed` carries no
    /// per-slot validity, so the caller must have checked the row's mask bit.
    fn cell_bytes(&self, slot: usize) -> Option<&[u8]> {
        match self {
            StoreCol::Fixed { width, data } => Some(&data[slot * *width..(slot + 1) * *width]),
            StoreCol::Var(v) => v[slot].as_deref(),
            StoreCol::Str(v) => v[slot].as_deref().map(str::as_bytes),
            _ => panic!("expected a byte-backed column"),
        }
    }
}

/// Merge-on-insert columnar table: one slot per distinct key. `by_key` backs
/// point lookup and insert dedup; `order` backs the range scans prune,
/// rollback, and token-balance read need. `free` holds freed slots for reuse,
/// so capacity never shrinks but also never leaks.
pub(crate) struct Table<K> {
    by_key: HashMap<K, u32>,
    order: BTreeMap<K, u32>,
    masks: Vec<u64>,
    cols: Vec<Option<StoreCol>>,
    free: Vec<u32>,
    len: usize,
    n_fields: usize,
}

impl<K: Ord + Clone + std::hash::Hash> Table<K> {
    pub(crate) fn new(n_fields: usize) -> Self {
        Self {
            by_key: HashMap::new(),
            order: BTreeMap::new(),
            masks: Vec::new(),
            cols: (0..n_fields).map(|_| None).collect(),
            free: Vec::new(),
            len: 0,
            n_fields,
        }
    }

    fn alloc_slot(&mut self) -> u32 {
        match self.free.pop() {
            Some(slot) => slot,
            None => {
                let slot = self.len as u32;
                self.len += 1;
                for col in self.cols.iter_mut().flatten() {
                    col.push_empty();
                }
                self.masks.push(0);
                slot
            }
        }
    }

    fn slot_for(&mut self, key: K) -> u32 {
        if let Some(&slot) = self.by_key.get(&key) {
            return slot;
        }
        let slot = self.alloc_slot();
        self.order.insert(key.clone(), slot);
        self.by_key.insert(key, slot);
        slot
    }

    fn ensure_col(&mut self, field: usize, template: &AnyCol) {
        if self.cols[field].is_none() {
            let mut col = StoreCol::new_like(template);
            for _ in 0..self.len {
                col.push_empty();
            }
            self.cols[field] = Some(col);
        }
    }

    fn free_slot(&mut self, slot: u32) {
        for col in self.cols.iter_mut().flatten() {
            col.clear(slot as usize);
        }
        self.masks[slot as usize] = 0;
        self.free.push(slot);
    }

    /// Merge one batch's rows into the table, per field: a field the batch
    /// has no valid cell for is left untouched, so a sparser batch only ever
    /// adds coverage to a key's existing row. Keys need not be sorted or
    /// unique within the batch.
    pub(crate) fn merge_batch(&mut self, keys: Vec<K>, cols: Vec<Option<AnyCol>>) {
        debug_assert_eq!(cols.len(), self.n_fields);
        for (row, key) in keys.into_iter().enumerate() {
            let slot = self.slot_for(key) as usize;
            for (f, col_opt) in cols.iter().enumerate() {
                if let Some(col) = col_opt {
                    if col.is_valid(row) {
                        self.ensure_col(f, col);
                        self.cols[f].as_mut().unwrap().set_from(slot, col, row);
                        self.masks[slot] |= 1u64 << f;
                    }
                }
            }
        }
    }

    /// Move every live row from `other` into this table (a fetch-response page
    /// merging into the persistent per-chain table). `other` is left empty.
    pub(crate) fn append_from(&mut self, other: &mut Table<K>) {
        let live_keys: Vec<K> = other.order.keys().cloned().collect();
        if live_keys.is_empty() {
            return;
        }
        let slots: Vec<u32> = live_keys.iter().map(|k| other.by_key[k]).collect();
        let cols: Vec<Option<AnyCol>> = (0..other.n_fields)
            .map(|f| {
                other.cols[f].as_ref().map(|col| {
                    let mut out = col.new_scratch();
                    for &slot in &slots {
                        if other.masks[slot as usize] & (1u64 << f) != 0 {
                            col.copy_to(&mut out, slot as usize);
                        } else {
                            out.push_missing();
                        }
                    }
                    out
                })
            })
            .collect();
        self.merge_batch(live_keys, cols);
        other.clear();
    }

    /// Bytes of `field`'s cell for `key`, if the row exists and carries the
    /// field.
    pub(crate) fn field_bytes(&self, key: &K, field: usize) -> Option<&[u8]> {
        let &slot = self.by_key.get(key)?;
        if self.masks[slot as usize] & (1u64 << field) == 0 {
            return None;
        }
        self.cols[field]
            .as_ref()
            .and_then(|c| c.cell_bytes(slot as usize))
    }

    /// Lowest key `>= from` carrying `field` in both tables whose cells differ.
    pub(crate) fn first_field_mismatch(
        &self,
        other: &Table<K>,
        field: usize,
        from: K,
    ) -> Option<K> {
        for key in other.order.range(from..).map(|(k, _)| k) {
            if let (Some(a), Some(b)) =
                (self.field_bytes(key, field), other.field_bytes(key, field))
            {
                if a != b {
                    return Some(key.clone());
                }
            }
        }
        None
    }

    /// Lowest key whose incoming `field` cell conflicts with what's already
    /// written — either the table's stored cell or an earlier row of the same
    /// batch (a within-response duplicate with a different hash). Returns the
    /// conflicting (key, stored, received) byte values. Run before
    /// `merge_batch`, which would silently overwrite.
    pub(crate) fn detect_field_conflict(
        &self,
        keys: &[K],
        col: Option<&AnyCol>,
        field: usize,
    ) -> Option<(K, Vec<u8>, Vec<u8>)> {
        let col = col?;
        let mut best: Option<(K, Vec<u8>, Vec<u8>)> = None;
        let mut batch_last_row: HashMap<K, usize> = HashMap::new();
        for (row, key) in keys.iter().enumerate() {
            let Some(new) = col.cell_bytes(row) else {
                continue;
            };
            let old = match batch_last_row.get(key) {
                Some(&prev_row) => col.cell_bytes(prev_row),
                None => self.field_bytes(key, field),
            };
            if let Some(old) = old {
                if old != new && best.as_ref().is_none_or(|(k, _, _)| key < k) {
                    best = Some((key.clone(), old.to_vec(), new.to_vec()));
                }
            }
            batch_last_row.insert(key.clone(), row);
        }
        best
    }

    /// Drop rows with keys `<= up_to` (processed), except rows with keys
    /// `>= keep_from` that carry `field`: those are reduced to that one field,
    /// so it stays readable after the rest of the row is gone.
    pub(crate) fn prune_keeping_field(&mut self, up_to: K, keep_from: K, field: usize) {
        let bit = 1u64 << field;
        let pruned: Vec<K> = self.order.range(..=up_to).map(|(k, _)| k.clone()).collect();
        for k in pruned {
            let slot = self.by_key[&k];
            if k >= keep_from && self.masks[slot as usize] & bit != 0 {
                let mask = self.masks[slot as usize];
                for f in 0..self.n_fields {
                    if f != field && mask & (1u64 << f) != 0 {
                        self.cols[f].as_mut().unwrap().clear(slot as usize);
                    }
                }
                self.masks[slot as usize] = bit;
            } else {
                self.by_key.remove(&k);
                self.order.remove(&k);
                self.free_slot(slot);
            }
        }
    }

    /// Keys in `[from, below)` whose row carries `field`, ascending.
    pub(crate) fn keys_with_field(&self, from: K, below: K, field: usize) -> Vec<K> {
        let bit = 1u64 << field;
        self.order
            .range(from..below)
            .filter(|(_, &slot)| self.masks[slot as usize] & bit != 0)
            .map(|(k, _)| k.clone())
            .collect()
    }

    /// Drop rows with keys `<= up_to` (processed).
    pub(crate) fn prune(&mut self, up_to: K) {
        let dead: Vec<K> = self.order.range(..=up_to).map(|(k, _)| k.clone()).collect();
        for k in dead {
            if let Some(slot) = self.by_key.remove(&k) {
                self.order.remove(&k);
                self.free_slot(slot);
            }
        }
    }

    /// Reduce rows with keys `> target` to `field` only (a non-reorg chain's
    /// rollback: buffered blocks will be refetched, but the scanned hashes are
    /// still valid for reorg detection). Rows without the field are dropped.
    pub(crate) fn rollback_keeping_field(&mut self, target: K, field: usize) {
        let bit = 1u64 << field;
        let affected: Vec<K> = self
            .order
            .range((
                std::ops::Bound::Excluded(target),
                std::ops::Bound::Unbounded,
            ))
            .map(|(k, _)| k.clone())
            .collect();
        for k in affected {
            let slot = self.by_key[&k];
            if self.masks[slot as usize] & bit != 0 {
                let mask = self.masks[slot as usize];
                for f in 0..self.n_fields {
                    if f != field && mask & (1u64 << f) != 0 {
                        self.cols[f].as_mut().unwrap().clear(slot as usize);
                    }
                }
                self.masks[slot as usize] = bit;
            } else {
                self.by_key.remove(&k);
                self.order.remove(&k);
                self.free_slot(slot);
            }
        }
    }

    /// Drop rows with keys `> target` (rolled back).
    pub(crate) fn rollback(&mut self, target: K) {
        let dead: Vec<K> = self
            .order
            .range((
                std::ops::Bound::Excluded(target),
                std::ops::Bound::Unbounded,
            ))
            .map(|(k, _)| k.clone())
            .collect();
        for k in dead {
            if let Some(slot) = self.by_key.remove(&k) {
                self.order.remove(&k);
                self.free_slot(slot);
            }
        }
    }

    pub(crate) fn clear(&mut self) {
        self.by_key.clear();
        self.order.clear();
        self.masks.clear();
        self.cols = (0..self.n_fields).map(|_| None).collect();
        self.free.clear();
        self.len = 0;
    }

    /// The per-field scratch a `materialize` call decodes from: resolves each
    /// requested key to its slot once, then gathers a column per field whose
    /// bit is set in any row's mask, respecting both the caller's per-row mask
    /// and the slot's own field presence.
    pub(crate) fn gather_scratch(&self, keys: &[Option<K>], masks: &[u64]) -> Vec<Option<AnyCol>> {
        let slots: Vec<Option<u32>> = keys
            .iter()
            .map(|k| k.as_ref().and_then(|k| self.by_key.get(k)).copied())
            .collect();
        let union = masks.iter().fold(0u64, |acc, &m| acc | m);
        (0..self.n_fields)
            .map(|f| {
                let bit = 1u64 << f;
                if union & bit == 0 {
                    return None;
                }
                self.cols[f].as_ref().map(|col| {
                    let mut out = col.new_scratch();
                    for (i, slot) in slots.iter().enumerate() {
                        let present = masks[i] & bit != 0
                            && slot.is_some_and(|s| self.masks[s as usize] & bit != 0);
                        match (present, slot) {
                            (true, Some(s)) => col.copy_to(&mut out, *s as usize),
                            _ => out.push_missing(),
                        }
                    }
                    out
                })
            })
            .collect()
    }
}

/// Account-keyed token-balance table only: the account is the key's third
/// component (force-added to the SVM query's field selection whenever token
/// balances are requested, so it's always available to key on), so it isn't
/// stored as its own column.
impl Table<(u64, u32, Box<str>)> {
    /// All slots for `(block, tx_index)`, in account order. `""` sorts before
    /// any real account, so the range starts exactly at the pair's first row.
    pub(crate) fn range_slots(
        &self,
        block: u64,
        tx_index: u32,
    ) -> impl Iterator<Item = (&(u64, u32, Box<str>), u32)> {
        self.order
            .range((block, tx_index, Box::from(""))..)
            .take_while(move |(k, _)| k.0 == block && k.1 == tx_index)
            .map(|(k, &slot)| (k, slot))
    }

    /// Raw string bytes for one token-balance field at `slot`, or `None` if
    /// the field was never populated for that row.
    pub(crate) fn var_cell(&self, field: usize, slot: u32) -> Option<&[u8]> {
        if self.masks[slot as usize] & (1u64 << field) == 0 {
            return None;
        }
        self.cols[field]
            .as_ref()
            .and_then(|c| c.var_cell(slot as usize))
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

/// Like `var_from`, for fields that are already text (e.g. a base58 hash) —
/// storing them as `StrCol` skips the bytes↔text round-trip `var_from` +
/// `utf8` would otherwise pay on every read.
pub(crate) fn str_from<R>(rows: &[R], f: impl Fn(&R) -> Option<&str>) -> Option<AnyCol> {
    let mut col = StrCol::new();
    rows.iter().for_each(|r| col.push(f(r)));
    built(AnyCol::Str(col))
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

/// Decode a `StrCol` straight into owned `String` cells — no UTF-8 validation,
/// since the column's buffer is a `String` by construction.
pub(crate) fn str_cells(col: Option<&AnyCol>, len: usize) -> Vec<Option<String>> {
    match col {
        None => vec![None; len],
        Some(AnyCol::Str(c)) => (0..len).map(|i| c.get(i).map(str::to_string)).collect(),
        Some(_) => panic!("expected a string column"),
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

    fn u64_batch(rows: &[TestRow]) -> (Vec<u64>, Vec<Option<AnyCol>>) {
        let keys = rows.iter().map(|&(k, ..)| k).collect();
        let mut num = NumCol::new();
        let mut var = VarCol::new();
        for &(_, n, v) in rows {
            num.push(n);
            var.push(v);
        }
        (keys, vec![Some(AnyCol::U64(num)), Some(AnyCol::Var(var))])
    }

    fn gathered_u64(table: &Table<u64>, keys: &[u64]) -> Vec<Option<u64>> {
        let keys: Vec<Option<u64>> = keys.iter().map(|&k| Some(k)).collect();
        let masks = vec![1u64; keys.len()];
        match &table.gather_scratch(&keys, &masks)[0] {
            Some(AnyCol::U64(c)) => (0..keys.len()).map(|i| c.get(i)).collect(),
            Some(_) => panic!("wrong column kind"),
            None => vec![None; keys.len()],
        }
    }

    #[test]
    fn bitvec_push_get() {
        let mut bv = BitVec::new();
        for i in 0..130 {
            bv.push(i % 3 == 0);
        }
        assert_eq!(
            (bv.get(0), bv.get(1), bv.get(63), bv.get(64), bv.get(129)),
            (true, false, true, false, true)
        );
    }

    #[test]
    fn var_col_roundtrip() {
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
    }

    #[test]
    fn str_col_roundtrip() {
        let mut col = StrCol::new();
        col.push(Some("abc"));
        col.push(None);
        col.push(Some(""));
        col.push(Some("xy"));
        assert_eq!(
            (col.get(0), col.get(1), col.get(2), col.get(3)),
            (Some("abc"), None, Some(""), Some("xy"))
        );
    }

    #[test]
    fn merge_batch_and_gather_roundtrip() {
        let mut table = Table::new(2);
        let (keys, cols) = u64_batch(&[(1, Some(10), None), (2, Some(20), None)]);
        table.merge_batch(keys, cols);
        assert_eq!(
            gathered_u64(&table, &[1, 2, 9]),
            vec![Some(10), Some(20), None]
        );
    }

    #[test]
    fn prune_drops_rows_and_frees_slots_for_reuse() {
        let mut table = Table::new(2);
        let (keys, cols) = u64_batch(&[(1, Some(10), None), (2, Some(20), None)]);
        table.merge_batch(keys, cols);
        let (keys, cols) = u64_batch(&[(3, Some(30), None), (4, Some(40), None)]);
        table.merge_batch(keys, cols);

        table.prune(2);
        assert_eq!(
            gathered_u64(&table, &[1, 2, 3, 4]),
            vec![None, None, Some(30), Some(40)]
        );
        assert_eq!(table.free.len(), 2);

        // The two freed slots are reused rather than growing the table further.
        let (keys, cols) = u64_batch(&[(5, Some(50), None), (6, Some(60), None)]);
        table.merge_batch(keys, cols);
        assert_eq!(table.len, 4);
        assert_eq!(gathered_u64(&table, &[5, 6]), vec![Some(50), Some(60)]);
    }

    #[test]
    fn rollback_drops_rows_above_target() {
        let mut table = Table::new(2);
        let (keys, cols) = u64_batch(&[(1, Some(10), None), (5, Some(50), None)]);
        table.merge_batch(keys, cols);
        let (keys, cols) = u64_batch(&[(6, Some(60), None)]);
        table.merge_batch(keys, cols);

        table.rollback(4);
        assert_eq!(gathered_u64(&table, &[1, 5, 6]), vec![Some(10), None, None]);
    }

    #[test]
    fn field_union_resolves_newest_wins_per_field() {
        let mut table = Table::new(2);
        // One batch carries only the var field for key 7; a later batch only
        // the num field. Both must resolve on read.
        let mut var = VarCol::new();
        var.push(Some(b"hash"));
        table.merge_batch(vec![7], vec![None, Some(AnyCol::Var(var))]);
        let mut num = NumCol::new();
        num.push(Some(70));
        table.merge_batch(vec![7], vec![Some(AnyCol::U64(num)), None]);

        let keys = vec![Some(7u64)];
        let masks = vec![0b11u64];
        let scratch = table.gather_scratch(&keys, &masks);
        let num_cell = match &scratch[0] {
            Some(AnyCol::U64(c)) => c.get(0),
            _ => panic!("expected num column"),
        };
        let var_cell = match &scratch[1] {
            Some(AnyCol::Var(c)) => c.get(0).map(|b| b.to_vec()),
            _ => panic!("expected var column"),
        };
        assert_eq!((num_cell, var_cell), (Some(70), Some(b"hash".to_vec())));
    }

    #[test]
    fn overlapping_batches_store_a_repeated_keys_var_field_once() {
        // Two responses both carry the same key (e.g. an overlapping partition
        // re-fetch of one transaction's `input`): the second merge must
        // overwrite the slot in place instead of appending a new row, so the
        // value is stored once, not once per response.
        let mut table = Table::new(1);
        let mut first = VarCol::new();
        first.push(Some(b"first-input"));
        table.merge_batch(vec![1u64], vec![Some(AnyCol::Var(first))]);
        assert_eq!(table.len, 1);

        let mut second = VarCol::new();
        second.push(Some(b"second-input"));
        table.merge_batch(vec![1u64], vec![Some(AnyCol::Var(second))]);

        // Still exactly one slot, holding the newest value: the key
        // deduplicated instead of growing the table, and overwriting dropped
        // (rather than retained) the first response's blob.
        assert_eq!(table.len, 1);
        match &table.cols[0] {
            Some(StoreCol::Var(v)) => {
                assert_eq!(v.len(), 1);
                assert_eq!(v[0].as_deref(), Some(b"second-input".as_slice()));
            }
            _ => panic!("expected var column"),
        }
    }

    #[test]
    fn gather_respects_selection_and_misses() {
        let mut table = Table::new(2);
        let (keys, cols) = u64_batch(&[(1, Some(10), None), (2, Some(20), None)]);
        table.merge_batch(keys, cols);

        let keys = vec![Some(1u64), Some(2), Some(9)];
        let masks = vec![1u64, 0, 1];
        match &table.gather_scratch(&keys, &masks)[0] {
            Some(AnyCol::U64(c)) => {
                assert_eq!((c.get(0), c.get(1), c.get(2)), (Some(10), None, None))
            }
            _ => panic!("expected num column"),
        }
    }

    #[test]
    fn append_from_merges_a_page_into_the_persistent_table() {
        // Mirrors a re-fetched (e.g. reorg-replaced) row: two pages for the
        // same key merge into the persistent table one after another, and the
        // second must win.
        let mut persistent = Table::new(1);
        let mut page1 = Table::new(1);
        let mut first = NumCol::new();
        first.push(Some(100u64));
        page1.merge_batch(vec![20u64], vec![Some(AnyCol::U64(first))]);
        persistent.append_from(&mut page1);

        let mut page2 = Table::new(1);
        let mut second = NumCol::new();
        second.push(Some(200u64));
        page2.merge_batch(vec![20u64], vec![Some(AnyCol::U64(second))]);
        persistent.append_from(&mut page2);

        assert_eq!(gathered_u64(&persistent, &[20]), vec![Some(200)]);
        assert_eq!(persistent.len, 1);
        assert_eq!(page2.len, 0);
    }

    #[test]
    fn token_balance_table_range_read_by_slot_and_tx() {
        let mut table: Table<(u64, u32, Box<str>)> = Table::new(1);
        let key = |account: &str| (5u64, 0u32, Box::<str>::from(account));
        let mut mint_a = VarCol::new();
        mint_a.push(Some(b"mintA"));
        table.merge_batch(vec![key("acctA")], vec![Some(AnyCol::Var(mint_a))]);
        let mut mint_b = VarCol::new();
        mint_b.push(Some(b"mintB"));
        table.merge_batch(vec![key("acctB")], vec![Some(AnyCol::Var(mint_b))]);
        // A different transaction in the same slot must not leak into the range.
        let mut mint_c = VarCol::new();
        mint_c.push(Some(b"mintC"));
        table.merge_batch(
            vec![(5u64, 1u32, Box::<str>::from("acctC"))],
            vec![Some(AnyCol::Var(mint_c))],
        );

        let rows: Vec<(String, Vec<u8>)> = table
            .range_slots(5, 0)
            .map(|(k, slot)| (k.2.to_string(), table.var_cell(0, slot).unwrap().to_vec()))
            .collect();
        assert_eq!(
            rows,
            vec![
                ("acctA".to_string(), b"mintA".to_vec()),
                ("acctB".to_string(), b"mintB".to_vec()),
            ]
        );
    }

    #[test]
    fn clear_drops_all_rows_and_resets_growth() {
        let mut table = Table::new(2);
        let (keys, cols) = u64_batch(&[(1, Some(10), None), (2, Some(20), None)]);
        table.merge_batch(keys, cols);

        table.clear();
        assert_eq!(
            (table.len, table.free.len(), gathered_u64(&table, &[1, 2])),
            (0, 0, vec![None, None])
        );

        // The table is fully usable afterwards, growing fresh from slot 0
        // rather than carrying over any pre-clear state.
        let (keys, cols) = u64_batch(&[(9, Some(90), None)]);
        table.merge_batch(keys, cols);
        assert_eq!((table.len, gathered_u64(&table, &[9])), (1, vec![Some(90)]));
    }
}
