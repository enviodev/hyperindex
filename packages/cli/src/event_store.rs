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

use crate::columnar::{js as columnar_js, Arena};
use crate::evm_hypersync_source::types::EvmParams;
use crate::js_value::JsTape;
use crate::storage::rows::{lay_out, Cell, ColumnRead, ReadKind};

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

/// Merges `incoming` into the sorted, deduplicated `rows`. On a tie the row
/// already stored is kept.
fn merge_rows(mut rows: VecDeque<Row>, mut incoming: Vec<Row>) -> VecDeque<Row> {
    // Stable, so of two equal incoming rows the first is the one kept.
    incoming.sort_by(Row::compare);
    let Some(first) = incoming.first() else {
        return rows;
    };
    // Stored rows up to the page's first row stay where they are, so a page at
    // the fetch frontier only appends, and a gap-filling page only moves the
    // rows after its own start.
    let start = rows.partition_point(|row| row.compare(first) != Ordering::Greater);
    let tail = rows.split_off(start);
    let mut push = |row: Row| {
        if rows
            .back()
            .is_none_or(|last| last.compare(&row) != Ordering::Equal)
        {
            rows.push_back(row);
        }
    };
    let mut stored = tail.into_iter().peekable();
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
    rows
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

/// A tape's cell: its position among the result's tapes.
fn tape_cell(tapes: &mut Vec<JsTape>, tape: &JsTape) -> Cell<'static> {
    tapes.push(tape.clone());
    Cell::Num((tapes.len() - 1) as f64)
}

