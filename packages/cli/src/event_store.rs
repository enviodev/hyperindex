//! Per-chain store of fetched items, kept sorted in processing order until a
//! batch takes them. A row holds the item's sort key and its data as Rust
//! values, so an item becomes a JS object only when a batch or a contract
//! register reads it. Sources return one store per response (a page), merged
//! into the chain's store once the response is applied.
//!
//! Rows leave as an arena result: whole items, events and block handlers
//! mixed, laid out column by column the way storage hands JavaScript a query
//! result, and read there with the same `Reading` code.

use std::cmp::Ordering;
use std::collections::VecDeque;
use std::ops::Range;
use std::sync::{LazyLock, Mutex};

use anyhow::Result;
use napi::bindgen_prelude::{ArrayBuffer, Float64Array, Uint32Array};
use napi::Env;
use napi_derive::napi;

use crate::columnar::{js as columnar_js, Arena, ColumnSpec};
use crate::evm_hypersync_source::types::{EvmParams, ParamCell, ParamSchema};
use crate::js_value::JsTape;
use crate::storage::rows::{ColumnRead, ReadKind};

/// Which JS conversion a row goes through, chosen by what produced it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RowFormat {
    /// An EVM log routed by HyperSync or RPC.
    EvmLog = 0,
    FuelReceipt = 1,
    SvmInstruction = 2,
    /// A block handler's item, fetched or generated.
    Block = 3,
    /// An item built in JS (simulate input), stored without its registration.
    JsItem = 4,
}

/// Events of a block run before its block handlers, whatever an ecosystem's
/// within-block key grows to.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub(crate) enum ItemKind {
    Event = 0,
    Block = 1,
}

#[derive(Clone)]
pub(crate) enum RowData {
    EvmLog {
        src_address: String,
        transaction_index: i64,
        params: EvmParams,
    },
    FuelReceipt {
        tx_id: String,
        src_address: String,
        /// Sway values, nested by nature, so a tape.
        params: JsTape,
    },
    SvmInstruction {
        program_id: String,
        accounts: Vec<String>,
        data: Vec<u8>,
        is_inner: bool,
        /// Borsh-decoded args, when the registration selected them.
        args: Option<JsTape>,
        /// `[{kind, message}]`, when the registration selected them.
        logs: Option<JsTape>,
    },
    Block {
        skipped: bool,
    },
    /// An item built in JS (simulate input), without its registration.
    JsItem {
        item: JsTape,
        /// The key of its transaction in the chain's store, when the item
        /// doesn't carry the transaction itself.
        transaction_index: Option<i64>,
        /// Whether its block comes from the chain's store rather than the item.
        block_from_store: bool,
    },
}

const READS_TRANSACTION: u8 = 1;
const READS_BLOCK: u8 = 2;

impl RowData {
    /// Which of the chain's stores the item's transaction and block come from.
    /// Fuel carries its transaction, a skipped block item reads no block, and
    /// a JS-built item says what it carries.
    fn reads(&self) -> u8 {
        match self {
            RowData::EvmLog { .. } | RowData::SvmInstruction { .. } => {
                READS_TRANSACTION | READS_BLOCK
            }
            RowData::FuelReceipt { .. } => READS_BLOCK,
            RowData::Block { skipped } => {
                if *skipped {
                    0
                } else {
                    READS_BLOCK
                }
            }
            RowData::JsItem {
                transaction_index,
                block_from_store,
                ..
            } => {
                (if transaction_index.is_some() {
                    READS_TRANSACTION
                } else {
                    0
                }) | if *block_from_store { READS_BLOCK } else { 0 }
            }
        }
    }

    fn format(&self) -> RowFormat {
        match self {
            RowData::EvmLog { .. } => RowFormat::EvmLog,
            RowData::FuelReceipt { .. } => RowFormat::FuelReceipt,
            RowData::SvmInstruction { .. } => RowFormat::SvmInstruction,
            RowData::Block { .. } => RowFormat::Block,
            RowData::JsItem { .. } => RowFormat::JsItem,
        }
    }
}

#[derive(Clone)]
pub(crate) struct Row {
    block_number: i64,
    kind: ItemKind,
    /// The ecosystem's within-block order: log index (EVM), receipt index
    /// (Fuel), transaction index (SVM). Zero for block items.
    log_index: i64,
    /// SVM's position in the transaction's CPI tree, parent before child.
    order_path: Option<Vec<i64>>,
    registration_index: i64,
    data: RowData,
}

impl Row {
    pub(crate) fn event(
        block_number: i64,
        log_index: i64,
        order_path: Option<Vec<i64>>,
        registration_index: i64,
        data: RowData,
    ) -> Self {
        Row {
            block_number,
            kind: ItemKind::Event,
            log_index,
            order_path,
            registration_index,
            data,
        }
    }

    pub(crate) fn block(block_number: i64, registration_index: i64, skipped: bool) -> Self {
        Row {
            block_number,
            kind: ItemKind::Block,
            log_index: 0,
            order_path: None,
            registration_index,
            data: RowData::Block { skipped },
        }
    }

    /// Total order on rows. `Equal` means a true duplicate: the same log routed
    /// to the same registration, which an overlapping re-fetch delivers again.
    fn compare(&self, other: &Row) -> Ordering {
        self.block_number
            .cmp(&other.block_number)
            .then(self.kind.cmp(&other.kind))
            .then(self.log_index.cmp(&other.log_index))
            // Lexicographic, so a parent instruction `[1]` precedes its child
            // `[1, 0]`. No path is an empty one, as in a chunk.
            .then_with(|| {
                self.order_path
                    .as_deref()
                    .unwrap_or_default()
                    .cmp(other.order_path.as_deref().unwrap_or_default())
            })
            .then(self.registration_index.cmp(&other.registration_index))
    }
}

/// A chunk this short takes the next appended rows into itself rather than
/// staying beside them, so generated block items and small pages don't pile
/// up chunks that the positional queries would walk, when they are short too:
/// a long page is kept whole, and a long chunk isn't regrown.
const COALESCE_BELOW: usize = 1024;

/// Rows in processing order, deduplicated, as sorted chunks that don't
/// overlap. A page whose rows all come after the stored ones, which is what a
/// response at the fetch frontier brings, is kept whole as one more chunk, so
/// merging it copies nothing. A page that fills a gap merges only into the
/// chunks it overlaps.
#[derive(Default)]
pub(crate) struct Rows {
    /// None empty: `append` and `merge_chunk` skip empty chunks, and `take`
    /// and `rollback` pop a chunk they empty.
    chunks: VecDeque<Chunk>,
    len: usize,
}

impl Rows {
    /// Sorts and deduplicates `rows` into one chunk. Of two equal rows the
    /// first is kept.
    fn from_unsorted(mut rows: Vec<Row>) -> Self {
        // Stable, so of two equal rows the first stays first.
        rows.sort_by(Row::compare);
        rows.dedup_by(|later, kept| kept.compare(later) == Ordering::Equal);
        let mut sorted = Rows::default();
        let mut chunk = Chunk::from_sorted_rows(&rows);
        chunk.shrink_to_fit();
        sorted.append(chunk);
        sorted
    }

    fn len(&self) -> usize {
        self.len
    }

    fn keys(&self) -> impl Iterator<Item = u128> + '_ {
        self.chunks
            .iter()
            .flat_map(|chunk| chunk.keys[chunk.start..].iter().copied())
    }

    fn block_number_at(&self, mut index: usize) -> Option<i64> {
        for chunk in &self.chunks {
            if index < chunk.len() {
                return Some(chunk.block_number_at(chunk.start + index));
            }
            index -= chunk.len();
        }
        None
    }

    fn count_at_or_below(&self, block_number: i64) -> usize {
        let mut count = 0;
        for chunk in &self.chunks {
            if chunk.block_number_at(chunk.keys.len() - 1) > block_number {
                return count + chunk.count_at_or_below(block_number);
            }
            count += chunk.len();
        }
        count
    }

    /// Adds a chunk whose rows all come after the stored ones.
    fn append(&mut self, chunk: Chunk) {
        if chunk.len() == 0 {
            return;
        }
        self.len += chunk.len();
        match self.chunks.back_mut() {
            Some(last) if last.len() < COALESCE_BELOW && chunk.len() < COALESCE_BELOW => {
                // A chunk batches take from while pages append to it never
                // drains: once at least half of it is taken rows, it leaves
                // them behind.
                if last.start > 0 && last.start * 2 >= last.keys.len() {
                    let mut kept = Chunk::empty();
                    kept.extend_from(last, last.start..last.keys.len());
                    *last = kept;
                }
                last.extend_from(&chunk, chunk.start..chunk.keys.len())
            }
            _ => self.chunks.push_back(chunk),
        }
    }

    /// Merges `other`'s rows in. On a tie the row already stored is kept.
    fn merge(&mut self, other: Rows) {
        for chunk in other.chunks {
            self.merge_chunk(chunk);
        }
    }

    fn merge_chunk(&mut self, incoming: Chunk) {
        if incoming.len() == 0 {
            return;
        }
        let first = incoming.start;
        let last = incoming.keys.len() - 1;
        // The chunks the page overlaps: from the first whose last row isn't
        // before the page's first, to the last whose first row isn't after the
        // page's last.
        let Some(start) = self.chunks.iter().position(|chunk| {
            chunk.compare(chunk.keys.len() - 1, &incoming, first) != Ordering::Less
        }) else {
            return self.append(incoming);
        };
        let end = start
            + self
                .chunks
                .iter()
                .skip(start)
                .take_while(|chunk| {
                    chunk.compare(chunk.start, &incoming, last) != Ordering::Greater
                })
                .count();
        if start == end {
            // In the gap before the chunk at `start`, overlapping no stored row.
            self.len += incoming.len();
            self.chunks.insert(start, incoming);
            return;
        }
        let mut overlapped: Vec<Chunk> = self.chunks.drain(start..end).collect();
        // The first overlapped chunk's rows before the page and the last one's
        // rows past it stay where they are, so a merge copies only the rows the
        // page lands among. Where both sides are one chunk, the smaller side is
        // copied with them.
        let first_chunk = &overlapped[0];
        let last_chunk = &overlapped[overlapped.len() - 1];
        let before_page = first_chunk.first_not_before(&incoming, first);
        let past_page = last_chunk.first_after(&incoming, last);
        let (keep_front, keep_back) = if overlapped.len() == 1 {
            let front = before_page - first_chunk.start;
            let back = last_chunk.keys.len() - past_page;
            (front > back, front <= back)
        } else {
            (true, true)
        };
        let count = overlapped.len();
        let ranges: Vec<(&Chunk, Range<usize>)> = overlapped
            .iter()
            .enumerate()
            .map(|(index, chunk)| {
                let from = if index == 0 && keep_front {
                    before_page
                } else {
                    chunk.start
                };
                let to = if index == count - 1 && keep_back {
                    past_page
                } else {
                    chunk.keys.len()
                };
                (chunk, from..to)
            })
            .collect();
        let stored_len: usize = ranges.iter().map(|(_, rows)| rows.len()).sum();
        let mut merged = merge_sorted(&ranges, &incoming);
        merged.shrink_to_fit();
        self.len = self.len - stored_len + merged.len();

        let mut kept = Vec::new();
        let mut back = overlapped.pop().unwrap();
        let mut front = overlapped.into_iter().next();
        if keep_back {
            back.start = past_page;
        }
        if keep_front {
            let front = front.get_or_insert_with(|| std::mem::replace(&mut back, Chunk::empty()));
            front.truncate(before_page);
        }
        kept.extend(front.filter(|chunk| chunk.len() > 0));
        kept.push(merged);
        if back.len() > 0 {
            kept.push(back);
        }
        for (offset, chunk) in kept.into_iter().enumerate() {
            self.chunks.insert(start + offset, chunk);
        }
    }

    /// Removes the first `count` rows. A chunk taken whole from its first row
    /// on is handed over as it is.
    fn take(&mut self, count: usize) -> Chunk {
        let mut taken: Option<Chunk> = None;
        let mut remaining = count;
        while remaining > 0 {
            let Some(front) = self.chunks.front_mut() else {
                break;
            };
            let len = front.len();
            if len > remaining {
                taken
                    .get_or_insert_with(Chunk::empty)
                    .extend_from(front, front.start..front.start + remaining);
                front.start += remaining;
                remaining = 0;
            } else {
                let front = self.chunks.pop_front().unwrap();
                remaining -= len;
                match &mut taken {
                    None if front.start == 0 && !front.truncated => taken = Some(front),
                    _ => taken
                        .get_or_insert_with(Chunk::empty)
                        .extend_from(&front, front.start..front.keys.len()),
                }
            }
        }
        let taken = taken.unwrap_or_else(Chunk::empty);
        self.len -= taken.len();
        taken
    }

    /// Drops every row above `block_number`.
    fn rollback(&mut self, block_number: i64) {
        while let Some(chunk) = self.chunks.back_mut() {
            let kept = chunk.count_at_or_below(block_number);
            self.len -= chunk.len() - kept;
            if kept == 0 {
                self.chunks.pop_back();
            } else {
                if kept < chunk.len() {
                    chunk.truncate(chunk.start + kept);
                }
                break;
            }
        }
    }

    /// The rows `keep` accepts, in order, copied out.
    fn select(&self, keep: impl Fn(&Chunk, usize) -> bool) -> Chunk {
        let mut selected = Chunk::empty();
        for chunk in &self.chunks {
            let mut row = chunk.start;
            while row < chunk.keys.len() {
                let run_start = row;
                while row < chunk.keys.len() && keep(chunk, row) {
                    row += 1;
                }
                selected.extend_from(chunk, run_start..row);
                row += 1;
            }
        }
        selected
    }
}

