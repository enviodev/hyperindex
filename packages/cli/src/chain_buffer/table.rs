//! A table of rows sorted by key, as a deque of sorted chunks that never
//! overlap. A chunk never changes once built and is shared by reference, so a
//! build that took a snapshot keeps reading it while a merge or a removal
//! replaces it in the table.

use std::cmp::Ordering;
use std::collections::VecDeque;
use std::sync::Arc;

/// Position bits of a key: the block number sits above them. An EVM log index
/// is a u32, and a block number fits the 32 bits left above it.
pub(crate) const POSITION_BITS: u32 = 32;
pub(crate) const MAX_POSITION: u64 = (1 << POSITION_BITS) - 1;
/// The highest block number a key holds.
pub(crate) const LAST_BLOCK: u64 = u64::MAX >> POSITION_BITS;

pub(crate) fn make_key(block_number: u64, position: u64) -> u64 {
    debug_assert!(position <= MAX_POSITION);
    (block_number << POSITION_BITS) | position
}

pub(crate) fn block_of_key(key: u64) -> u64 {
    key >> POSITION_BITS
}

pub(crate) fn position_of_key(key: u64) -> u64 {
    key & MAX_POSITION
}

fn first_key_of_block(block_number: u64) -> u64 {
    block_number << POSITION_BITS
}