/// Lays rows out as the arenas `StoredRows` describes, and keeps them until
/// JavaScript has read them.
fn lay_out_rows<'a>(rows: impl IntoIterator<Item = &'a Row>) -> Result<StoredRows> {
    let mut item_cells = Vec::new();
    let mut fuel_cells = Vec::new();
    let mut svm_cells = Vec::new();
    let (mut fuel_rows, mut svm_rows) = (0usize, 0usize);
    let mut tapes = Vec::new();
    // Each registration's EVM logs' params, in order.
    let mut params: Vec<(i64, Vec<&'a EvmParams>)> = Vec::new();
    let mut count = 0usize;
    for row in rows {
        count += 1;
        let registration = Cell::Num(row.registration_index as f64);
        let (transaction_index, src_address, skipped, detail_row, tape) = match &row.data {
            RowData::EvmLog {
                src_address,
                transaction_index,
                params: log_params,
            } => {
                let group = match params
                    .iter_mut()
                    .find(|(index, _)| *index == row.registration_index)
                {
                    Some((_, group)) => group,
                    None => {
                        params.push((row.registration_index, Vec::new()));
                        &mut params.last_mut().unwrap().1
                    }
                };
                group.push(log_params);
                (
                    Cell::Num(*transaction_index as f64),
                    Cell::Str(src_address.as_str().into()),
                    Cell::Null,
                    Cell::Num((group.len() - 1) as f64),
                    Cell::Null,
                )
            }
            RowData::FuelReceipt {
                tx_id,
                src_address,
                params,
            } => {
                fuel_cells.extend([
                    registration.clone(),
                    Cell::Num(row.log_index as f64),
                    Cell::Str(tx_id.as_str().into()),
                    Cell::Num(row.block_number as f64),
                    Cell::Str(src_address.as_str().into()),
                    tape_cell(&mut tapes, params),
                ]);
                fuel_rows += 1;
                (
                    Cell::Null,
                    Cell::Null,
                    Cell::Null,
                    Cell::Num((fuel_rows - 1) as f64),
                    Cell::Null,
                )
            }
            RowData::SvmInstruction {
                program_id,
                accounts,
                data,
                is_inner,
                args,
                logs,
            } => {
                let path = row.order_path.as_deref().unwrap_or_default();
                let optional_tape = |tapes: &mut Vec<JsTape>, tape: &Option<JsTape>| match tape {
                    Some(tape) => tape_cell(tapes, tape),
                    None => Cell::Null,
                };
                svm_cells.extend([
                    registration.clone(),
                    Cell::Num(row.block_number as f64),
                    Cell::Num(row.log_index as f64),
                    Cell::Arr(path.iter().map(|step| Cell::Num(*step as f64)).collect()),
                    Cell::Str(program_id.as_str().into()),
                    Cell::Arr(
                        accounts
                            .iter()
                            .map(|account| Cell::Str(account.as_str().into()))
                            .collect(),
                    ),
                    Cell::Bytes(data.as_slice().into()),
                    Cell::Bool(*is_inner),
                    optional_tape(&mut tapes, args),
                    optional_tape(&mut tapes, logs),
                ]);
                svm_rows += 1;
                (
                    Cell::Null,
                    Cell::Null,
                    Cell::Null,
                    Cell::Num((svm_rows - 1) as f64),
                    Cell::Null,
                )
            }
            RowData::Block { skipped } => (
                Cell::Null,
                Cell::Null,
                Cell::Bool(*skipped),
                Cell::Null,
                Cell::Null,
            ),
            RowData::JsItem(item) => (
                Cell::Null,
                Cell::Null,
                Cell::Null,
                Cell::Null,
                tape_cell(&mut tapes, item),
            ),
        };
        item_cells.extend([
            Cell::Num(row.data.format() as u8 as f64),
            Cell::Num(row.block_number as f64),
            Cell::Num(row.log_index as f64),
            transaction_index,
            registration,
            src_address,
            skipped,
            detail_row,
            tape,
        ]);
    }

    let item_columns: Vec<ColumnRead> = ITEM_COLUMNS
        .iter()
        .map(|(name, kind)| ColumnRead::scalar(*name, *kind))
        .collect();
    let items = ArenaShape::of(&item_columns, count);
    let mut arenas = vec![lay_out(&item_cells, item_columns)?.arena];

    let mut params_shapes = Vec::with_capacity(params.len());
    for (registration_index, group) in params {
        let schema = &group[0].schema;
        let columns: Vec<ColumnRead> = schema
            .params
            .iter()
            .zip(&schema.kinds)
            .map(|(param, kind)| ColumnRead::scalar(param.name.clone(), *kind))
            .collect();
        let mut cells = Vec::with_capacity(group.len() * columns.len());
        for log_params in &group {
            for index in 0..columns.len() {
                cells.push(log_params.cell(index, &mut tapes));
            }
        }
        params_shapes.push(ParamsShape {
            registration_index,
            shape: ArenaShape::of(&columns, group.len()),
        });
        arenas.push(lay_out(&cells, columns)?.arena);
    }

    let fuel = ArenaShape::of(&fuel_columns(), fuel_rows);
    arenas.push(lay_out(&fuel_cells, fuel_columns())?.arena);
    let svm = ArenaShape::of(&svm_columns(), svm_rows);
    arenas.push(lay_out(&svm_cells, svm_columns())?.arena);

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
    rows: Mutex<VecDeque<Row>>,
}

impl EventStore {
    pub(crate) fn from_rows(rows: Vec<Row>) -> Self {
        EventStore {
            rows: Mutex::new(merge_rows(VecDeque::new(), rows)),
        }
    }

    fn rows(&self) -> std::sync::MutexGuard<'_, VecDeque<Row>> {
        self.rows.lock().unwrap()
    }

    fn insert(&self, incoming: Vec<Row>) {
        let mut rows = self.rows();
        let stored = std::mem::take(&mut *rows);
        *rows = merge_rows(stored, incoming);
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
        let incoming = std::mem::take(&mut *page.rows());
        self.insert(incoming.into());
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
        self.rows()
            .partition_point(|row| row.block_number <= block_number) as u32
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
        let mut rows = self.rows();
        let count = (count as usize).min(rows.len());
        let taken: Vec<Row> = rows.drain(..count).collect();
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
        self.rows()
            .retain(|row| row.block_number <= target_block_number);
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