/// Merges the sorted, deduplicated rows of `stored`, row ranges of chunks that
/// follow each other, with `incoming`'s. On a tie the stored row is kept. Each side is
/// copied a run at a time.
fn merge_sorted(stored: &[(&Chunk, Range<usize>)], incoming: &Chunk) -> Chunk {
    let mut merged = Chunk::empty();
    let mut next = incoming.start;
    let incoming_end = incoming.keys.len();
    for (chunk, rows) in stored {
        let mut row = rows.start;
        let end = rows.end;
        while row < end {
            if next == incoming_end {
                merged.extend_from(chunk, row..end);
                break;
            }
            match chunk.compare(row, incoming, next) {
                Ordering::Less => {
                    let run_start = row;
                    while row < end && chunk.compare(row, incoming, next) == Ordering::Less {
                        row += 1;
                    }
                    merged.extend_from(chunk, run_start..row);
                }
                Ordering::Equal => {
                    merged.extend_from(chunk, row..row + 1);
                    row += 1;
                    next += 1;
                }
                Ordering::Greater => {
                    let run_start = next;
                    while next < incoming_end
                        && incoming.compare(next, chunk, row) == Ordering::Less
                    {
                        next += 1;
                    }
                    merged.extend_from(incoming, run_start..next);
                }
            }
        }
    }
    merged.extend_from(incoming, next..incoming_end);
    merged
}

/// A row's place in processing order but for an SVM path and the
/// registration: `block << 64 | kind << 63 | within-block index`.
fn sort_key(block_number: i64, kind: ItemKind, log_index: i64) -> u128 {
    ((block_number as u128) << 64) | ((kind as u128) << 63) | log_index as u128
}

const KIND_BIT: u128 = 1 << 63;

/// One params column per param of a registration's events.
struct Params {
    columns: Vec<ColumnRead>,
    arena: Arena,
}

/// Sorted, deduplicated rows as columns: the sort key, which every positional
/// query and merge reads alone, and the arenas a batch hands JavaScript,
/// laid out once when the page is decoded, off the JS thread. Rows before
/// `start` were taken already.
struct Chunk {
    start: usize,
    keys: Vec<u128>,
    registrations: Vec<i64>,
    /// Which of the chain's stores a row's transaction and block come from:
    /// `READS_TRANSACTION` and `READS_BLOCK`.
    reads: Vec<u8>,
    /// Whether `truncate` dropped rows whose tapes may still be in `tapes`:
    /// such a chunk is copied into a batch, never handed over whole.
    truncated: bool,
    /// SVM's position in the transaction's CPI tree, parent before child:
    /// `path_ends[row]` is where the row's steps stop. Empty for other rows.
    path_ends: Vec<u32>,
    path_steps: Vec<i64>,
    /// One row per row of the chunk, `ITEM_COLUMNS`. A row's `detailRow`
    /// points into its format's own arena, and every tape cell into `tapes`.
    items: Arena,
    /// By registration index.
    params: Vec<Option<Params>>,
    fuel: Arena,
    svm: Arena,
    tapes: Vec<JsTape>,
}

fn item_columns() -> Vec<ColumnRead> {
    ITEM_COLUMNS
        .iter()
        .map(|(name, kind)| ColumnRead::scalar(*name, *kind))
        .collect()
}

/// `elements` gives a list column's element count across all rows, which its
/// element column is sized to once.
fn sized_arena(columns: &[ColumnRead], rows: usize, elements: &[usize]) -> Arena {
    let specs: Vec<ColumnSpec> = columns
        .iter()
        .enumerate()
        .map(|(index, column)| match column.element {
            Some(element) => ColumnSpec::List {
                element: element.slot(),
                elements: elements.get(index).copied().unwrap_or(0),
            },
            None => ColumnSpec::Scalar(column.kind.slot()),
        })
        .collect();
    Arena::new_filled(rows, &specs)
}

fn tape_columns(columns: &[ColumnRead]) -> impl Iterator<Item = usize> + '_ {
    columns
        .iter()
        .enumerate()
        .filter(|(_, column)| column.kind == ReadKind::Tape)
        .map(|(index, _)| index)
}

/// Gives `rows` of `arena`'s tape `column`, copied from another chunk, their
/// tapes: each copied onto `tapes` and the cell pointed at the copy.
fn copy_tapes(
    arena: &mut Arena,
    column: usize,
    rows: Range<usize>,
    from: &[JsTape],
    tapes: &mut Vec<JsTape>,
) {
    for row in rows {
        if !arena.columns()[column].is_marked_null(row) {
            let position = arena.columns()[column].f64_at(row) as usize;
            tapes.push(from[position].clone());
            arena.set_f64(column, row, (tapes.len() - 1) as f64);
        }
    }
}

/// Where a format's own arena rows, behind a run of items, start in the chunk
/// they come from and in the one they are copied to, and how many there are.
#[derive(Clone, Copy)]
struct DetailRun {
    from: usize,
    to: usize,
    rows: usize,
}

impl DetailRun {
    fn note(run: &mut Option<DetailRun>, detail_row: usize) {
        match run {
            Some(run) => run.rows += 1,
            None => {
                *run = Some(DetailRun {
                    from: detail_row,
                    to: 0,
                    rows: 1,
                })
            }
        }
    }
}

/// The arena holding a row's format-specific fields.
#[derive(Clone, Copy)]
enum DetailArena {
    /// The params arena of an EVM log's registration.
    Params(usize),
    Fuel,
    Svm,
}

/// One value per detail arena of a chunk.
struct PerDetailArena<T> {
    params: Vec<T>,
    fuel: T,
    svm: T,
}

impl<T: Clone + Default> PerDetailArena<T> {
    fn new(params: usize) -> Self {
        PerDetailArena {
            params: vec![T::default(); params],
            fuel: T::default(),
            svm: T::default(),
        }
    }

    fn get(&self, arena: DetailArena) -> &T {
        match arena {
            DetailArena::Params(registration) => &self.params[registration],
            DetailArena::Fuel => &self.fuel,
            DetailArena::Svm => &self.svm,
        }
    }

    fn get_mut(&mut self, arena: DetailArena) -> &mut T {
        match arena {
            DetailArena::Params(registration) => &mut self.params[registration],
            DetailArena::Fuel => &mut self.fuel,
            DetailArena::Svm => &mut self.svm,
        }
    }
}

impl Chunk {
    fn empty() -> Self {
        Chunk {
            start: 0,
            keys: Vec::new(),
            registrations: Vec::new(),
            reads: Vec::new(),
            truncated: false,
            path_ends: Vec::new(),
            path_steps: Vec::new(),
            items: sized_arena(&item_columns(), 0, &[]),
            params: Vec::new(),
            fuel: sized_arena(&fuel_columns(), 0, &[]),
            svm: sized_arena(&svm_columns(), 0, &[]),
            tapes: Vec::new(),
        }
    }

    fn len(&self) -> usize {
        self.keys.len() - self.start
    }

    /// Drops every row from `at` on, and what only they held of the format
    /// arenas. Their tapes stay until the chunk goes.
    fn truncate(&mut self, at: usize) {
        // A format's arena rows run in item order, so the first dropped item
        // of a format says where that arena's kept rows end.
        let mut ends = PerDetailArena::<Option<usize>>::new(self.params.len());
        for row in at..self.keys.len() {
            if let Some(arena) = self.detail_arena_at(row) {
                ends.get_mut(arena).get_or_insert(self.detail_row_at(row));
            }
        }
        for (params, end) in self.params.iter_mut().zip(ends.params) {
            match end {
                Some(0) => *params = None,
                Some(end) => {
                    if let Some(params) = params {
                        params.arena.truncate(end);
                    }
                }
                None => {}
            }
        }
        if let Some(end) = ends.fuel {
            self.fuel.truncate(end);
        }
        if let Some(end) = ends.svm {
            self.svm.truncate(end);
        }
        self.keys.truncate(at);
        self.registrations.truncate(at);
        self.reads.truncate(at);
        self.path_ends.truncate(at);
        self.path_steps
            .truncate(self.path_ends.last().copied().unwrap_or(0) as usize);
        self.items.truncate(at);
        self.truncated |= !self.tapes.is_empty();
    }