/// The first key past every row of `block_number`.
fn key_after_block(block_number: u64) -> u64 {
    if block_number >= LAST_BLOCK {
        u64::MAX
    } else {
        first_key_of_block(block_number + 1)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ColumnKind {
    U32,
    U64,
    Fixed(usize),
    Var,
}

#[derive(Clone, Debug)]
pub(crate) struct Schema {
    pub(crate) columns: Vec<ColumnKind>,
    /// A second sort word below the key, for rows the key alone can't order.
    pub(crate) has_tiebreak: bool,
    /// Rows carry a mask of the fields fetched for them, one bit per column,
    /// and merging the same key fills the columns the stored row lacks.
    pub(crate) has_fetched: bool,
}

/// Set bit: the cell holds a value.
#[derive(Clone, Default, Debug)]
struct Presence {
    words: Vec<u64>,
}

impl Presence {
    fn get(&self, row: usize) -> bool {
        self.words
            .get(row / 64)
            .is_some_and(|word| word >> (row % 64) & 1 == 1)
    }

    fn set(&mut self, row: usize, present: bool) {
        let word = row / 64;
        if !present && self.words.len() <= word {
            return;
        }
        if self.words.len() <= word {
            self.words.resize(word + 1, 0);
        }
        if present {
            self.words[word] |= 1 << (row % 64);
        } else {
            self.words[word] &= !(1 << (row % 64));
        }
    }
}

#[derive(Clone, Debug)]
enum Values {
    U32(Vec<u32>),
    U64(Vec<u64>),
    Fixed { width: usize, bytes: Vec<u8> },
    Var { ends: Vec<u32>, bytes: Vec<u8> },
}

/// A column no row has set yet holds no values, only rows that are all null;
/// the first value fills the rows before it.
#[derive(Clone, Debug)]
struct ColumnData {
    values: Values,
    presence: Presence,
}

impl ColumnData {
    fn heap_bytes(&self) -> usize {
        let values = match &self.values {
            Values::U32(values) => values.capacity() * 4,
            Values::U64(values) => values.capacity() * 8,
            Values::Fixed { bytes, .. } => bytes.capacity(),
            Values::Var { ends, bytes } => ends.capacity() * 4 + bytes.capacity(),
        };
        values + self.presence.words.capacity() * 8
    }

    fn new(kind: ColumnKind) -> Self {
        let values = match kind {
            ColumnKind::U32 => Values::U32(Vec::new()),
            ColumnKind::U64 => Values::U64(Vec::new()),
            ColumnKind::Fixed(width) => Values::Fixed {
                width,
                bytes: Vec::new(),
            },
            ColumnKind::Var => Values::Var {
                ends: Vec::new(),
                bytes: Vec::new(),
            },
        };
        ColumnData {
            values,
            presence: Presence::default(),
        }
    }

    fn is_all_null(&self) -> bool {
        match &self.values {
            Values::U32(values) => values.is_empty(),
            Values::U64(values) => values.is_empty(),
            Values::Fixed { bytes, .. } => bytes.is_empty(),
            Values::Var { ends, .. } => ends.is_empty(),
        }
    }

    fn fill_nulls_up_to(&mut self, rows: usize) {
        if !self.is_all_null() {
            return;
        }
        match &mut self.values {
            Values::U32(values) => values.resize(rows, 0),
            Values::U64(values) => values.resize(rows, 0),
            Values::Fixed { width, bytes } => bytes.resize(rows * *width, 0),
            Values::Var { ends, .. } => ends.resize(rows, 0),
        }
    }

    fn push_null(&mut self, row: usize) {
        if self.is_all_null() {
            return;
        }
        match &mut self.values {
            Values::U32(values) => values.push(0),
            Values::U64(values) => values.push(0),
            Values::Fixed { width, bytes } => bytes.resize(bytes.len() + *width, 0),
            Values::Var { ends, bytes } => ends.push(bytes.len() as u32),
        }
        self.presence.set(row, false);
    }

    fn u64_at(&self, row: usize) -> Option<u64> {
        if !self.presence.get(row) {
            return None;
        }
        match &self.values {
            Values::U32(values) => Some(values[row] as u64),
            Values::U64(values) => Some(values[row]),
            _ => panic!("not a number column"),
        }
    }

    fn bytes_at(&self, row: usize) -> Option<&[u8]> {
        if !self.presence.get(row) {
            return None;
        }
        match &self.values {
            Values::Fixed { width, bytes } => Some(&bytes[row * width..(row + 1) * width]),
            Values::Var { ends, bytes } => {
                let start = if row == 0 { 0 } else { ends[row - 1] as usize };
                Some(&bytes[start..ends[row] as usize])
            }
            _ => panic!("not a bytes column"),
        }
    }

    /// Appends `other`'s cell at `row` as this column's row `to`.
    fn push_from(&mut self, to: usize, other: &ColumnData, row: usize) {
        let present = other.presence.get(row);
        if !present {
            self.push_null(to);
            return;
        }
        self.fill_nulls_up_to(to);
        match (&mut self.values, &other.values) {
            (Values::U32(values), Values::U32(from)) => values.push(from[row]),
            (Values::U64(values), Values::U64(from)) => values.push(from[row]),
            (
                Values::Fixed { width, bytes },
                Values::Fixed {
                    bytes: from,
                    width: from_width,
                },
            ) => {
                debug_assert_eq!(width, from_width);
                bytes.extend_from_slice(&from[row * *width..(row + 1) * *width]);
            }
            (Values::Var { ends, bytes }, Values::Var { .. }) => {
                if let Some(cell) = other.bytes_at(row) {
                    bytes.extend_from_slice(cell);
                }
                ends.push(bytes.len() as u32);
            }
            _ => panic!("column kinds differ"),
        }
        self.presence.set(to, present);
    }

    fn shrink_to_fit(&mut self) {
        match &mut self.values {
            Values::U32(values) => values.shrink_to_fit(),
            Values::U64(values) => values.shrink_to_fit(),
            Values::Fixed { bytes, .. } => bytes.shrink_to_fit(),
            Values::Var { ends, bytes } => {
                ends.shrink_to_fit();
                bytes.shrink_to_fit();
            }
        }
        self.presence.words.shrink_to_fit();
    }
}

/// Sorted, deduplicated rows. Never changes once built.
#[derive(Debug)]
pub(crate) struct Chunk {
    keys: Vec<u64>,
    tiebreaks: Vec<u64>,
    fetched: Vec<u64>,
    columns: Vec<ColumnData>,
}

impl Chunk {
    pub(crate) fn len(&self) -> usize {
        self.keys.len()
    }

    pub(crate) fn key(&self, row: usize) -> u64 {
        self.keys[row]
    }

    pub(crate) fn tiebreak(&self, row: usize) -> u64 {
        self.tiebreaks.get(row).copied().unwrap_or(0)
    }

    pub(crate) fn fetched(&self, row: usize) -> u64 {
        self.fetched.get(row).copied().unwrap_or(u64::MAX)
    }

    pub(crate) fn u64_at(&self, column: usize, row: usize) -> Option<u64> {
        self.columns[column].u64_at(row)
    }

    pub(crate) fn bytes_at(&self, column: usize, row: usize) -> Option<&[u8]> {
        self.columns[column].bytes_at(row)
    }

    fn heap_bytes(&self) -> usize {
        (self.keys.capacity() + self.tiebreaks.capacity() + self.fetched.capacity()) * 8
            + self
                .columns
                .iter()
                .map(ColumnData::heap_bytes)
                .sum::<usize>()
    }

    fn sort_key(&self, row: usize) -> (u64, u64) {
        (self.key(row), self.tiebreak(row))
    }
}

/// Builds a chunk row by row. A row starts with every column null; setters
/// fill the row just started. `finish` sorts and deduplicates.
pub(crate) struct ChunkBuilder {
    schema: Arc<Schema>,
    keys: Vec<u64>,
    tiebreaks: Vec<u64>,
    fetched: Vec<u64>,
    columns: Vec<ColumnData>,
}

impl ChunkBuilder {
    pub(crate) fn new(schema: Arc<Schema>) -> Self {
        Self::with_capacity(schema, 0)
    }

    pub(crate) fn with_capacity(schema: Arc<Schema>, capacity: usize) -> Self {
        let columns = schema
            .columns
            .iter()
            .map(|kind| ColumnData::new(*kind))
            .collect();
        ChunkBuilder {
            keys: Vec::with_capacity(capacity),
            tiebreaks: Vec::new(),
            fetched: Vec::new(),
            columns,
            schema,
        }
    }

    /// Starts a row. `fetched` is ignored by a table that keeps no mask, and
    /// `tiebreak` by one that has no second sort word.
    pub(crate) fn push_row(&mut self, key: u64, tiebreak: u64, fetched: u64) {
        let row = self.keys.len();
        self.keys.push(key);
        if self.schema.has_tiebreak {
            self.tiebreaks.push(tiebreak);
        }
        if self.schema.has_fetched {
            self.fetched.push(fetched);
        }
        for column in &mut self.columns {
            column.push_null(row);
        }
    }

    fn last_row(&self) -> usize {
        self.keys.len() - 1
    }

    pub(crate) fn set_u64(&mut self, column: usize, value: u64) {
        let row = self.last_row();
        let data = &mut self.columns[column];
        data.fill_nulls_up_to(row + 1);
        match &mut data.values {
            Values::U32(values) => {
                values[row] = u32::try_from(value).expect("value fits a u32 column");
            }
            Values::U64(values) => values[row] = value,
            _ => panic!("not a number column"),
        }
        data.presence.set(row, true);
    }

    pub(crate) fn set_bytes(&mut self, column: usize, value: &[u8]) {
        let row = self.last_row();
        let data = &mut self.columns[column];
        data.fill_nulls_up_to(row + 1);
        match &mut data.values {
            Values::Fixed { width, bytes } => {
                assert_eq!(
                    value.len(),
                    *width,
                    "a fixed-width cell takes exactly its width"
                );
                bytes[row * *width..(row + 1) * *width].copy_from_slice(value);
            }
            Values::Var { ends, bytes } => {
                let start = if row == 0 { 0 } else { ends[row - 1] as usize };
                bytes.truncate(start);
                bytes.extend_from_slice(value);
                ends[row] = bytes.len() as u32;
            }
            _ => panic!("not a bytes column"),
        }
        data.presence.set(row, true);
    }

    pub(crate) fn set_optional_u64(&mut self, column: usize, value: Option<u64>) {
        if let Some(value) = value {
            self.set_u64(column, value);
        }
    }

    pub(crate) fn set_optional_bytes(&mut self, column: usize, value: Option<&[u8]>) {
        if let Some(value) = value {
            self.set_bytes(column, value);
        }
    }

    /// Sorts by key and tiebreak and folds rows of the same key together:
    /// the first keeps its cells, and fills the ones it lacks from the rest.
    pub(crate) fn finish(self) -> Chunk {
        let sorted = (1..self.keys.len()).all(|row| {
            let sort_key = |row: usize| (self.keys[row], self.tiebreaks.get(row).copied());
            sort_key(row - 1) < sort_key(row)
        });
        let raw = OutChunk {
            keys: self.keys,
            tiebreaks: self.tiebreaks,
            fetched: self.fetched,
            columns: self.columns,
            has_tiebreak: self.schema.has_tiebreak,
            has_fetched: self.schema.has_fetched,
        };
        if sorted {
            return raw.finish();
        }
        let raw = Chunk {
            keys: raw.keys,
            tiebreaks: raw.tiebreaks,
            fetched: raw.fetched,
            columns: raw.columns,
        };
        let mut order: Vec<usize> = (0..raw.len()).collect();
        order.sort_by_key(|&row| raw.sort_key(row));
        let mut out = OutChunk::new(&self.schema, raw.len());
        let mut index = 0;
        while index < order.len() {
            let mut end = index + 1;
            while end < order.len() && raw.sort_key(order[end]) == raw.sort_key(order[index]) {
                end += 1;
            }
            let rows: Vec<(&Chunk, usize)> =
                order[index..end].iter().map(|&row| (&raw, row)).collect();
            out.push_folded(&rows);
            index = end;
        }
        out.finish()
    }
}

/// A chunk being assembled from rows of other chunks.
struct OutChunk {
    keys: Vec<u64>,
    tiebreaks: Vec<u64>,
    fetched: Vec<u64>,
    columns: Vec<ColumnData>,
    has_tiebreak: bool,
    has_fetched: bool,
}

impl OutChunk {
    fn new(schema: &Schema, capacity: usize) -> Self {
        OutChunk {
            keys: Vec::with_capacity(capacity),
            tiebreaks: Vec::new(),
            fetched: Vec::new(),
            columns: schema
                .columns
                .iter()
                .map(|kind| ColumnData::new(*kind))
                .collect(),
            has_tiebreak: schema.has_tiebreak,
            has_fetched: schema.has_fetched,
        }
    }

    fn push_copy(&mut self, chunk: &Chunk, row: usize) {
        self.push_folded(&[(chunk, row)]);
    }

    /// Pushes one row from several rows of the same key: the first one's
    /// cells, filled in from the others where it has none.
    fn push_folded(&mut self, rows: &[(&Chunk, usize)]) {
        let to = self.keys.len();
        let (first, first_row) = rows[0];
        self.keys.push(first.key(first_row));
        if self.has_tiebreak {
            self.tiebreaks.push(first.tiebreak(first_row));
        }
        if self.has_fetched {
            self.fetched.push(
                rows.iter()
                    .fold(0, |mask, (chunk, row)| mask | chunk.fetched(*row)),
            );
        }
        for (column, data) in self.columns.iter_mut().enumerate() {
            let (chunk, row) = rows
                .iter()
                .copied()
                .find(|(chunk, row)| chunk.columns[column].presence.get(*row))
                .unwrap_or((first, first_row));
            data.push_from(to, &chunk.columns[column], row);
        }
    }

    fn finish(mut self) -> Chunk {
        self.keys.shrink_to_fit();
        self.tiebreaks.shrink_to_fit();
        self.fetched.shrink_to_fit();
        for column in &mut self.columns {
            column.shrink_to_fit();
        }
        Chunk {
            keys: self.keys,
            tiebreaks: self.tiebreaks,
            fetched: self.fetched,
            columns: self.columns,
        }
    }
}

/// A run of a shared chunk's rows.
#[derive(Clone, Debug)]
pub(crate) struct Slice {
    pub(crate) chunk: Arc<Chunk>,
    pub(crate) start: usize,
    pub(crate) end: usize,
}

impl Slice {
    pub(crate) fn len(&self) -> usize {
        self.end - self.start
    }

    fn first(&self) -> (u64, u64) {
        self.chunk.sort_key(self.start)
    }

    fn last(&self) -> (u64, u64) {
        self.chunk.sort_key(self.end - 1)
    }

    /// The first row of the slice whose key is at least `key`.
    fn lower_bound(&self, key: u64) -> usize {
        self.start + self.chunk.keys[self.start..self.end].partition_point(|k| *k < key)
    }

    fn lower_bound_sort_key(&self, sort_key: (u64, u64)) -> usize {
        let (mut low, mut high) = (self.start, self.end);
        while low < high {
            let middle = low + (high - low) / 2;
            if self.chunk.sort_key(middle) < sort_key {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        low
    }

    /// The slice on a chunk of its own rows when it holds under half of its
    /// chunk, so the rows a removal or merge dropped are freed; a snapshot
    /// still reading the old chunk keeps it alive.
    fn compacted(self, schema: &Schema) -> Slice {
        if self.len() * 2 >= self.chunk.len() {
            return self;
        }
        let mut out = OutChunk::new(schema, self.len());
        for row in self.start..self.end {
            out.push_copy(&self.chunk, row);
        }
        let chunk = Arc::new(out.finish());
        let end = chunk.len();
        Slice {
            chunk,
            start: 0,
            end,
        }
    }

    fn sub(&self, start: usize, end: usize) -> Option<Slice> {
        (start < end).then(|| Slice {
            chunk: self.chunk.clone(),
            start,
            end,
        })
    }
}

/// A position in a table: the slice and the row inside its chunk.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) struct RowRef<'a> {
    pub(crate) chunk: &'a Chunk,
    pub(crate) row: usize,
}

impl<'a> RowRef<'a> {
    pub(crate) fn key(&self) -> u64 {
        self.chunk.key(self.row)
    }

    pub(crate) fn block_number(&self) -> u64 {
        block_of_key(self.key())
    }

    pub(crate) fn position(&self) -> u64 {
        position_of_key(self.key())
    }

    pub(crate) fn tiebreak(&self) -> u64 {
        self.chunk.tiebreak(self.row)
    }

    pub(crate) fn fetched(&self) -> u64 {
        self.chunk.fetched(self.row)
    }

    pub(crate) fn u64_at(&self, column: usize) -> Option<u64> {
        self.chunk.u64_at(column, self.row)
    }

    pub(crate) fn bytes_at(&self, column: usize) -> Option<&'a [u8]> {
        self.chunk.bytes_at(column, self.row)
    }
}

impl PartialEq for Chunk {
    fn eq(&self, other: &Self) -> bool {
        std::ptr::eq(self, other)
    }
}

impl Eq for Chunk {}

/// The rows of a table at one moment, readable while the table moves on.
#[derive(Clone, Default)]
pub(crate) struct Snapshot {
    slices: Vec<Slice>,
}

impl Snapshot {
    /// Rows of blocks `[from_block, to_block]`, in order.
    pub(crate) fn rows_in_block_range(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> impl Iterator<Item = RowRef<'_>> + '_ {
        let from = first_key_of_block(from_block);
        let below = key_after_block(to_block);
        self.slices.iter().flat_map(move |slice| {
            let start = slice.lower_bound(from);
            let end = slice.lower_bound(below);
            (start..end).map(move |row| RowRef {
                chunk: &slice.chunk,
                row,
            })
        })
    }

    /// The row of exactly this key and tiebreak.
    pub(crate) fn find(&self, key: u64, tiebreak: u64) -> Option<RowRef<'_>> {
        let sort_key = (key, tiebreak);
        let index = self.slices.partition_point(|slice| slice.last() < sort_key);
        let slice = self.slices.get(index)?;
        let row = slice.lower_bound_sort_key(sort_key);
        (row < slice.end && slice.chunk.sort_key(row) == sort_key).then_some(RowRef {
            chunk: &slice.chunk,
            row,
        })
    }
}

pub(crate) struct Table {
    schema: Arc<Schema>,
    slices: VecDeque<Slice>,
    rows: usize,
}

impl Table {
    pub(crate) fn new(schema: Schema) -> Self {
        Table {
            schema: Arc::new(schema),
            slices: VecDeque::new(),
            rows: 0,
        }
    }

    pub(crate) fn schema(&self) -> &Arc<Schema> {
        &self.schema
    }

    pub(crate) fn builder(&self) -> ChunkBuilder {
        ChunkBuilder::new(self.schema.clone())
    }

    pub(crate) fn len(&self) -> usize {
        self.rows
    }

    pub(crate) fn snapshot(&self) -> Snapshot {
        Snapshot {
            slices: self.slices.iter().cloned().collect(),
        }
    }

    /// Merges a chunk in and returns how many of its rows were new. A row of
    /// a key already stored keeps the stored cells, filled in from the
    /// incoming row where the stored one has none.
    pub(crate) fn merge(&mut self, incoming: Chunk) -> usize {
        self.merge_slice(Slice {
            end: incoming.len(),
            chunk: Arc::new(incoming),
            start: 0,
        })
    }

    /// Merges every row of another table in, returning how many were new.
    pub(crate) fn merge_table(&mut self, other: &Table) -> usize {
        other
            .slices
            .iter()
            .map(|slice| self.merge_slice(slice.clone()))
            .sum()
    }

    fn merge_slice(&mut self, incoming: Slice) -> usize {
        if incoming.len() == 0 {
            return 0;
        }
        let (first, last) = (incoming.first(), incoming.last());
        let start = self.slices.partition_point(|slice| slice.last() < first);
        let end = start
            + self
                .slices
                .iter()
                .skip(start)
                .take_while(|slice| slice.first() <= last)
                .count();
        if start == end {
            let added = incoming.len();
            self.rows += added;
            self.slices.insert(start, incoming);
            return added;
        }
        let overlapped: Vec<Slice> = self.slices.drain(start..end).collect();
        let mut replacement = Vec::new();
        // The stored rows before the incoming ones and after them stay where
        // they are; only the run they land among is rebuilt.
        let head = &overlapped[0];
        let head_end = head.lower_bound_sort_key(first);
        replacement.extend(
            head.sub(head.start, head_end)
                .map(|kept| kept.compacted(&self.schema)),
        );
        let tail = &overlapped[overlapped.len() - 1];
        let tail_start = {
            let at = tail.lower_bound_sort_key(last);
            if at < tail.end && tail.chunk.sort_key(at) == last {
                at + 1
            } else {
                at
            }
        };

        let mut stored: Vec<RowRef> = Vec::new();
        for (index, slice) in overlapped.iter().enumerate() {
            let from = if index == 0 { head_end } else { slice.start };
            let to = if index == overlapped.len() - 1 {
                tail_start
            } else {
                slice.end
            };
            stored.extend((from..to).map(|row| RowRef {
                chunk: &slice.chunk,
                row,
            }));
        }
        let mut out = OutChunk::new(&self.schema, stored.len() + incoming.len());
        let (mut s, mut i) = (0, incoming.start);
        let mut added = 0;
        while s < stored.len() || i < incoming.end {
            let take_stored = match (stored.get(s), (i < incoming.end).then_some(i)) {
                (Some(row), Some(i)) => {
                    row.chunk.sort_key(row.row).cmp(&incoming.chunk.sort_key(i))
                }
                (Some(_), None) => Ordering::Less,
                (None, _) => Ordering::Greater,
            };
            match take_stored {
                Ordering::Less => {
                    out.push_copy(stored[s].chunk, stored[s].row);
                    s += 1;
                }
                Ordering::Greater => {
                    out.push_copy(&incoming.chunk, i);
                    i += 1;
                    added += 1;
                }
                Ordering::Equal => {
                    out.push_folded(&[(stored[s].chunk, stored[s].row), (&incoming.chunk, i)]);
                    s += 1;
                    i += 1;
                }
            }
        }
        let merged = out.finish();
        replacement.push(Slice {
            end: merged.len(),
            chunk: Arc::new(merged),
            start: 0,
        });
        replacement.extend(
            tail.sub(tail_start, tail.end)
                .map(|kept| kept.compacted(&self.schema)),
        );
        for (offset, slice) in replacement.into_iter().enumerate() {
            self.slices.insert(start + offset, slice);
        }
        self.rows += added;
        added
    }

    /// Removes the rows of blocks `[from_block, to_block]` and returns how
    /// many there were.
    pub(crate) fn remove_block_range(&mut self, from_block: u64, to_block: u64) -> usize {
        if from_block > to_block {
            return 0;
        }
        let from = first_key_of_block(from_block);
        let below = key_after_block(to_block);
        let mut removed = 0;
        let schema = self.schema.clone();
        let mut kept = VecDeque::with_capacity(self.slices.len());
        for slice in self.slices.drain(..) {
            let cut_start = slice.lower_bound(from);
            let cut_end = slice.lower_bound(below);
            if cut_start == cut_end {
                kept.push_back(slice);
                continue;
            }
            removed += cut_end - cut_start;
            kept.extend(
                slice
                    .sub(slice.start, cut_start)
                    .map(|kept| kept.compacted(&schema)),
            );
            kept.extend(
                slice
                    .sub(cut_end, slice.end)
                    .map(|kept| kept.compacted(&schema)),
            );
        }
        self.slices = kept;
        self.rows -= removed;
        removed
    }

    /// Rows of blocks `[from_block, to_block]`.
    pub(crate) fn count_in_block_range(&self, from_block: u64, to_block: u64) -> usize {
        if from_block > to_block {
            return 0;
        }
        let from = first_key_of_block(from_block);
        let below = key_after_block(to_block);
        self.slices
            .iter()
            .map(|slice| slice.lower_bound(below) - slice.lower_bound(from))
            .sum()
    }

    /// The block of the row `offset` rows past the first row at or above
    /// `from_block`.
    pub(crate) fn block_number_of_row_at(&self, from_block: u64, offset: usize) -> Option<u64> {
        let from = first_key_of_block(from_block);
        let mut remaining = offset;
        for slice in &self.slices {
            let start = slice.lower_bound(from);
            let available = slice.end - start;
            if remaining < available {
                return Some(block_of_key(slice.chunk.key(start + remaining)));
            }
            remaining -= available;
        }
        None
    }

    pub(crate) fn find(&self, key: u64, tiebreak: u64) -> Option<RowRef<'_>> {
        let sort_key = (key, tiebreak);
        let index = self.slices.partition_point(|slice| slice.last() < sort_key);
        let slice = self.slices.get(index)?;
        let row = slice.lower_bound_sort_key(sort_key);
        (row < slice.end && slice.chunk.sort_key(row) == sort_key).then_some(RowRef {
            chunk: &slice.chunk,
            row,
        })
    }

    pub(crate) fn rows_in_block_range(
        &self,
        from_block: u64,
        to_block: u64,
    ) -> impl Iterator<Item = RowRef<'_>> + '_ {
        let from = first_key_of_block(from_block);
        let below = key_after_block(to_block);
        self.slices.iter().flat_map(move |slice| {
            let start = slice.lower_bound(from);
            let end = slice.lower_bound(below);
            (start..end).map(move |row| RowRef {
                chunk: &slice.chunk,
                row,
            })
        })
    }

    /// The rows of blocks at or below `to_block`, highest key first.
    pub(crate) fn rows_down_from_block(
        &self,
        to_block: u64,
    ) -> impl Iterator<Item = RowRef<'_>> + '_ {
        let below = key_after_block(to_block);
        self.slices.iter().rev().flat_map(move |slice| {
            let end = slice.lower_bound(below);
            (slice.start..end).rev().map(move |row| RowRef {
                chunk: &slice.chunk,
                row,
            })
        })
    }

    /// The bytes the table's chunks hold, a chunk shared by several slices
    /// counted once.
    pub(crate) fn heap_bytes(&self) -> usize {
        let mut seen = std::collections::HashSet::new();
        self.slices
            .iter()
            .filter(|slice| seen.insert(Arc::as_ptr(&slice.chunk)))
            .map(|slice| slice.chunk.heap_bytes())
            .sum()
    }

    #[cfg(test)]
    fn slice_count(&self) -> usize {
        self.slices.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALUE: usize = 0;
    const NAME: usize = 1;

    fn schema(has_fetched: bool) -> Schema {
        Schema {
            columns: vec![ColumnKind::U64, ColumnKind::Var],
            has_tiebreak: false,
            has_fetched,
        }
    }

    fn chunk(table: &Table, rows: &[(u64, u64, Option<u64>, Option<&str>)]) -> Chunk {
        let mut builder = table.builder();
        for (block, position, value, name) in rows {
            let fetched = value.map_or(0, |_| 1 << VALUE) | name.map_or(0, |_| 1 << NAME);
            builder.push_row(make_key(*block, *position), 0, fetched);
            builder.set_optional_u64(VALUE, *value);
            builder.set_optional_bytes(NAME, name.map(str::as_bytes));
        }
        builder.finish()
    }

    type Described = (u64, u64, Option<u64>, Option<String>);

    fn describe(table: &Table) -> Vec<Described> {
        table
            .rows_in_block_range(0, LAST_BLOCK)
            .map(|row| {
                (
                    row.block_number(),
                    row.position(),
                    row.u64_at(VALUE),
                    row.bytes_at(NAME)
                        .map(|bytes| String::from_utf8(bytes.to_vec()).unwrap()),
                )
            })
            .collect()
    }

    fn row(block: u64, position: u64, value: Option<u64>, name: Option<&str>) -> Described {
        (block, position, value, name.map(str::to_string))
    }

    #[test]
    fn appends_and_reads_in_key_order() {
        let mut table = Table::new(schema(false));
        let added = table.merge(chunk(
            &table,
            &[(2, 0, Some(20), None), (1, 3, Some(13), Some("a"))],
        ));
        let added_after = table.merge(chunk(&table, &[(5, 0, Some(50), Some("b"))]));
        assert_eq!(
            (added, added_after, describe(&table), table.slice_count()),
            (
                2,
                1,
                vec![
                    row(1, 3, Some(13), Some("a")),
                    row(2, 0, Some(20), None),
                    row(5, 0, Some(50), Some("b")),
                ],
                2
            )
        );
    }

    #[test]
    fn an_overlapping_merge_keeps_one_row_per_key_and_copies_only_the_overlap() {
        let mut table = Table::new(schema(false));
        table.merge(chunk(
            &table,
            &[
                (1, 0, Some(1), None),
                (3, 0, Some(3), None),
                (5, 0, Some(5), None),
                (9, 0, Some(9), None),
            ],
        ));
        let added = table.merge(chunk(
            &table,
            &[(3, 0, Some(333), None), (4, 0, Some(4), None)],
        ));
        assert_eq!(
            (added, describe(&table), table.slice_count(), table.len()),
            (
                1,
                vec![
                    row(1, 0, Some(1), None),
                    row(3, 0, Some(3), None),
                    row(4, 0, Some(4), None),
                    row(5, 0, Some(5), None),
                    row(9, 0, Some(9), None),
                ],
                3,
                5
            )
        );
    }

    #[test]
    fn merging_the_same_key_unions_its_fetched_fields() {
        let mut table = Table::new(schema(true));
        table.merge(chunk(&table, &[(7, 0, Some(70), None)]));
        table.merge(chunk(&table, &[(7, 0, None, Some("seven"))]));
        let fetched = table.find(make_key(7, 0), 0).unwrap().fetched();
        assert_eq!(
            (describe(&table), fetched),
            (vec![row(7, 0, Some(70), Some("seven"))], 0b11)
        );
    }

    #[test]
    fn a_page_with_duplicate_keys_folds_them() {
        let table = Table::new(schema(true));
        let folded = chunk(
            &table,
            &[
                (4, 0, None, Some("x")),
                (2, 0, Some(2), None),
                (4, 0, Some(40), None),
            ],
        );
        let mut table = table;
        table.merge(folded);
        assert_eq!(
            describe(&table),
            vec![row(2, 0, Some(2), None), row(4, 0, Some(40), Some("x"))]
        );
    }

    #[test]
    fn removes_and_counts_a_block_range() {
        let mut table = Table::new(schema(false));
        table.merge(chunk(
            &table,
            &[
                (1, 0, Some(1), None),
                (2, 0, Some(2), None),
                (2, 1, Some(21), None),
                (3, 0, Some(3), None),
            ],
        ));
        table.merge(chunk(&table, &[(6, 0, Some(6), None)]));
        let counted = (
            table.count_in_block_range(2, 3),
            table.count_in_block_range(4, 5),
            table.block_number_of_row_at(2, 2),
            table.block_number_of_row_at(2, 3),
            table.block_number_of_row_at(2, 4),
        );
        let removed = table.remove_block_range(2, 2);
        assert_eq!(
            (counted, removed, describe(&table), table.len()),
            (
                (3, 0, Some(3), Some(6), None),
                2,
                vec![
                    row(1, 0, Some(1), None),
                    row(3, 0, Some(3), None),
                    row(6, 0, Some(6), None)
                ],
                3
            )
        );
    }

    #[test]
    fn a_removal_frees_the_rows_it_drops_once_they_are_most_of_a_chunk() {
        let mut table = Table::new(schema(false));
        table.merge(chunk(
            &table,
            &(1..=10)
                .map(|block| (block, 0, Some(block), None))
                .collect::<Vec<_>>(),
        ));
        table.remove_block_range(1, 4);
        let after_minority_removed: Vec<usize> =
            table.slices.iter().map(|slice| slice.chunk.len()).collect();
        table.remove_block_range(5, 8);
        assert_eq!(
            (
                after_minority_removed,
                table
                    .slices
                    .iter()
                    .map(|slice| slice.chunk.len())
                    .collect::<Vec<_>>(),
                describe(&table),
            ),
            (
                vec![10],
                vec![2],
                vec![row(9, 0, Some(9), None), row(10, 0, Some(10), None)],
            )
        );
    }

    #[test]
    fn a_snapshot_keeps_reading_what_a_removal_dropped() {
        let mut table = Table::new(schema(false));
        table.merge(chunk(
            &table,
            &[(1, 0, Some(1), None), (2, 0, Some(2), None)],
        ));
        let snapshot = table.snapshot();
        table.remove_block_range(0, 10);
        let read: Vec<u64> = snapshot
            .rows_in_block_range(0, 10)
            .map(|row| row.u64_at(VALUE).unwrap())
            .collect();
        assert_eq!((read, table.len()), (vec![1, 2], 0));
    }

    #[test]
    fn a_tiebreak_orders_rows_of_one_key() {
        let mut table = Table::new(Schema {
            columns: vec![ColumnKind::U32],
            has_tiebreak: true,
            has_fetched: false,
        });
        let mut builder = table.builder();
        for (tiebreak, value) in [(3, 30), (1, 10), (2, 20)] {
            builder.push_row(make_key(1, 0), tiebreak, 0);
            builder.set_u64(0, value);
        }
        table.merge(builder.finish());
        let mut builder = table.builder();
        builder.push_row(make_key(1, 0), 2, 0);
        builder.set_u64(0, 99);
        let added = table.merge(builder.finish());
        let read: Vec<(u64, u64)> = table
            .rows_in_block_range(0, 5)
            .map(|row| (row.tiebreak(), row.u64_at(0).unwrap()))
            .collect();
        assert_eq!((added, read), (0, vec![(1, 10), (2, 20), (3, 30)]));
    }

    #[test]
    fn columns_no_row_sets_take_no_value_bytes() {
        let mut table = Table::new(Schema {
            columns: vec![ColumnKind::U64, ColumnKind::Fixed(32), ColumnKind::Var],
            has_tiebreak: false,
            has_fetched: false,
        });
        let mut builder = table.builder();
        for block in 0..1000 {
            builder.push_row(make_key(block, 0), 0, 0);
            builder.set_u64(0, block);
        }
        table.merge(builder.finish());
        let read: Vec<_> = table
            .rows_in_block_range(998, LAST_BLOCK)
            .map(|row| (row.u64_at(0), row.bytes_at(1), row.bytes_at(2)))
            .collect();
        assert_eq!(
            (table.heap_bytes(), read),
            (
                16_128,
                vec![(Some(998), None, None), (Some(999), None, None)]
            )
        );
    }

    #[test]
    fn a_merge_inside_a_chunk_frees_the_rows_it_rebuilt() {
        let mut table = Table::new(schema(false));
        table.merge(chunk(
            &table,
            &(0..1000)
                .map(|block| (block * 2, 0, Some(block), None))
                .collect::<Vec<_>>(),
        ));
        let stored_bytes = table.heap_bytes();
        table.merge(chunk(
            &table,
            &(10..990)
                .map(|block| (block * 2 + 1, 0, Some(block), None))
                .collect::<Vec<_>>(),
        ));
        assert!(
            table.heap_bytes() < stored_bytes * 2,
            "{} bytes after merging {} rows into {stored_bytes}",
            table.heap_bytes(),
            980
        );
    }
}
