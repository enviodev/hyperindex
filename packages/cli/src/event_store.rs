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
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU32, Ordering as AtomicOrdering};
use std::sync::{LazyLock, Mutex};

use anyhow::Result;
use napi::bindgen_prelude::ArrayBuffer;
use napi::Env;
use napi_derive::napi;

use crate::columnar::{js as columnar_js, Arena, ColumnSpec};
use crate::evm_hypersync_source::types::{EvmParams, ParamCell, ParamSchema};
use crate::js_value::JsTape;
use crate::storage::rows::{ColumnRead, ReadKind};

/// Which JS conversion a row goes through, chosen by what produced it.
#[napi]
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
    JsItem(JsTape),
}

impl RowData {
    fn format(&self) -> RowFormat {
        match self {
            RowData::EvmLog { .. } => RowFormat::EvmLog,
            RowData::FuelReceipt { .. } => RowFormat::FuelReceipt,
            RowData::SvmInstruction { .. } => RowFormat::SvmInstruction,
            RowData::Block { .. } => RowFormat::Block,
            RowData::JsItem(_) => RowFormat::JsItem,
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

    pub(crate) fn evm_log(
        block_number: i64,
        log_index: i64,
        transaction_index: i64,
        src_address: String,
        registration_index: i64,
        params: EvmParams,
    ) -> Self {
        Row {
            block_number,
            kind: ItemKind::Event,
            log_index,
            order_path: None,
            registration_index,
            data: RowData::EvmLog {
                src_address,
                transaction_index,
                params,
            },
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
            .then_with(|| match (&self.order_path, &other.order_path) {
                // Lexicographic, so a parent instruction `[1]` precedes its
                // child `[1, 0]`.
                (Some(a), Some(b)) => a.cmp(b),
                _ => Ordering::Equal,
            })
            .then(self.registration_index.cmp(&other.registration_index))
    }
}

/// A chunk this short takes the next appended rows into itself rather than
/// staying beside them, so generated block items and small pages don't pile
/// up chunks that the positional queries would walk.
const COALESCE_BELOW: usize = 1024;

/// Rows in processing order, deduplicated, as sorted chunks that don't
/// overlap. A page whose rows all come after the stored ones, which is what a
/// response at the fetch frontier brings, is kept whole as one more chunk, so
/// merging it moves no row. A page that fills a gap merges only into the
/// chunks it overlaps.
#[derive(Default)]
pub(crate) struct Rows {
    // A chunk is itself a deque, so a batch taking the front of one moves only
    // the rows it takes.
    chunks: VecDeque<VecDeque<Row>>,
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
        sorted.append(rows);
        sorted
    }

    fn len(&self) -> usize {
        self.len
    }

    fn iter(&self) -> impl Iterator<Item = &Row> {
        self.chunks.iter().flatten()
    }

    fn get(&self, mut index: usize) -> Option<&Row> {
        for chunk in &self.chunks {
            if index < chunk.len() {
                return chunk.get(index);
            }
            index -= chunk.len();
        }
        None
    }

    fn count_at_or_below(&self, block_number: i64) -> usize {
        let mut count = 0;
        for chunk in &self.chunks {
            match chunk.back() {
                Some(last) if last.block_number <= block_number => count += chunk.len(),
                _ => return count + chunk.partition_point(|row| row.block_number <= block_number),
            }
        }
        count
    }

    /// Adds sorted rows that all come after the stored ones.
    fn append(&mut self, rows: Vec<Row>) {
        let rows = VecDeque::from(rows);
        if rows.is_empty() {
            return;
        }
        self.len += rows.len();
        match self.chunks.back_mut() {
            Some(last) if last.len() < COALESCE_BELOW || rows.len() < COALESCE_BELOW => {
                last.extend(rows)
            }
            _ => self.chunks.push_back(rows),
        }
    }

    /// Merges `other`'s rows in. On a tie the row already stored is kept.
    fn merge(&mut self, other: Rows) {
        let incoming: Vec<Row> = match other.chunks.len() {
            0 => return,
            1 => other.chunks.into_iter().next().unwrap().into(),
            _ => other.chunks.into_iter().flatten().collect(),
        };
        let first = &incoming[0];
        let last = &incoming[incoming.len() - 1];
        // The chunks the page overlaps: from the first whose last row isn't
        // before the page's first, to the last whose first row isn't after the
        // page's last.
        let Some(start) = self.chunks.iter().position(|chunk| {
            chunk
                .back()
                .is_some_and(|stored| stored.compare(first) != Ordering::Less)
        }) else {
            return self.append(incoming);
        };
        let end = start
            + self
                .chunks
                .iter()
                .skip(start)
                .take_while(|chunk| {
                    chunk
                        .front()
                        .is_some_and(|stored| stored.compare(last) != Ordering::Greater)
                })
                .count();
        let overlapped: Vec<VecDeque<Row>> = self.chunks.drain(start..end).collect();
        let stored_len: usize = overlapped.iter().map(VecDeque::len).sum();
        let merged = merge_sorted(overlapped.into_iter().flatten(), incoming);
        self.len = self.len - stored_len + merged.len();
        self.chunks.insert(start, merged.into());
    }

    /// Removes and returns the first `count` rows.
    fn take(&mut self, count: usize) -> Vec<Row> {
        let mut taken = Vec::with_capacity(count.min(self.len));
        while taken.len() < count {
            let Some(chunk) = self.chunks.front_mut() else {
                break;
            };
            let wanted = count - taken.len();
            if chunk.len() > wanted {
                taken.extend(chunk.drain(..wanted));
            } else {
                taken.extend(self.chunks.pop_front().unwrap());
            }
        }
        self.len -= taken.len();
        taken
    }

    /// Drops every row above `block_number`.
    fn rollback(&mut self, block_number: i64) {
        while let Some(chunk) = self.chunks.back_mut() {
            let kept = chunk.partition_point(|row| row.block_number <= block_number);
            self.len -= chunk.len() - kept;
            if kept == 0 {
                self.chunks.pop_back();
            } else {
                chunk.truncate(kept);
                break;
            }
        }
    }
}

/// Merges two sorted, deduplicated runs. On a tie the row of `stored` is kept.
fn merge_sorted(stored: impl Iterator<Item = Row>, incoming: Vec<Row>) -> Vec<Row> {
    let mut merged: Vec<Row> = Vec::with_capacity(incoming.len());
    let mut push = |row: Row| {
        if merged
            .last()
            .is_none_or(|last| last.compare(&row) != Ordering::Equal)
        {
            merged.push(row);
        }
    };
    let mut stored = stored.peekable();
    let mut incoming = incoming.into_iter().peekable();
    loop {
        match (stored.peek(), incoming.peek()) {
            (Some(a), Some(b)) => {
                if a.compare(b) != Ordering::Greater {
                    push(stored.next().unwrap());
                } else {
                    push(incoming.next().unwrap());
                }
            }
            (Some(_), None) => push(stored.next().unwrap()),
            (None, Some(_)) => push(incoming.next().unwrap()),
            (None, None) => break,
        }
    }
    merged
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
    fn of(columns: &[ColumnRead], rows: usize) -> Self {
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
/// `fuel` and `svm`, the whole item record of each such row. `tapes` carries
/// what has no column shape. `EventStore.lendRows` lends the arenas' buffers
/// in that order, and `EventStore.releaseRows` takes them back.
#[napi(object, object_from_js = false)]
pub struct StoredRows {
    pub handle: u32,
    pub items: ArenaShape,
    pub params: Vec<ParamsShape>,
    pub fuel: ArenaShape,
    pub svm: ArenaShape,
    pub tapes: Vec<JsTape>,
}

/// The arenas of the results JavaScript has yet to read, by handle.
struct Lent {
    arenas: Vec<Arena>,
    /// How many buffers each arena lent, so each takes back its own.
    buffer_counts: Vec<usize>,
}

static RESULTS: LazyLock<Mutex<HashMap<u32, Lent>>> = LazyLock::new(Default::default);
static NEXT_HANDLE: AtomicU32 = AtomicU32::new(1);

const ITEM_COLUMNS: [(&str, ReadKind); 9] = [
    ("format", ReadKind::Float),
    ("blockNumber", ReadKind::Float),
    ("logIndex", ReadKind::Float),
    ("transactionIndex", ReadKind::Float),
    ("registrationIndex", ReadKind::Float),
    ("srcAddress", ReadKind::Text),
    ("skipped", ReadKind::Bool),
    // The row's place in its format's own arena: an EVM log's in its
    // registration's params, a Fuel receipt's or SVM instruction's in theirs.
    ("detailRow", ReadKind::Float),
    // A JS-built row's item.
    ("tape", ReadKind::Float),
];

/// Positions in `ITEM_COLUMNS`.
mod item_column {
    pub(super) const FORMAT: usize = 0;
    pub(super) const BLOCK_NUMBER: usize = 1;
    pub(super) const LOG_INDEX: usize = 2;
    pub(super) const TRANSACTION_INDEX: usize = 3;
    pub(super) const REGISTRATION_INDEX: usize = 4;
    pub(super) const SRC_ADDRESS: usize = 5;
    pub(super) const SKIPPED: usize = 6;
    pub(super) const DETAIL_ROW: usize = 7;
    pub(super) const TAPE: usize = 8;
}

/// Named as `FuelHyperSyncClient.EventItems.item`'s fields, so a row reads as
/// that record.
fn fuel_columns() -> Vec<ColumnRead> {
    vec![
        ColumnRead::scalar("onEventRegistrationIndex", ReadKind::Float),
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
        ColumnRead::scalar("onEventRegistrationIndex", ReadKind::Float),
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

/// One arena written straight from the stored rows: each column once per row,
/// rows in order, which is how a variable-width or list column finds where its
/// row starts.
struct ArenaWriter {
    columns: Vec<ColumnRead>,
    arena: Arena,
    row: usize,
    /// List elements written so far, per column.
    elements: Vec<usize>,
}

impl ArenaWriter {
    /// `elements` gives a list column's element count across all rows, which
    /// its element column is sized to once.
    fn new(columns: Vec<ColumnRead>, rows: usize, elements: &[usize]) -> Self {
        let specs: Vec<ColumnSpec> = columns
            .iter()
            .enumerate()
            .map(|(index, column)| match column.element {
                Some(element) => ColumnSpec::List {
                    element: element.slot(),
                    elements: elements[index],
                },
                None => ColumnSpec::Scalar(column.kind.slot()),
            })
            .collect();
        ArenaWriter {
            arena: Arena::new_filled(rows, &specs),
            elements: vec![0; columns.len()],
            columns,
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

    /// A tape's position among the result's tapes.
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

    fn finish(mut self) -> Result<(ArenaShape, Arena)> {
        let shape = ArenaShape::of(&self.columns, self.row);
        self.arena.seal(&shape.names)?;
        Ok((shape, self.arena))
    }
}

/// Lays rows out as the arenas `StoredRows` describes, and keeps them until
/// JavaScript has read them.
fn lay_out_rows<'a>(rows: impl IntoIterator<Item = &'a Row>) -> Result<StoredRows> {
    let rows: Vec<&Row> = rows.into_iter().collect();

    // Every arena is sized before it is written, so one pass counts each
    // format's rows and the SVM lists' elements first.
    let (mut fuel_rows, mut svm_rows, mut svm_steps, mut svm_accounts) = (0, 0, 0, 0);
    // By registration index: the schema of its EVM logs' params, and how many.
    let mut params_of: Vec<Option<(&ParamSchema, usize)>> = Vec::new();
    for row in &rows {
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
            RowData::Block { .. } | RowData::JsItem(_) => {}
        }
    }

    let mut tapes = Vec::new();
    let mut items = ArenaWriter::new(
        ITEM_COLUMNS
            .iter()
            .map(|(name, kind)| ColumnRead::scalar(*name, *kind))
            .collect(),
        rows.len(),
        &[],
    );
    let mut params: Vec<Option<ArenaWriter>> = params_of
        .iter()
        .map(|group| {
            group.map(|(schema, logs)| {
                let columns = schema
                    .params
                    .iter()
                    .zip(&schema.kinds)
                    .map(|(param, kind)| ColumnRead::scalar(param.name.clone(), *kind))
                    .collect();
                ArenaWriter::new(columns, logs, &[])
            })
        })
        .collect();
    let mut fuel = ArenaWriter::new(fuel_columns(), fuel_rows, &[]);
    let mut svm = ArenaWriter::new(
        svm_columns(),
        svm_rows,
        &[0, 0, 0, svm_steps, 0, svm_accounts, 0, 0, 0, 0],
    );

    for row in &rows {
        let registration = row.registration_index as f64;
        items.num(item_column::FORMAT, row.data.format() as u8 as f64);
        items.num(item_column::BLOCK_NUMBER, row.block_number as f64);
        items.num(item_column::LOG_INDEX, row.log_index as f64);
        items.num(item_column::REGISTRATION_INDEX, registration);
        let unset: &[usize] = match &row.data {
            RowData::EvmLog {
                src_address,
                transaction_index,
                params: log_params,
            } => {
                let group = params[row.registration_index as usize]
                    .as_mut()
                    .expect("counted in the first pass");
                for (column, cell) in log_params.cells.iter().enumerate() {
                    match cell {
                        ParamCell::Bool(value) => group.bool(column, *value),
                        ParamCell::Text(value) | ParamCell::BigInt(value) => {
                            group.bytes(column, value.as_bytes())
                        }
                        ParamCell::Tape(tape) => group.tape(column, &mut tapes, tape),
                    }
                }
                items.num(item_column::TRANSACTION_INDEX, *transaction_index as f64);
                items.bytes(item_column::SRC_ADDRESS, src_address.as_bytes());
                items.num(item_column::DETAIL_ROW, group.row as f64);
                group.end_row();
                &[item_column::SKIPPED, item_column::TAPE]
            }
            RowData::FuelReceipt {
                tx_id,
                src_address,
                params,
            } => {
                fuel.num(0, registration);
                fuel.num(1, row.log_index as f64);
                fuel.bytes(2, tx_id.as_bytes());
                fuel.num(3, row.block_number as f64);
                fuel.bytes(4, src_address.as_bytes());
                fuel.tape(5, &mut tapes, params);
                items.num(item_column::DETAIL_ROW, fuel.row as f64);
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
                svm.num(0, registration);
                svm.num(1, row.block_number as f64);
                svm.num(2, row.log_index as f64);
                svm.num_list(3, row.order_path.as_deref().unwrap_or_default());
                svm.bytes(4, program_id.as_bytes());
                svm.text_list(5, accounts);
                svm.bytes(6, data);
                svm.bool(7, *is_inner);
                svm.optional_tape(8, &mut tapes, args);
                svm.optional_tape(9, &mut tapes, logs);
                items.num(item_column::DETAIL_ROW, svm.row as f64);
                svm.end_row();
                &[
                    item_column::TRANSACTION_INDEX,
                    item_column::SRC_ADDRESS,
                    item_column::SKIPPED,
                    item_column::TAPE,
                ]
            }
            RowData::Block { skipped } => {
                items.bool(item_column::SKIPPED, *skipped);
                &[
                    item_column::TRANSACTION_INDEX,
                    item_column::SRC_ADDRESS,
                    item_column::DETAIL_ROW,
                    item_column::TAPE,
                ]
            }
            RowData::JsItem(item) => {
                items.tape(item_column::TAPE, &mut tapes, item);
                &[
                    item_column::TRANSACTION_INDEX,
                    item_column::SRC_ADDRESS,
                    item_column::SKIPPED,
                    item_column::DETAIL_ROW,
                ]
            }
        };
        for column in unset {
            items.null(*column);
        }
        items.end_row();
    }

    let (items, items_arena) = items.finish()?;
    let mut arenas = vec![items_arena];
    let mut params_shapes = Vec::new();
    for (registration_index, group) in params.into_iter().enumerate() {
        if let Some(group) = group {
            let (shape, arena) = group.finish()?;
            params_shapes.push(ParamsShape {
                registration_index: registration_index as i64,
                shape,
            });
            arenas.push(arena);
        }
    }
    let (fuel, fuel_arena) = fuel.finish()?;
    arenas.push(fuel_arena);
    let (svm, svm_arena) = svm.finish()?;
    arenas.push(svm_arena);

    let handle = NEXT_HANDLE.fetch_add(1, AtomicOrdering::Relaxed);
    RESULTS.lock().unwrap().insert(
        handle,
        Lent {
            arenas,
            buffer_counts: Vec::new(),
        },
    );
    Ok(StoredRows {
        handle,
        items,
        params: params_shapes,
        fuel,
        svm,
        tapes,
    })
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
                Ok(Row {
                    block_number: item.block_number,
                    kind,
                    log_index: item.log_index,
                    order_path: item.order_path,
                    registration_index: item.registration_index,
                    data: RowData::JsItem(item.item),
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
        self.rows().get(index as usize).map(|row| row.block_number)
    }

    #[napi]
    pub fn first_event_block_number(&self) -> Option<i64> {
        self.rows()
            .iter()
            .find(|row| row.kind == ItemKind::Event)
            .map(|row| row.block_number)
    }

    /// How many rows are at or below `block_number`.
    #[napi]
    pub fn count_at_or_below(&self, block_number: i64) -> u32 {
        self.rows().count_at_or_below(block_number) as u32
    }

    /// How many rows from `from_index` on a batch takes: those at or below
    /// `frontier`, up to `target_size`, and then the rest of the last block, so
    /// a batch never splits a block.
    #[napi]
    pub fn ready_count(&self, frontier: i64, target_size: u32, from_index: u32) -> u32 {
        let rows = self.rows();
        let mut ready_block_number = frontier;
        let mut count = 0u32;
        for row in rows.iter().skip(from_index as usize) {
            if row.block_number > ready_block_number {
                break;
            }
            count += 1;
            if count == target_size {
                ready_block_number = row.block_number;
            }
        }
        count
    }

    /// Removes the first `count` rows and lays them out for JS.
    #[napi]
    pub fn take(&self, count: u32) -> napi::Result<StoredRows> {
        let taken = self.rows().take(count as usize);
        lay_out_rows(&taken).map_err(to_napi)
    }

    /// The event rows routed to any of `registration_indexes`, in order, laid
    /// out for JS. The rows stay.
    #[napi]
    pub fn events_of_registrations(
        &self,
        registration_indexes: Vec<i64>,
    ) -> napi::Result<StoredRows> {
        let rows = self.rows();
        lay_out_rows(rows.iter().filter(|row| {
            row.kind == ItemKind::Event && registration_indexes.contains(&row.registration_index)
        }))
        .map_err(to_napi)
    }

    /// Every row, in order, laid out for JS. The rows stay.
    #[napi]
    pub fn all_items(&self) -> napi::Result<StoredRows> {
        lay_out_rows(self.rows().iter()).map_err(to_napi)
    }

    /// Drops every row above `target_block_number`.
    #[napi]
    pub fn rollback(&self, target_block_number: i64) {
        self.rows().rollback(target_block_number);
    }

    /// Every buffer of a laid-out result's arenas, in order: the items, then
    /// each registration's params.
    #[napi]
    pub fn lend_rows<'env>(env: &'env Env, handle: u32) -> napi::Result<Vec<ArrayBuffer<'env>>> {
        let mut results = RESULTS.lock().unwrap();
        let lent = results
            .get_mut(&handle)
            .ok_or_else(|| napi::Error::from_reason(format!("Unknown rows {handle}")))?;
        let mut buffers = Vec::new();
        for arena in lent.arenas.iter_mut() {
            let lent_buffers = columnar_js::lend_for_reading(env, arena)?;
            lent.buffer_counts.push(lent_buffers.len());
            buffers.extend(lent_buffers);
        }
        Ok(buffers)
    }

    /// Takes a result's buffers back and frees it. A result that cannot hand
    /// them all back still has a JavaScript view into its memory, so that
    /// memory is abandoned rather than freed.
    #[napi]
    pub fn release_rows(handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
        let mut results = RESULTS.lock().unwrap();
        let Some(mut lent) = results.remove(&handle) else {
            return Ok(());
        };
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
            RowData::JsItem(data),
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
            RowData::JsItem(data),
        )
    }

    /// What each laid-out row reads as: a tape row its tape, a block row its
    /// block and registration. Frees the result.
    fn read(rows: StoredRows) -> Vec<JsValue> {
        let lent = RESULTS.lock().unwrap().remove(&rows.handle).unwrap();
        let columns = lent.arenas[0].columns();
        let column = |name: &str| ITEM_COLUMNS.iter().position(|(n, _)| *n == name).unwrap();
        (0..rows.items.rows as usize)
            .map(|row| {
                if columns[column("format")].f64_at(row) == RowFormat::Block as u8 as f64 {
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
                3,
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
                store.ready_count(4, 100, 0),
                store.ready_count(4, 2, 0),
                store.ready_count(4, 1, 1),
                store.count_at_or_below(2),
            ),
            (4, 3, 2, 3)
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
        let contract_registers = read(store.events_of_registrations(vec![4]).unwrap());
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