    /// Gives back what the columns grew ahead of the rows. Worth a copy only
    /// for a chunk that is kept: a page, a gap-fill merge, a rollback's rest.
    fn shrink_to_fit(&mut self) {
        self.keys.shrink_to_fit();
        self.registrations.shrink_to_fit();
        self.reads.shrink_to_fit();
        self.path_ends.shrink_to_fit();
        self.path_steps.shrink_to_fit();
        self.items.shrink_to_fit();
        for params in self.params.iter_mut().flatten() {
            params.arena.shrink_to_fit();
        }
        self.fuel.shrink_to_fit();
        self.svm.shrink_to_fit();
        self.tapes.shrink_to_fit();
    }

    fn block_number_at(&self, row: usize) -> i64 {
        (self.keys[row] >> 64) as i64
    }

    /// Rows from `start` on at or below `block_number`.
    fn count_at_or_below(&self, block_number: i64) -> usize {
        let bound = sort_key(block_number + 1, ItemKind::Event, 0);
        self.keys[self.start..].partition_point(|key| *key < bound)
    }

    /// The first row from `start` on that doesn't sort before `other`'s `row`.
    fn first_not_before(&self, other: &Chunk, row: usize) -> usize {
        let (mut low, mut high) = (self.start, self.keys.len());
        while low < high {
            let middle = low + (high - low) / 2;
            if self.compare(middle, other, row) == Ordering::Less {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        low
    }

    /// The first row from `start` on that sorts after `other`'s `row`.
    fn first_after(&self, other: &Chunk, row: usize) -> usize {
        let (mut low, mut high) = (self.start, self.keys.len());
        while low < high {
            let middle = low + (high - low) / 2;
            if self.compare(middle, other, row) == Ordering::Greater {
                high = middle;
            } else {
                low = middle + 1;
            }
        }
        low
    }

    fn path(&self, row: usize) -> &[i64] {
        let start = if row == 0 {
            0
        } else {
            self.path_ends[row - 1] as usize
        };
        &self.path_steps[start..self.path_ends[row] as usize]
    }

    /// Total order on rows. `Equal` means a true duplicate: the same log routed
    /// to the same registration, which an overlapping re-fetch delivers again.
    fn compare(&self, row: usize, other: &Chunk, other_row: usize) -> Ordering {
        self.keys[row]
            .cmp(&other.keys[other_row])
            // Lexicographic, so a parent instruction `[1]` precedes its child
            // `[1, 0]`. No path is an empty one.
            .then_with(|| self.path(row).cmp(other.path(other_row)))
            .then(self.registrations[row].cmp(&other.registrations[other_row]))
    }

    fn detail_at(&self, row: usize) -> usize {
        self.items.columns()[item_column::DETAIL].f64_at(row) as usize
    }

    fn format_at(&self, row: usize) -> u8 {
        (self.detail_at(row) & ((1 << FORMAT_BITS) - 1)) as u8
    }

    fn detail_row_at(&self, row: usize) -> usize {
        self.detail_at(row) >> FORMAT_BITS
    }

    fn detail_arena_at(&self, row: usize) -> Option<DetailArena> {
        match self.format_at(row) {
            format if format == RowFormat::EvmLog as u8 => {
                Some(DetailArena::Params(self.registrations[row] as usize))
            }
            format if format == RowFormat::FuelReceipt as u8 => Some(DetailArena::Fuel),
            format if format == RowFormat::SvmInstruction as u8 => Some(DetailArena::Svm),
            _ => None,
        }
    }

    /// Lays sorted rows out.
    fn from_sorted_rows(rows: &[Row]) -> Self {
        // Every arena is sized before it is written, so one pass counts each
        // format's rows and the SVM lists' elements first.
        let (mut fuel_rows, mut svm_rows, mut svm_steps, mut svm_accounts) = (0, 0, 0, 0);
        // By registration index: the schema of its EVM logs' params, and how
        // many.
        let mut params_of: Vec<Option<(&ParamSchema, usize)>> = Vec::new();
        for row in rows {
            match &row.data {
                RowData::EvmLog { params, .. } => {
                    let index = row.registration_index as usize;
                    if params_of.len() <= index {
                        params_of.resize(index + 1, None);
                    }
                    params_of[index].get_or_insert((&params.schema, 0)).1 += 1;
                }
                RowData::FuelReceipt { .. } => fuel_rows += 1,
                RowData::SvmInstruction { accounts, .. } => {
                    svm_rows += 1;
                    svm_steps += row.order_path.as_ref().map_or(0, Vec::len);
                    svm_accounts += accounts.len();
                }
                RowData::Block { .. } | RowData::JsItem { .. } => {}
            }
        }

        let mut tapes = Vec::new();
        let mut items = ArenaWriter::new(sized_arena(&item_columns(), rows.len(), &[]));
        let mut params: Vec<Option<(Vec<ColumnRead>, ArenaWriter)>> = params_of
            .iter()
            .map(|group| {
                group.map(|(schema, logs)| {
                    let columns: Vec<ColumnRead> = schema
                        .params
                        .iter()
                        .zip(&schema.kinds)
                        .map(|(param, kind)| ColumnRead::scalar(param.name.clone(), *kind))
                        .collect();
                    let arena = sized_arena(&columns, logs, &[]);
                    (columns, ArenaWriter::new(arena))
                })
            })
            .collect();
        let mut fuel = ArenaWriter::new(sized_arena(&fuel_columns(), fuel_rows, &[]));
        let mut svm = ArenaWriter::new(sized_arena(
            &svm_columns(),
            svm_rows,
            &[0, 0, svm_steps, 0, svm_accounts],
        ));
        let mut keys = Vec::with_capacity(rows.len());
        let mut registrations = Vec::with_capacity(rows.len());
        let mut reads = Vec::with_capacity(rows.len());
        let mut path_ends = Vec::with_capacity(rows.len());
        let mut path_steps = Vec::new();

        for row in rows {
            keys.push(sort_key(row.block_number, row.kind, row.log_index));
            registrations.push(row.registration_index);
            reads.push(row.data.reads());
            path_steps.extend_from_slice(row.order_path.as_deref().unwrap_or_default());
            path_ends.push(path_steps.len() as u32);

            let registration = row.registration_index as f64;
            let format = row.data.format();
            items.num(item_column::BLOCK_NUMBER, row.block_number as f64);
            items.num(item_column::LOG_INDEX, row.log_index as f64);
            items.num(item_column::REGISTRATION_INDEX, registration);
            let unset: &[usize] = match &row.data {
                RowData::EvmLog {
                    src_address,
                    transaction_index,
                    params: log_params,
                } => {
                    let (_, group) = params[row.registration_index as usize]
                        .as_mut()
                        .expect("counted in the first pass");
                    for (column, cell) in log_params.cells.iter().enumerate() {
                        match cell {
                            ParamCell::Bool(value) => group.bool(column, *value),
                            ParamCell::Text(value) => group.bytes(column, value.as_bytes()),
                            ParamCell::Tape(tape) => group.tape(column, &mut tapes, tape),
                        }
                    }
                    items.num(item_column::TRANSACTION_INDEX, *transaction_index as f64);
                    items.bytes(item_column::SRC_ADDRESS, src_address.as_bytes());
                    items.num(item_column::DETAIL, pack_detail(format, group.row));
                    group.end_row();
                    &[item_column::SKIPPED, item_column::TAPE]
                }
                RowData::FuelReceipt {
                    tx_id,
                    src_address,
                    params,
                } => {
                    fuel.num(0, row.log_index as f64);
                    fuel.bytes(1, tx_id.as_bytes());
                    fuel.num(2, row.block_number as f64);
                    fuel.bytes(3, src_address.as_bytes());
                    fuel.tape(4, &mut tapes, params);
                    items.num(item_column::DETAIL, pack_detail(format, fuel.row));
                    fuel.end_row();
                    &[
                        item_column::TRANSACTION_INDEX,
                        item_column::SRC_ADDRESS,
                        item_column::SKIPPED,
                        item_column::TAPE,
                    ]
                }
                RowData::SvmInstruction {
                    program_id,
                    accounts,
                    data,
                    is_inner,
                    args,
                    logs,
                } => {
                    svm.num(0, row.block_number as f64);
                    svm.num(1, row.log_index as f64);
                    svm.num_list(2, row.order_path.as_deref().unwrap_or_default());
                    svm.bytes(3, program_id.as_bytes());
                    svm.text_list(4, accounts);
                    svm.bytes(5, data);
                    svm.bool(6, *is_inner);
                    svm.optional_tape(7, &mut tapes, args);
                    svm.optional_tape(8, &mut tapes, logs);
                    items.num(item_column::DETAIL, pack_detail(format, svm.row));
                    // A slot's transaction is keyed by its index, the row's
                    // within-block order.
                    items.num(item_column::TRANSACTION_INDEX, row.log_index as f64);
                    svm.end_row();
                    &[
                        item_column::SRC_ADDRESS,
                        item_column::SKIPPED,
                        item_column::TAPE,
                    ]
                }
                RowData::Block { skipped } => {
                    items.bool(item_column::SKIPPED, *skipped);
                    items.num(item_column::DETAIL, pack_detail(format, 0));
                    &[
                        item_column::TRANSACTION_INDEX,
                        item_column::SRC_ADDRESS,
                        item_column::TAPE,
                    ]
                }
                RowData::JsItem {
                    item,
                    transaction_index,
                    ..
                } => {
                    items.tape(item_column::TAPE, &mut tapes, item);
                    items.num(item_column::DETAIL, pack_detail(format, 0));
                    match transaction_index {
                        Some(index) => {
                            items.num(item_column::TRANSACTION_INDEX, *index as f64);
                            &[item_column::SRC_ADDRESS, item_column::SKIPPED]
                        }
                        None => &[
                            item_column::TRANSACTION_INDEX,
                            item_column::SRC_ADDRESS,
                            item_column::SKIPPED,
                        ],
                    }
                }
            };
            for column in unset {
                items.null(*column);
            }
            items.end_row();
        }

        Chunk {
            start: 0,
            keys,
            registrations,
            reads,
            truncated: false,
            path_ends,
            path_steps,
            items: items.arena,
            params: params
                .into_iter()
                .map(|group| {
                    group.map(|(columns, writer)| Params {
                        columns,
                        arena: writer.arena,
                    })
                })
                .collect(),
            fuel: fuel.arena,
            svm: svm.arena,
            tapes,
        }
    }

    /// Appends `rows` of `other`, every column a range at a time, then points
    /// the copied items at where their format's rows and their tapes landed.
    fn extend_from(&mut self, other: &Chunk, rows: Range<usize>) {
        if rows.is_empty() {
            return;
        }
        self.keys.extend_from_slice(&other.keys[rows.clone()]);
        self.registrations
            .extend_from_slice(&other.registrations[rows.clone()]);
        self.reads.extend_from_slice(&other.reads[rows.clone()]);
        let steps_start = if rows.start == 0 {
            0
        } else {
            other.path_ends[rows.start - 1]
        };
        let steps_end = other.path_ends[rows.end - 1];
        let steps_base = self.path_steps.len() as u32;
        self.path_steps
            .extend_from_slice(&other.path_steps[steps_start as usize..steps_end as usize]);
        self.path_ends.extend(
            other.path_ends[rows.clone()]
                .iter()
                .map(|end| end - steps_start + steps_base),
        );

        // A format's arena rows behind a run of items are themselves one run,
        // in the same order.
        let mut runs = PerDetailArena::<Option<DetailRun>>::new(other.params.len());
        for row in rows.clone() {
            if let Some(arena) = other.detail_arena_at(row) {
                DetailRun::note(runs.get_mut(arena), other.detail_row_at(row));
            }
        }
        if self.params.len() < other.params.len() {
            self.params.resize_with(other.params.len(), || None);
        }
        for (registration, run) in runs.params.iter_mut().enumerate() {
            let Some(run) = run else { continue };
            let from = other.params[registration]
                .as_ref()
                .expect("a log's registration has params");
            let to = self.params[registration].get_or_insert_with(|| Params {
                columns: from.columns.clone(),
                arena: Arena::empty_like(&from.arena),
            });
            run.to = to.arena.rows();
            to.arena
                .extend_from(&from.arena, run.from..run.from + run.rows);
            for column in tape_columns(&from.columns) {
                copy_tapes(
                    &mut to.arena,
                    column,
                    run.to..run.to + run.rows,
                    &other.tapes,
                    &mut self.tapes,
                );
            }
        }
        for (run, to, from, columns) in [
            (
                &mut runs.fuel,
                &mut self.fuel,
                &other.fuel,
                fuel_columns as fn() -> Vec<ColumnRead>,
            ),
            (&mut runs.svm, &mut self.svm, &other.svm, svm_columns),
        ] {
            let Some(run) = run else { continue };
            run.to = to.rows();
            to.extend_from(from, run.from..run.from + run.rows);
            for column in tape_columns(&columns()) {
                copy_tapes(
                    to,
                    column,
                    run.to..run.to + run.rows,
                    &other.tapes,
                    &mut self.tapes,
                );
            }
        }

        let first = self.items.rows();
        self.items.extend_from(&other.items, rows.clone());
        for (offset, row) in rows.enumerate() {
            if let Some(run) = other
                .detail_arena_at(row)
                .and_then(|arena| *runs.get(arena))
            {
                let detail_row = run.to + other.detail_row_at(row) - run.from;
                let detail = (detail_row << FORMAT_BITS) | other.format_at(row) as usize;
                self.items
                    .set_f64(item_column::DETAIL, first + offset, detail as f64);
            }
        }
        let copied = first..self.items.rows();
        copy_tapes(
            &mut self.items,
            item_column::TAPE,
            copied,
            &other.tapes,
            &mut self.tapes,
        );
    }

    /// Which transaction and block each item reads from the chain's stores,
    /// as its row among the batch's distinct ones, and the keys and selected
    /// fields of those rows for the stores to read. Consecutive items of one
    /// transaction or block share its row, selecting the union of their
    /// fields; the rows are sorted, so they are consecutive.
    fn join(&self, fields: &JoinedFields) -> Joined {
        let rows = self.start..self.keys.len();
        let mut links = sized_arena(&link_columns(), rows.len(), &[]);
        let (mut transaction_blocks, mut transaction_indexes, mut transaction_masks) =
            (Vec::new(), Vec::<u32>::new(), Vec::<u64>::new());
        let (mut block_numbers, mut block_masks) = (Vec::new(), Vec::<u64>::new());
        let mask_of = |masks: &[f64], registration: i64| {
            masks.get(registration as usize).copied().unwrap_or(0.0) as u64
        };
        let mut any_transaction_field = false;
        for (out, row) in rows.enumerate() {
            let event = self.keys[row] & KIND_BIT == 0;
            let registration = self.registrations[row];
            let block_number = self.block_number_at(row);
            if self.reads[row] & READS_TRANSACTION != 0 {
                let mask = if event {
                    mask_of(&fields.transaction_masks, registration)
                } else {
                    0
                };
                any_transaction_field |= mask != 0;
                let index = self.items.columns()[item_column::TRANSACTION_INDEX].f64_at(row) as u32;
                if transaction_blocks.last() == Some(&block_number)
                    && transaction_indexes.last() == Some(&index)
                {
                    *transaction_masks.last_mut().unwrap() |= mask;
                } else {
                    transaction_blocks.push(block_number);
                    transaction_indexes.push(index);
                    transaction_masks.push(mask);
                }
                links.set_f64(
                    link_column::TRANSACTION,
                    out,
                    (transaction_blocks.len() - 1) as f64,
                );
            } else {
                links.mark_null(link_column::TRANSACTION, out);
            }
            let block_mask = if self.reads[row] & READS_BLOCK == 0 {
                None
            } else if event {
                Some(mask_of(&fields.event_block_masks, registration))
            } else {
                fields
                    .block_handler_masks
                    .get(registration as usize)
                    .copied()
                    .flatten()
                    .map(|mask| mask as u64)
            };
            match block_mask {
                Some(mask) => {
                    if block_numbers.last() == Some(&block_number) {
                        *block_masks.last_mut().unwrap() |= mask;
                    } else {
                        block_numbers.push(block_number);
                        block_masks.push(mask);
                    }
                    links.set_f64(link_column::BLOCK, out, (block_numbers.len() - 1) as f64);
                }
                None => links.mark_null(link_column::BLOCK, out),
            }
        }
        // With no transaction field selected anywhere in the batch, each item
        // still gets a transaction: an empty object of its own.
        let transaction_keys = if any_transaction_field {
            Some(TransactionKeys {
                block_numbers: Float64Array::new(
                    transaction_blocks
                        .iter()
                        .map(|block| *block as f64)
                        .collect(),
                ),
                transaction_indexes: Uint32Array::new(transaction_indexes),
                masks: Float64Array::new(
                    transaction_masks.iter().map(|mask| *mask as f64).collect(),
                ),
            })
        } else {
            for out in 0..links.rows() {
                if !links.columns()[link_column::TRANSACTION].is_marked_null(out) {
                    links.set_f64(link_column::TRANSACTION, out, EMPTY_LINK);
                }
            }
            None
        };
        // The same for blocks: with no block field selected there is nothing to
        // read, and each item gets an empty block object of its own.
        let block_keys = if block_masks.iter().any(|mask| *mask != 0) {
            Some(BlockKeys {
                block_numbers: Float64Array::new(
                    block_numbers.iter().map(|block| *block as f64).collect(),
                ),
                masks: Float64Array::new(block_masks.iter().map(|mask| *mask as f64).collect()),
            })
        } else {
            for out in 0..links.rows() {
                if !links.columns()[link_column::BLOCK].is_marked_null(out) {
                    links.set_f64(link_column::BLOCK, out, EMPTY_LINK);
                }
            }
            None
        };
        Joined {
            links,
            transaction_keys,
            block_keys,
        }
    }

    /// Hands the arenas to JavaScript to read, with the links and keys `joined`
    /// planned for them.
    fn lay_out(mut self, joined: Option<Joined>) -> Result<StoredRows> {
        // `take` hands over a chunk whole only from its first row, and every
        // other result is a fresh chunk.
        debug_assert_eq!(self.start, 0);
        let seal = |columns: &[ColumnRead], arena: &mut Arena| -> Result<ArenaShape> {
            let shape = ArenaShape::of(columns, arena.rows());
            arena.seal(&shape.names)?;
            Ok(shape)
        };
        let items = seal(&item_columns(), &mut self.items)?;
        let mut arenas = vec![self.items];
        let mut params = Vec::new();
        for (registration_index, group) in self.params.into_iter().enumerate() {
            if let Some(mut group) = group {
                params.push(ParamsShape {
                    registration_index: registration_index as i64,
                    shape: seal(&group.columns, &mut group.arena)?,
                });
                arenas.push(group.arena);
            }
        }
        let fuel = seal(&fuel_columns(), &mut self.fuel)?;
        arenas.push(self.fuel);
        let svm = seal(&svm_columns(), &mut self.svm)?;
        arenas.push(self.svm);
        let (mut links, mut transaction_keys, mut block_keys) = (None, None, None);
        if let Some(mut joined) = joined {
            links = Some(seal(&link_columns(), &mut joined.links)?);
            arenas.push(joined.links);
            transaction_keys = joined.transaction_keys;
            block_keys = joined.block_keys;
        }

        let handle = hold(arenas)?;
        Ok(StoredRows {
            handle,
            items,
            params,
            fuel,
            svm,
            links,
            transaction_keys,
            block_keys,
            tapes: self.tapes,
        })
    }
}

/// The columns of an arena result, which JavaScript builds its views from.
#[napi(object)]
pub struct ArenaShape {
    pub names: Vec<String>,
    /// `ReadKind` ordinals.
    pub kinds: Vec<u8>,
    pub element_kinds: Vec<Option<u8>>,
    pub rows: u32,
}

impl ArenaShape {
    pub(crate) fn of(columns: &[ColumnRead], rows: usize) -> Self {
        ArenaShape {
            names: columns.iter().map(|column| column.name.clone()).collect(),
            kinds: columns.iter().map(|column| column.kind as u8).collect(),
            element_kinds: columns
                .iter()
                .map(|column| column.element.map(|kind| kind as u8))
                .collect(),
            rows: rows as u32,
        }
    }
}

/// The params of one registration's EVM logs, one row per log.
#[napi(object)]
pub struct ParamsShape {
    pub registration_index: i64,
    pub shape: ArenaShape,
}

/// Items on their way to JS. The arenas behind `handle` hold `items`, one row
/// per item in processing order; then each registration's EVM `params`; then
/// `fuel` and `svm`, the whole item record of each such row; then, for a
/// joined take, `links`. `tapes` carries what has no column shape.
/// `EventStore.lendRows` lends the arenas' buffers in that order, and
/// `EventStore.releaseRows` takes them back.
#[napi(object, object_from_js = false)]
pub struct StoredRows {
    pub handle: u32,
    pub items: ArenaShape,
    pub params: Vec<ParamsShape>,
    pub fuel: ArenaShape,
    pub svm: ArenaShape,
    /// For a joined result, each item's row among the transactions and the
    /// blocks it reads from the chain's stores, null where it reads none;
    /// `EMPTY_LINK` gives it an empty object of its own.
    pub links: Option<ArenaShape>,
    /// The keys and selected fields of those transactions, for
    /// `TransactionStore.readFields`; absent when no item selects any.
    pub transaction_keys: Option<TransactionKeys>,
    /// The same of the blocks, for `BlockStore.readFields`.
    pub block_keys: Option<BlockKeys>,
    pub tapes: Vec<JsTape>,
}

/// Which fields each registration selects of its items' transaction and
/// block, as the field-code masks its field selection compiled to.
#[napi(object)]
pub struct JoinedFields {
    /// By event registration index.
    pub transaction_masks: Vec<f64>,
    /// By event registration index.
    pub event_block_masks: Vec<f64>,
    /// By block registration index; `None` where the handler reads no block
    /// field beyond its number.
    pub block_handler_masks: Vec<Option<f64>>,
}

#[napi(object, object_from_js = false)]
pub struct TransactionKeys {
    pub block_numbers: Float64Array,
    pub transaction_indexes: Uint32Array,
    /// Field-code masks.
    pub masks: Float64Array,
}

#[napi(object, object_from_js = false)]
pub struct BlockKeys {
    pub block_numbers: Float64Array,
    /// Field-code masks.
    pub masks: Float64Array,
}

struct Joined {
    links: Arena,
    transaction_keys: Option<TransactionKeys>,
    block_keys: Option<BlockKeys>,
}

/// A link to no store row: the item gets an empty object of its own.
const EMPTY_LINK: f64 = -1.0;

fn link_columns() -> Vec<ColumnRead> {
    vec![
        ColumnRead::scalar("transactionRow", ReadKind::Float),
        ColumnRead::scalar("blockRow", ReadKind::Float),
    ]
}

/// Positions in `link_columns`.
mod link_column {
    pub(super) const TRANSACTION: usize = 0;
    pub(super) const BLOCK: usize = 1;
}

/// The arenas of the results JavaScript has yet to read, by handle.
struct Lent {
    arenas: Vec<Arena>,
    /// How many buffers each arena lent, so each takes back its own.
    buffer_counts: Vec<usize>,
}

/// The results JavaScript has yet to read, in reused slots. A handle is its
/// slot in the low `SLOT_BITS` and the slot's generation above them, so a
/// handle released twice finds nothing once its slot holds another result.
#[derive(Default)]
struct Results {
    slots: Vec<(u32, Option<Lent>)>,
    free: Vec<u32>,
}

const SLOT_BITS: u32 = 16;

impl Results {
    fn insert(&mut self, lent: Lent) -> Result<u32> {
        let slot = match self.free.pop() {
            Some(slot) => slot,
            None => {
                if self.slots.len() >= 1 << SLOT_BITS {
                    anyhow::bail!(
                        "{} results are waiting to be read, more than handles can address",
                        self.slots.len()
                    );
                }
                self.slots.push((0, None));
                (self.slots.len() - 1) as u32
            }
        };
        let (generation, entry) = &mut self.slots[slot as usize];
        // Never zero, so no handle is 0.
        *generation = (*generation % ((1 << (32 - SLOT_BITS)) - 1)) + 1;
        *entry = Some(lent);
        Ok((*generation << SLOT_BITS) | slot)
    }

    fn entry(&mut self, handle: u32) -> Option<&mut Option<Lent>> {
        let slot = (handle & ((1 << SLOT_BITS) - 1)) as usize;
        self.slots
            .get_mut(slot)
            .filter(|(generation, _)| *generation == handle >> SLOT_BITS)
            .map(|(_, entry)| entry)
    }

    fn get_mut(&mut self, handle: u32) -> Option<&mut Lent> {
        self.entry(handle)?.as_mut()
    }

    fn remove(&mut self, handle: u32) -> Option<Lent> {
        let lent = self.entry(handle)?.take()?;
        self.free.push(handle & ((1 << SLOT_BITS) - 1));
        Some(lent)
    }
}

static RESULTS: LazyLock<Mutex<Results>> = LazyLock::new(Default::default);

/// Keeps sealed arenas until JavaScript has read them through `lendRows` and
/// `releaseRows`, by the handle this returns.
pub(crate) fn hold(arenas: Vec<Arena>) -> Result<u32> {
    RESULTS.lock().unwrap().insert(Lent {
        arenas,
        buffer_counts: Vec::new(),
    })
}

const ITEM_COLUMNS: [(&str, ReadKind); 8] = [
    // The row's `RowFormat` in the low `FORMAT_BITS`, and above them its place
    // in its format's own arena: an EVM log's in its registration's params, a
    // Fuel receipt's or SVM instruction's in theirs.
    ("detail", ReadKind::Float),
    ("blockNumber", ReadKind::Float),
    ("logIndex", ReadKind::Float),
    ("transactionIndex", ReadKind::Float),
    ("registrationIndex", ReadKind::Float),
    ("srcAddress", ReadKind::Text),
    ("skipped", ReadKind::Bool),
    // A JS-built row's item.
    ("tape", ReadKind::Float),
];

/// Positions in `ITEM_COLUMNS`.
mod item_column {
    pub(super) const DETAIL: usize = 0;
    pub(super) const BLOCK_NUMBER: usize = 1;
    pub(super) const LOG_INDEX: usize = 2;
    pub(super) const TRANSACTION_INDEX: usize = 3;
    pub(super) const REGISTRATION_INDEX: usize = 4;
    pub(super) const SRC_ADDRESS: usize = 5;
    pub(super) const SKIPPED: usize = 6;
    pub(super) const TAPE: usize = 7;
}

const FORMAT_BITS: u32 = 3;

/// A row's `detail` cell: its format, and its row in that format's arena.
fn pack_detail(format: RowFormat, detail_row: usize) -> f64 {
    ((detail_row << FORMAT_BITS) | format as usize) as f64
}

/// Named as `FuelHyperSyncClient.EventItems.item`'s fields, so a row reads as
/// that record.
fn fuel_columns() -> Vec<ColumnRead> {
    vec![
        ColumnRead::scalar("receiptIndex", ReadKind::Float),
        ColumnRead::scalar("txId", ReadKind::Text),
        ColumnRead::scalar("blockHeight", ReadKind::Float),
        ColumnRead::scalar("srcAddress", ReadKind::Text),
        ColumnRead::scalar("params", ReadKind::Tape),
    ]
}

/// Named as `SvmHyperSyncClient.Items.item`'s fields.
fn svm_columns() -> Vec<ColumnRead> {
    vec![
        ColumnRead::scalar("slot", ReadKind::Float),
        ColumnRead::scalar("transactionIndex", ReadKind::Float),
        ColumnRead::list("path", ReadKind::Float),
        ColumnRead::scalar("programId", ReadKind::Text),
        ColumnRead::list("accounts", ReadKind::Text),
        ColumnRead::scalar("data", ReadKind::Bytes),
        ColumnRead::scalar("isInner", ReadKind::Bool),
        ColumnRead::scalar("args", ReadKind::Tape),
        ColumnRead::scalar("logs", ReadKind::Tape),
    ]
}

/// An arena written row by row: each column once per row, rows in order,
/// which is how a variable-width or list column finds where its row starts.
struct ArenaWriter {
    arena: Arena,
    row: usize,
    /// List elements written so far, per column.
    elements: Vec<usize>,
}

impl ArenaWriter {
    fn new(arena: Arena) -> Self {
        ArenaWriter {
            elements: vec![0; arena.columns().len()],
            arena,
            row: 0,
        }
    }

    fn num(&mut self, column: usize, value: f64) {
        self.arena.set_f64(column, self.row, value);
    }

    fn bool(&mut self, column: usize, value: bool) {
        self.num(column, if value { 1.0 } else { 0.0 });
    }

    fn bytes(&mut self, column: usize, value: &[u8]) {
        self.arena.set_bytes(column, self.row, value);
    }

    fn null(&mut self, column: usize) {
        self.arena.mark_null(column, self.row);
    }

    /// A tape's position among the chunk's tapes.
    fn tape(&mut self, column: usize, tapes: &mut Vec<JsTape>, tape: &JsTape) {
        tapes.push(tape.clone());
        self.num(column, (tapes.len() - 1) as f64);
    }

    fn optional_tape(&mut self, column: usize, tapes: &mut Vec<JsTape>, tape: &Option<JsTape>) {
        match tape {
            Some(tape) => self.tape(column, tapes, tape),
            None => self.null(column),
        }
    }

    fn num_list(&mut self, column: usize, values: &[i64]) {
        for value in values {
            self.arena
                .set_element_f64(column, self.elements[column], *value as f64);
            self.elements[column] += 1;
        }
        self.arena
            .end_list_row(column, self.row, self.elements[column]);
    }

    fn text_list(&mut self, column: usize, values: &[String]) {
        for value in values {
            self.arena
                .set_element_bytes(column, self.elements[column], value.as_bytes());
            self.elements[column] += 1;
        }
        self.arena
            .end_list_row(column, self.row, self.elements[column]);
    }

    fn end_row(&mut self) {
        self.row += 1;
    }
}

fn to_napi(err: anyhow::Error) -> napi::Error {
    napi::Error::from_reason(format!("{err:#}"))
}

/// An item built in JS, its registration replaced by the registration's index.
#[napi(object)]
pub struct JsItemInput {
    /// 0 for an event, 1 for a block handler's item.
    pub kind: i32,
    pub block_number: i64,
    pub log_index: i64,
    pub order_path: Option<Vec<i64>>,
    pub registration_index: i64,
    pub item: JsTape,
    /// The key of the item's transaction in the chain's store, when the item
    /// doesn't carry the transaction itself.
    pub transaction_index: Option<i64>,
    /// Whether the item's block comes from the chain's store.
    pub block_from_store: bool,
}

#[napi]
pub struct EventStore {
    rows: Mutex<Rows>,
}

impl EventStore {
    pub(crate) fn from_rows(rows: Vec<Row>) -> Self {
        EventStore {
            rows: Mutex::new(Rows::from_unsorted(rows)),
        }
    }

    fn rows(&self) -> std::sync::MutexGuard<'_, Rows> {
        self.rows.lock().unwrap()
    }

    fn insert(&self, incoming: Vec<Row>) {
        self.rows().merge(Rows::from_unsorted(incoming));
    }
}

#[napi]
impl EventStore {
    #[napi(factory)]
    pub fn empty() -> Self {
        EventStore::from_rows(Vec::new())
    }

    #[napi(factory)]
    pub fn from_js_items(items: Vec<JsItemInput>) -> napi::Result<Self> {
        let rows = items
            .into_iter()
            .map(|item| {
                let kind = match item.kind {
                    0 => ItemKind::Event,
                    1 => ItemKind::Block,
                    other => {
                        return Err(napi::Error::from_reason(format!(
                            "unknown item kind {other}"
                        )))
                    }
                };
                if item.block_number < 0 || item.log_index < 0 {
                    return Err(napi::Error::from_reason(format!(
                        "an item's block number and log index can't be negative, got {} and {}",
                        item.block_number, item.log_index
                    )));
                }
                Ok(Row {
                    block_number: item.block_number,
                    kind,
                    log_index: item.log_index,
                    order_path: item.order_path,
                    registration_index: item.registration_index,
                    data: RowData::JsItem {
                        item: item.item,
                        transaction_index: item.transaction_index,
                        block_from_store: item.block_from_store,
                    },
                })
            })
            .collect::<napi::Result<Vec<_>>>()?;
        Ok(EventStore::from_rows(rows))
    }

    /// Moves `page`'s rows in, leaving it empty.
    #[napi]
    pub fn merge(&self, page: &EventStore) {
        // Each lock alone: a page merged into itself would otherwise wait on
        // its own lock.
        let incoming = std::mem::take(&mut *page.rows());
        self.rows().merge(incoming);
    }

    /// Block handler items generated locally, one per `(blockNumber,
    /// registrationIndex)` pair.
    #[napi]
    pub fn insert_block_items(&self, block_numbers: Vec<i64>, registration_indexes: Vec<i64>) {
        let rows = block_numbers
            .into_iter()
            .zip(registration_indexes)
            .map(|(block_number, registration_index)| {
                Row::block(block_number, registration_index, false)
            })
            .collect();
        self.insert(rows);
    }

    #[napi]
    pub fn len(&self) -> u32 {
        self.rows().len() as u32
    }

    #[napi]
    pub fn block_number_at(&self, index: u32) -> Option<i64> {
        self.rows().block_number_at(index as usize)
    }

    #[napi]
    pub fn first_event_block_number(&self) -> Option<i64> {
        self.rows()
            .keys()
            .find(|key| key & KIND_BIT == 0)
            .map(|key| (key >> 64) as i64)
    }

    /// How many rows are at or below `block_number`.
    #[napi]
    pub fn count_at_or_below(&self, block_number: i64) -> u32 {
        self.rows().count_at_or_below(block_number) as u32
    }

    /// How many rows a batch takes: those at or below `frontier`, up to
    /// `target_size`, and then the rest of the last block, so a batch never
    /// splits a block.
    #[napi]
    pub fn ready_count(&self, frontier: i64, target_size: u32) -> u32 {
        let rows = self.rows();
        let mut ready_block_number = frontier;
        let mut count = 0u32;
        for key in rows.keys() {
            let block_number = (key >> 64) as i64;
            if block_number > ready_block_number {
                break;
            }
            count += 1;
            if count == target_size {
                ready_block_number = block_number;
            }
        }
        count
    }

    /// Removes the first `count` rows and lays them out, with no join.
    #[cfg(test)]
    pub fn take(&self, count: u32) -> napi::Result<StoredRows> {
        let taken = self.rows().take(count as usize);
        taken.lay_out(None).map_err(to_napi)
    }

    /// Removes the first `count` rows and lays them out for JS, with what each
    /// item reads from the chain's transaction and block stores planned: its
    /// links, and the keys the stores read.
    #[napi]
    pub fn take_joined(&self, count: u32, fields: JoinedFields) -> napi::Result<StoredRows> {
        let taken = self.rows().take(count as usize);
        let joined = taken.join(&fields);
        taken.lay_out(Some(joined)).map_err(to_napi)
    }

    /// The event rows routed to any of `registration_indexes`, in order, laid
    /// out for JS. The rows stay.
    #[napi]
    pub fn events_of_registrations(
        &self,
        registration_indexes: Vec<i64>,
        fields: JoinedFields,
    ) -> napi::Result<StoredRows> {
        let selected = self.rows().select(|chunk, row| {
            chunk.keys[row] & KIND_BIT == 0
                && registration_indexes.contains(&chunk.registrations[row])
        });
        let joined = selected.join(&fields);
        selected.lay_out(Some(joined)).map_err(to_napi)
    }

    /// Every row, in order, laid out for JS. The rows stay.
    #[napi]
    pub fn all_items(&self) -> napi::Result<StoredRows> {
        let all = self.rows().select(|_, _| true);
        all.lay_out(None).map_err(to_napi)
    }

    /// Drops every row above `target_block_number`.
    #[napi]
    pub fn rollback(&self, target_block_number: i64) {
        self.rows().rollback(target_block_number);
    }

    /// Every buffer of a held result's arenas, in the order they were held.
    #[napi]
    pub fn lend_rows<'env>(env: &'env Env, handle: u32) -> napi::Result<Vec<ArrayBuffer<'env>>> {
        let mut results = RESULTS.lock().unwrap();
        let lent = results
            .get_mut(handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown rows {handle}")))?;
        let mut buffers = Vec::new();
        for arena in lent.arenas.iter_mut() {
            match columnar_js::lend_for_reading(env, arena) {
                Ok(lent_buffers) => {
                    lent.buffer_counts.push(lent_buffers.len());
                    buffers.extend(lent_buffers);
                }
                Err(error) => {
                    // JavaScript never sees this result, so it is freed here,
                    // with what was lent of it taken back first.
                    let lent = results.remove(handle).unwrap();
                    give_back(lent, buffers).ok();
                    return Err(error);
                }
            }
        }
        Ok(buffers)
    }

    /// Takes a result's buffers back and frees it.
    #[napi]
    pub fn release_rows(handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        let Some(lent) = RESULTS.lock().unwrap().remove(handle) else {
            return Ok(());
        };
        give_back(lent, buffers)
    }
}

/// Detaches `buffers`, each arena's in turn, and frees the arenas. One that
/// cannot be detached still has a JavaScript view into its memory, so the
/// memory is abandoned rather than freed.
fn give_back(mut lent: Lent, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
    let mut buffers = buffers.into_iter();
    let mut failure = None;
    for (arena, count) in lent.arenas.iter_mut().zip(&lent.buffer_counts) {
        let own: Vec<ArrayBuffer> = buffers.by_ref().take(*count).collect();
        if let Err(error) = columnar_js::detach_all(arena, own) {
            failure = Some(error);
        }
    }
    match failure {
        None => Ok(()),
        Some(error) => {
            std::mem::forget(lent);
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_value::test_value::JsValue;

    fn event(block_number: i64, log_index: i64, registration_index: i64, tag: &str) -> Row {
        let mut data = JsTape::new();
        data.str(tag);
        Row::event(
            block_number,
            log_index,
            None,
            registration_index,
            RowData::JsItem {
                item: data,
                transaction_index: None,
                block_from_store: false,
            },
        )
    }

    fn svm(slot: i64, transaction_index: i64, path: &[i64], tag: &str) -> Row {
        let mut data = JsTape::new();
        data.str(tag);
        Row::event(
            slot,
            transaction_index,
            Some(path.to_vec()),
            0,
            RowData::JsItem {
                item: data,
                transaction_index: None,
                block_from_store: false,
            },
        )
    }

    /// What each laid-out row reads as: a tape row its tape, a block row its
    /// block and registration. Frees the result.
    fn read(rows: StoredRows) -> Vec<JsValue> {
        let lent = RESULTS.lock().unwrap().remove(rows.handle).unwrap();
        let columns = lent.arenas[0].columns();
        let column = |name: &str| ITEM_COLUMNS.iter().position(|(n, _)| *n == name).unwrap();
        (0..rows.items.rows as usize)
            .map(|row| {
                let format =
                    columns[column("detail")].f64_at(row) as usize & ((1 << FORMAT_BITS) - 1);
                if format == RowFormat::Block as usize {
                    JsValue::str(&format!(
                        "block {} r{}",
                        columns[column("blockNumber")].f64_at(row),
                        columns[column("registrationIndex")].f64_at(row)
                    ))
                } else {
                    let tape = columns[column("tape")].f64_at(row) as usize;
                    JsValue::of(&rows.tapes[tape])
                }
            })
            .collect()
    }

    fn take_all(store: &EventStore) -> Vec<JsValue> {
        read(store.take(u32::MAX).unwrap())
    }

    #[test]
    fn orders_by_block_then_events_before_block_items_then_log_and_registration() {
        let store = EventStore::from_rows(vec![
            Row::block(2, 0, false),
            event(2, 5, 1, "b2-l5-r1"),
            event(1, 9, 0, "b1-l9"),
            event(2, 5, 0, "b2-l5-r0"),
            event(2, 1, 0, "b2-l1"),
        ]);
        assert_eq!(
            take_all(&store),
            vec![
                JsValue::str("b1-l9"),
                JsValue::str("b2-l1"),
                JsValue::str("b2-l5-r0"),
                JsValue::str("b2-l5-r1"),
                JsValue::str("block 2 r0"),
            ]
        );
    }

    #[test]
    fn orders_svm_instructions_parent_before_child() {
        let store = EventStore::from_rows(vec![
            svm(7, 3, &[1, 0], "child"),
            svm(7, 3, &[2], "sibling"),
            svm(7, 3, &[1], "parent"),
        ]);
        assert_eq!(
            take_all(&store),
            vec![
                JsValue::str("parent"),
                JsValue::str("child"),
                JsValue::str("sibling")
            ]
        );
    }

    fn tagged(tag: &str) -> JsTape {
        let mut tape = JsTape::new();
        tape.str(tag);
        tape
    }

    fn evm(block_number: i64, registration_index: i64, value: &str) -> Row {
        use crate::evm_hypersync_source::types::{ParamMeta, ParamSchema};
        let meta = |name: &str, abi_type: &str| ParamMeta {
            name: name.into(),
            abi_type: abi_type.into(),
            indexed: false,
            components: None,
        };
        let schema = std::sync::Arc::new(ParamSchema::new(
            vec![meta("value", "uint256"), meta("list", "uint256[]")],
            false,
        ));
        Row::event(
            block_number,
            0,
            None,
            registration_index,
            RowData::EvmLog {
                src_address: "0xsrc".into(),
                transaction_index: 0,
                params: EvmParams {
                    cells: vec![
                        ParamCell::Text(value.into()),
                        ParamCell::Tape(tagged(&format!("{value} list"))),
                    ],
                    schema,
                },
            },
        )
    }

    /// Each row as its format's arena row says it, followed through
    /// `detailRow` and its tape cells. Frees the result.
    fn describe(rows: StoredRows) -> Vec<String> {
        let lent = RESULTS.lock().unwrap().remove(rows.handle).unwrap();
        let items = lent.arenas[0].columns();
        let fuel = lent.arenas[1 + rows.params.len()].columns();
        let svm = lent.arenas[2 + rows.params.len()].columns();
        let tape = |position: f64| format!("{:?}", JsValue::of(&rows.tapes[position as usize]));
        let text =
            |column: &crate::columnar::Column, row: usize| column.str_at(row).unwrap().to_string();
        (0..rows.items.rows as usize)
            .map(|row| {
                let block = items[item_column::BLOCK_NUMBER].f64_at(row);
                let packed = items[item_column::DETAIL].f64_at(row) as usize;
                let detail = packed >> FORMAT_BITS;
                let registration = items[item_column::REGISTRATION_INDEX].f64_at(row) as i64;
                match (packed & ((1 << FORMAT_BITS) - 1)) as u8 {
                    format if format == RowFormat::EvmLog as u8 => {
                        let group = rows
                            .params
                            .iter()
                            .position(|group| group.registration_index == registration)
                            .unwrap();
                        let params = lent.arenas[1 + group].columns();
                        format!(
                            "evm {block} r{registration} {} {}",
                            text(&params[0], detail),
                            tape(params[1].f64_at(detail))
                        )
                    }
                    format if format == RowFormat::FuelReceipt as u8 => format!(
                        "fuel {block} {} {}",
                        text(&fuel[1], detail),
                        tape(fuel[4].f64_at(detail))
                    ),
                    _ => {
                        let (steps, ends) = svm[2].list().unwrap();
                        let start = if detail == 0 {
                            0
                        } else {
                            ends[detail - 1] as usize
                        };
                        let path: Vec<f64> = (start..ends[detail] as usize)
                            .map(|step| steps.f64_at(step))
                            .collect();
                        format!(
                            "svm {block} {path:?} {} {}",
                            text(&svm[3], detail),
                            tape(svm[7].f64_at(detail))
                        )
                    }
                }
            })
            .collect()
    }

    #[test]
    fn a_page_inside_a_chunk_keeps_the_formats_of_the_rows_before_it() {
        let fuel = |block_number: i64, tag: &str| {
            Row::event(
                block_number,
                1,
                None,
                3,
                RowData::FuelReceipt {
                    tx_id: tag.into(),
                    src_address: "0xfuel".into(),
                    params: tagged(tag),
                },
            )
        };
        let store = EventStore::from_rows(vec![
            evm(1, 0, "1"),
            fuel(1, "fuel 1"),
            evm(2, 0, "2"),
            fuel(2, "fuel 2"),
            evm(4, 0, "4"),
        ]);
        store.merge(&EventStore::from_rows(vec![evm(3, 1, "3")]));
        let chunks = store.rows().chunks.len();
        assert_eq!(
            (chunks, describe(store.take(u32::MAX).unwrap())),
            (
                2,
                vec![
                    "evm 1 r0 1 Str(\"1 list\")".to_string(),
                    "fuel 1 fuel 1 Str(\"fuel 1\")".to_string(),
                    "evm 2 r0 2 Str(\"2 list\")".to_string(),
                    "fuel 2 fuel 2 Str(\"fuel 2\")".to_string(),
                    "evm 3 r1 3 Str(\"3 list\")".to_string(),
                    "evm 4 r0 4 Str(\"4 list\")".to_string(),
                ]
            )
        );
    }

    fn svm_at(slot: i64, path: &[i64], program: &str) -> Row {
        Row::event(
            slot,
            5,
            Some(path.to_vec()),
            2,
            RowData::SvmInstruction {
                program_id: program.into(),
                accounts: vec![format!("{program} account")],
                data: vec![1],
                is_inner: false,
                args: Some(tagged(&format!("{program} args"))),
                logs: None,
            },
        )
    }

    #[test]
    fn a_truncated_chunk_s_lists_take_rows_appended_after_a_rollback() {
        let store = EventStore::from_rows(vec![
            svm_at(1, &[0], "a"),
            svm_at(2, &[0, 1], "b"),
            svm_at(3, &[0], "c"),
            svm_at(5, &[0], "e"),
        ]);
        store.merge(&EventStore::from_rows(vec![svm_at(4, &[0], "d")]));
        store.rollback(3);
        store.merge(&EventStore::from_rows(vec![svm_at(6, &[2, 3], "f")]));
        assert_eq!(
            describe(store.take(u32::MAX).unwrap()),
            vec![
                "svm 1 [0.0] a Str(\"a args\")".to_string(),
                "svm 2 [0.0, 1.0] b Str(\"b args\")".to_string(),
                "svm 3 [0.0] c Str(\"c args\")".to_string(),
                "svm 6 [2.0, 3.0] f Str(\"f args\")".to_string(),
            ]
        );
    }

    #[test]
    fn a_truncated_chunk_hands_over_only_its_kept_rows_tapes() {
        let store = EventStore::from_rows(vec![
            svm_at(1, &[0], "a"),
            svm_at(2, &[0], "b"),
            svm_at(3, &[0], "c"),
            svm_at(5, &[0], "e"),
        ]);
        store.merge(&EventStore::from_rows(vec![svm_at(4, &[0], "d")]));
        store.rollback(3);
        let rows = store.take(u32::MAX).unwrap();
        let tapes = rows.tapes.len();
        describe(rows);
        assert_eq!(tapes, 3);
    }

    #[test]
    fn merges_and_partial_takes_carry_each_format_s_details_and_tapes() {
        let svm_row = |block_number: i64, path: &[i64], program: &str| {
            Row::event(
                block_number,
                5,
                Some(path.to_vec()),
                2,
                RowData::SvmInstruction {
                    program_id: program.into(),
                    accounts: vec!["acc".into()],
                    data: vec![1],
                    is_inner: false,
                    args: Some(tagged(&format!("{program} args"))),
                    logs: None,
                },
            )
        };
        let store = EventStore::from_rows(vec![
            evm(1, 0, "1"),
            evm(3, 1, "3"),
            Row::event(
                3,
                1,
                None,
                3,
                RowData::FuelReceipt {
                    tx_id: "tx".into(),
                    src_address: "0xfuel".into(),
                    params: tagged("fuel params"),
                },
            ),
            svm_row(3, &[0, 1], "child"),
            svm_row(3, &[0], "parent"),
        ]);
        store.merge(&EventStore::from_rows(vec![
            evm(2, 1, "2"),
            evm(2, 0, "2"),
            evm(3, 1, "3 refetched"),
        ]));
        let first = describe(store.take(2).unwrap());
        let rest = describe(store.take(u32::MAX).unwrap());
        assert_eq!(
            (first, rest),
            (
                vec![
                    "evm 1 r0 1 Str(\"1 list\")".to_string(),
                    "evm 2 r0 2 Str(\"2 list\")".to_string(),
                ],
                vec![
                    "evm 2 r1 2 Str(\"2 list\")".to_string(),
                    "evm 3 r1 3 Str(\"3 list\")".to_string(),
                    "fuel 3 tx Str(\"fuel params\")".to_string(),
                    "svm 3 [0.0] parent Str(\"parent args\")".to_string(),
                    "svm 3 [0.0, 1.0] child Str(\"child args\")".to_string(),
                ]
            )
        );
    }

    fn no_fields() -> JoinedFields {
        JoinedFields {
            transaction_masks: Vec::new(),
            event_block_masks: Vec::new(),
            block_handler_masks: Vec::new(),
        }
    }

    fn evm_at(block_number: i64, log_index: i64, transaction: i64, registration: i64) -> Row {
        let mut row = evm(
            block_number,
            registration,
            &format!("{block_number}-{log_index}"),
        );
        row.log_index = log_index;
        if let RowData::EvmLog {
            transaction_index, ..
        } = &mut row.data
        {
            *transaction_index = transaction;
        }
        row
    }

    /// Each item's link into the batch's transactions and blocks, `None` where
    /// it reads neither, and the transaction and block keys the stores are to
    /// read. Frees the result.
    type Links = Vec<(Option<f64>, Option<f64>)>;

    #[allow(clippy::type_complexity)]
    fn links_of(rows: StoredRows) -> (Links, Option<Vec<(i64, u32)>>, Option<Vec<i64>>) {
        let mut lent = RESULTS.lock().unwrap().remove(rows.handle).unwrap();
        let links = lent.arenas.remove(3 + rows.params.len());
        let cell = |column: usize, row: usize| {
            let column = &links.columns()[column];
            (!column.is_null(row)).then(|| column.f64_at(row))
        };
        (
            (0..links.rows())
                .map(|row| {
                    (
                        cell(link_column::TRANSACTION, row),
                        cell(link_column::BLOCK, row),
                    )
                })
                .collect(),
            rows.transaction_keys.map(|keys| {
                keys.block_numbers
                    .iter()
                    .zip(keys.transaction_indexes.iter())
                    .map(|(block, index)| (*block as i64, *index))
                    .collect()
            }),
            rows.block_keys.map(|keys| {
                keys.block_numbers
                    .iter()
                    .map(|block| *block as i64)
                    .collect()
            }),
        )
    }

    #[test]
    fn a_joined_take_links_each_item_to_its_transaction_and_block_rows() {
        use crate::block_store::EvmBlockField;
        use crate::transaction_store::EvmTxField;
        let rows = || {
            EventStore::from_rows(vec![
                evm_at(1, 0, 0, 0),
                evm_at(1, 1, 0, 1),
                evm_at(1, 2, 1, 0),
                evm_at(2, 0, 0, 0),
                Row::block(2, 0, false),
                Row::block(2, 1, true),
            ])
        };
        let fields = |transaction_mask: u64| JoinedFields {
            transaction_masks: vec![transaction_mask as f64, 0.0],
            event_block_masks: vec![(1u64 << EvmBlockField::Number as u32) as f64, 0.0],
            block_handler_masks: vec![Some((1u64 << EvmBlockField::Number as u32) as f64), None],
        };
        let selected = links_of(
            rows()
                .take_joined(u32::MAX, fields(1 << EvmTxField::TransactionIndex as u32))
                .unwrap(),
        );
        let none_selected = links_of(rows().take_joined(u32::MAX, fields(0)).unwrap());
        assert_eq!(
            (
                selected,
                none_selected.0.iter().map(|(t, _)| *t).collect::<Vec<_>>(),
                none_selected.1
            ),
            (
                (
                    vec![
                        (Some(0.0), Some(0.0)),
                        (Some(0.0), Some(0.0)),
                        (Some(1.0), Some(0.0)),
                        (Some(2.0), Some(1.0)),
                        (None, Some(1.0)),
                        (None, None),
                    ],
                    Some(vec![(1, 0), (1, 1), (2, 0)]),
                    Some(vec![1, 2])
                ),
                vec![
                    Some(EMPTY_LINK),
                    Some(EMPTY_LINK),
                    Some(EMPTY_LINK),
                    Some(EMPTY_LINK),
                    None,
                    None
                ],
                None
            )
        );
    }

    #[test]
    fn a_joined_take_reads_no_block_when_none_of_its_fields_is_selected() {
        let store = EventStore::from_rows(vec![evm_at(1, 0, 0, 0), Row::block(1, 0, false)]);
        let fields = JoinedFields {
            transaction_masks: vec![0.0],
            event_block_masks: vec![0.0],
            block_handler_masks: vec![Some(0.0)],
        };
        assert_eq!(
            links_of(store.take_joined(u32::MAX, fields).unwrap()),
            (
                vec![
                    (Some(EMPTY_LINK), Some(EMPTY_LINK)),
                    (None, Some(EMPTY_LINK))
                ],
                None,
                None
            )
        );
    }

    #[test]
    fn a_released_handle_finds_nothing_once_its_slot_holds_another_result() {
        let lent = || Lent {
            arenas: Vec::new(),
            buffer_counts: Vec::new(),
        };
        let mut results = Results::default();
        let first = results.insert(lent()).unwrap();
        results.remove(first);
        let second = results.insert(lent()).unwrap();
        assert_eq!(
            (
                first & ((1 << SLOT_BITS) - 1) == second & ((1 << SLOT_BITS) - 1),
                first != second,
                results.remove(first).is_some(),
                results.get_mut(second).is_some(),
            ),
            (true, true, false, true)
        );
    }

    #[test]
    fn merge_keeps_the_stored_row_of_a_duplicate_and_empties_the_page() {
        let store = EventStore::from_rows(vec![event(1, 0, 0, "stored"), event(3, 0, 0, "b3")]);
        let page = EventStore::from_rows(vec![event(1, 0, 0, "refetched"), event(2, 0, 0, "b2")]);
        store.merge(&page);
        assert_eq!(
            (page.len(), take_all(&store)),
            (
                0,
                vec![
                    JsValue::str("stored"),
                    JsValue::str("b2"),
                    JsValue::str("b3")
                ]
            )
        );
    }

    #[test]
    fn merging_a_page_past_the_stored_rows_still_drops_duplicates() {
        let store = EventStore::from_rows(vec![event(1, 0, 0, "b1")]);
        // Starts on the stored row itself, then repeats a row of its own.
        store.merge(&EventStore::from_rows(vec![
            event(1, 0, 0, "b1 refetched"),
            event(2, 0, 0, "b2"),
        ]));
        store.insert(vec![event(3, 0, 0, "b3"), event(3, 0, 0, "b3 again")]);
        assert_eq!(
            take_all(&store),
            vec![JsValue::str("b1"), JsValue::str("b2"), JsValue::str("b3")]
        );
    }

    /// Rows in blocks `blocks`, one per block, each its own big-enough page so
    /// it stays a chunk of its own.
    fn chunked(pages: &[std::ops::Range<i64>]) -> EventStore {
        let store = EventStore::empty();
        for page in pages {
            let rows = page
                .clone()
                .flat_map(|block| {
                    (0..COALESCE_BELOW as i64)
                        .map(move |log| event(block, log, 0, &format!("{block}-{log}")))
                })
                .collect();
            store.merge(&EventStore::from_rows(rows));
        }
        store
    }

    /// Each stored row's block, in order, runs of one block collapsed into one
    /// entry per kind.
    fn blocks_of_rows(store: &EventStore) -> Vec<i64> {
        let mut blocks: Vec<(i64, bool)> = store
            .rows()
            .keys()
            .map(|key| ((key >> 64) as i64, key & KIND_BIT != 0))
            .collect();
        blocks.dedup();
        blocks.into_iter().map(|(block, _)| block).collect()
    }

    fn blocks_of(rows: Vec<JsValue>) -> Vec<i64> {
        let mut blocks: Vec<i64> = rows
            .iter()
            .map(|row| match row {
                JsValue::Str(tag) => tag.split('-').next().unwrap().parse().unwrap(),
                other => panic!("not a tagged row: {other:?}"),
            })
            .collect();
        blocks.dedup();
        blocks
    }

    #[test]
    fn appending_pages_keeps_each_whole_and_a_gap_fill_merges_only_what_it_overlaps() {
        let store = chunked(&[1..3, 5..7, 9..11]);
        let chunks_before = store.rows().chunks.len();
        // Fills block 3 and 4 and repeats a row of block 5, which stays.
        store.merge(&EventStore::from_rows(vec![
            event(3, 0, 0, "3-0"),
            event(4, 0, 0, "4-0"),
            event(5, 0, 0, "5-0 refetched"),
        ]));
        let chunks_after = store.rows().chunks.len();
        let len = store.len();
        let at = (
            store.block_number_at(2 * COALESCE_BELOW as u32),
            store.count_at_or_below(4),
        );
        assert_eq!(
            (
                chunks_before,
                chunks_after,
                len,
                at,
                blocks_of(take_all(&store))
            ),
            (
                3,
                // The page's rows, with the refetched row of block 5, and the
                // rest of the chunk of blocks 5 and 6, left where it was.
                4,
                6 * COALESCE_BELOW as u32 + 2,
                (Some(3), 2 * COALESCE_BELOW as u32 + 2),
                vec![1, 2, 3, 4, 5, 6, 9, 10]
            )
        );
    }

    #[test]
    fn take_and_rollback_cut_through_chunks() {
        let store = chunked(&[1..3, 3..5, 5..7]);
        let taken = blocks_of(read(store.take(COALESCE_BELOW as u32 + 1).unwrap()));
        store.rollback(4);
        let chunks = store.rows().chunks.len();
        assert_eq!(
            (taken, store.len(), chunks, blocks_of(take_all(&store))),
            (vec![1, 2], 3 * COALESCE_BELOW as u32 - 1, 2, vec![2, 3, 4])
        );
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_page_merged_into_a_chunk_s_front_leaves_the_rest_of_it_in_place() {
        let store = chunked(&[1..3]);
        store.merge(&EventStore::from_rows(vec![Row::block(1, 0, false)]));
        let chunks: Vec<(usize, usize)> = store
            .rows()
            .chunks
            .iter()
            .map(|chunk| (chunk.start, chunk.len()))
            .collect();
        assert_eq!(
            (chunks, blocks_of_rows(&store)),
            (
                vec![(0, COALESCE_BELOW + 1), (COALESCE_BELOW, COALESCE_BELOW)],
                vec![1, 1, 2]
            )
        );
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_page_inside_a_chunk_copies_only_its_smaller_side() {
        let store = chunked(&[1..3]);
        store.merge(&EventStore::from_rows(vec![event(2, 5, 1, "2-5 again")]));
        let chunks: Vec<(usize, usize)> = store
            .rows()
            .chunks
            .iter()
            .map(|chunk| (chunk.start, chunk.len()))
            .collect();
        assert_eq!(
            chunks,
            vec![(0, COALESCE_BELOW + 6), (0, COALESCE_BELOW - 6 + 1)]
        );
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_small_page_after_a_big_chunk_starts_its_own() {
        let store = chunked(&[1..3]);
        store.merge(&EventStore::from_rows(vec![event(9, 0, 0, "9-0")]));
        let chunks = store.rows().chunks.len();
        assert_eq!(chunks, 2);
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn a_long_page_after_a_short_chunk_starts_its_own() {
        let store = EventStore::from_rows(vec![event(1, 0, 0, "1-0")]);
        store.merge(&chunked(&[2..3]));
        let chunks = store.rows().chunks.len();
        assert_eq!(chunks, 2);
    }

    #[test]
    fn an_empty_svm_path_orders_the_same_within_a_page_and_across_pages() {
        let within = EventStore::from_rows(vec![svm(7, 3, &[], "empty"), svm(7, 3, &[0], "child")]);
        let across = EventStore::from_rows(vec![svm(7, 3, &[], "empty")]);
        across.merge(&EventStore::from_rows(vec![svm(7, 3, &[0], "child")]));
        let expected = vec![JsValue::str("empty"), JsValue::str("child")];
        assert_eq!(
            (take_all(&within), take_all(&across)),
            (expected.clone(), expected)
        );
    }

    #[test]
    fn the_result_registry_refuses_more_results_than_its_handles_address() {
        let lent = || Lent {
            arenas: Vec::new(),
            buffer_counts: Vec::new(),
        };
        let mut results = Results::default();
        for _ in 0..(1 << SLOT_BITS) {
            results.insert(lent()).unwrap();
        }
        assert!(results.insert(lent()).is_err());
    }

    #[test]
    fn a_page_between_two_chunks_lands_between_them() {
        let store = chunked(&[1..3, 5..7]);
        store.merge(&EventStore::from_rows(vec![event(4, 0, 0, "4-0")]));
        let chunks = store.rows().chunks.len();
        assert_eq!(
            (chunks, blocks_of(take_all(&store))),
            (3, vec![1, 2, 4, 5, 6])
        );
    }

    #[test]
    #[allow(clippy::single_range_in_vec_init)]
    fn appending_to_a_mostly_taken_chunk_drops_its_taken_rows() {
        let store = chunked(&[1..3]);
        store.take(COALESCE_BELOW as u32 + 1).unwrap();
        store.merge(&EventStore::from_rows(vec![event(9, 0, 0, "9-0")]));
        let rows = store.rows();
        let chunk = (rows.chunks[0].start, rows.chunks[0].keys.len());
        assert_eq!(chunk, (0, COALESCE_BELOW));
    }

    #[test]
    fn a_js_item_at_a_negative_block_is_refused() {
        let item = |block_number| JsItemInput {
            kind: 0,
            block_number,
            log_index: 0,
            order_path: None,
            registration_index: 0,
            item: JsTape::new(),
            transaction_index: None,
            block_from_store: false,
        };
        assert_eq!(
            (
                EventStore::from_js_items(vec![item(1)]).is_ok(),
                EventStore::from_js_items(vec![item(-1)]).is_ok()
            ),
            (true, false)
        );
    }

    #[test]
    fn small_pages_join_the_last_chunk() {
        let store = EventStore::empty();
        for block in 1..=5 {
            store.merge(&EventStore::from_rows(vec![event(block, 0, 0, "small")]));
        }
        store.insert_block_items(vec![6, 7], vec![0, 0]);
        let chunks = store.rows().chunks.len();
        assert_eq!((chunks, store.len()), (1, 7));
    }

    #[test]
    fn ready_count_stops_at_the_frontier_and_finishes_the_target_block() {
        let store = EventStore::from_rows(vec![
            event(1, 0, 0, "a"),
            event(2, 0, 0, "b"),
            event(2, 1, 0, "c"),
            event(3, 0, 0, "d"),
            event(5, 0, 0, "e"),
        ]);
        assert_eq!(
            (
                store.ready_count(4, 100),
                store.ready_count(4, 2),
                store.ready_count(4, 1),
                store.count_at_or_below(2),
            ),
            (4, 3, 1, 3)
        );
    }

    #[test]
    fn take_rollback_and_lookups_read_the_sorted_rows() {
        let store = EventStore::from_rows(vec![
            Row::block(1, 0, false),
            event(2, 0, 4, "cr"),
            event(3, 0, 0, "plain"),
            event(4, 0, 4, "dropped by rollback"),
        ]);
        store.rollback(3);
        let contract_registers = read(store.events_of_registrations(vec![4], no_fields()).unwrap());
        let first_event = store.first_event_block_number();
        let second = store.block_number_at(1);
        let taken = read(store.take(1).unwrap());
        assert_eq!(
            (
                contract_registers,
                first_event,
                second,
                taken,
                take_all(&store)
            ),
            (
                vec![JsValue::str("cr")],
                Some(2),
                Some(2),
                vec![JsValue::str("block 1 r0")],
                vec![JsValue::str("cr"), JsValue::str("plain")]
            )
        );
    }
}
