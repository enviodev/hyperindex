//! Built items on their way to JavaScript: laid out as arenas, column by
//! column, the way storage hands JavaScript a query result, and lent to it
//! until it has read them.

use std::sync::{LazyLock, Mutex};

use alloy_primitives::U256;
use anyhow::{Context, Result};
use napi::bindgen_prelude::ArrayBuffer;
use napi::Env;
use napi_derive::napi;

use super::tables::table::RowRef;
use super::walk::{Built, Item, ItemLinks};
use crate::ecosystems::evm::format::{
    AccessList as AccessListItem, Authorization as AuthorizationItem,
};
use crate::ecosystems::evm::registration::{ParamCell, ParamSchema};
use crate::js_value::JsTape;
use crate::storage::columnar::{js as columnar_js, Arena, ColumnSpec};
use crate::storage::rows::{ColumnRead, ReadKind};

/// The columns of an arena, which JavaScript builds its views from.
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

/// One registration's EVM log params, a row per log.
#[napi(object)]
pub struct ParamsShape {
    pub registration_index: i64,
    pub shape: ArenaShape,
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmLamportsOut {
    pub pre: Option<napi::bindgen_prelude::BigInt>,
    pub post: Option<napi::bindgen_prelude::BigInt>,
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmAccountTokenOut {
    pub mint: String,
    pub owner: Option<String>,
    pub decimals: Option<u8>,
    pub pre_amount: Option<napi::bindgen_prelude::BigInt>,
    pub post_amount: Option<napi::bindgen_prelude::BigInt>,
}

#[napi(object)]
#[derive(Clone)]
pub struct SvmAccountActivityOut {
    pub address: String,
    pub transaction_account_index: Option<i64>,
    pub is_signer: Option<bool>,
    pub is_writable: Option<bool>,
    pub lamports: Option<SvmLamportsOut>,
    pub token: Option<SvmAccountTokenOut>,
}

/// A batch's transactions or blocks: an arena with a row each and a column
/// per selected field, null where a row has no value. The nested fields,
/// which have no column shape, travel beside it.
#[napi(object, object_from_js = false)]
pub struct FieldRows {
    pub shape: ArenaShape,
    pub access_list: Option<Vec<Option<Vec<AccessListItem>>>>,
    pub authorization_list: Option<Vec<Option<Vec<AuthorizationItem>>>>,
    pub account_activities: Option<Vec<Option<Vec<SvmAccountActivityOut>>>>,
}

/// Items built from the buffer. The arenas behind `handle` hold, in order:
/// `items`, a row per item in processing order; each registration's EVM
/// `params`; `fuel` and `svm`, the whole record of each such item; `links`,
/// each item's row among `transactions` and `blocks`; then `transactions` and
/// `blocks` themselves when present. `tapes` carries what has no column shape.
#[napi(object, object_from_js = false)]
pub struct BuiltItems {
    pub handle: u32,
    pub items: ArenaShape,
    pub params: Vec<ParamsShape>,
    pub fuel: ArenaShape,
    pub svm: ArenaShape,
    pub links: ArenaShape,
    pub transactions: Option<FieldRows>,
    pub blocks: Option<FieldRows>,
    pub tapes: Vec<JsTape>,
    /// The last block the items cover whole.
    pub last_block: Option<i64>,
}

/// Which JS conversion an item goes through.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ItemFormat {
    EvmLog = 0,
    FuelReceipt = 1,
    SvmInstruction = 2,
    Block = 3,
    Decoded = 4,
    Transaction = 5,
}

const FORMAT_BITS: u32 = 3;

pub(crate) const ITEM_COLUMNS: [(&str, ReadKind); 8] = [
    // The item's `ItemFormat` in the low `FORMAT_BITS`, and above them its row
    // in its format's own arena.
    ("detail", ReadKind::Float),
    ("blockNumber", ReadKind::Float),
    ("logIndex", ReadKind::Float),
    ("transactionIndex", ReadKind::Float),
    ("registrationIndex", ReadKind::Float),
    ("srcAddress", ReadKind::Text),
    ("skipped", ReadKind::Bool),
    // A decoded item's record.
    ("tape", ReadKind::Float),
];

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

fn item_columns() -> Vec<ColumnRead> {
    ITEM_COLUMNS
        .iter()
        .map(|(name, kind)| ColumnRead::scalar(*name, *kind))
        .collect()
}

/// Named as `FuelEventItem.item`'s fields.
pub(crate) fn fuel_columns() -> Vec<ColumnRead> {
    vec![
        ColumnRead::scalar("receiptIndex", ReadKind::Float),
        ColumnRead::scalar("txId", ReadKind::Text),
        ColumnRead::scalar("blockHeight", ReadKind::Float),
        ColumnRead::scalar("srcAddress", ReadKind::Text),
        ColumnRead::scalar("params", ReadKind::Tape),
    ]
}

/// Named as `SvmEventItem.item`'s fields.
pub(crate) fn svm_columns() -> Vec<ColumnRead> {
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

fn link_columns() -> Vec<ColumnRead> {
    vec![
        ColumnRead::scalar("transactionRow", ReadKind::Float),
        ColumnRead::scalar("blockRow", ReadKind::Float),
    ]
}

/// A link to no row: the item gets an empty object of its own.
pub(crate) const EMPTY_LINK: f64 = -1.0;

/// `elements` gives a list column's element count across all rows.
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

/// An arena written row by row, each column once per row.
struct ArenaWriter {
    arena: Arena,
    row: usize,
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

fn pack_detail(format: ItemFormat, detail_row: usize) -> f64 {
    ((detail_row << FORMAT_BITS) | format as usize) as f64
}

fn seal(columns: &[ColumnRead], arena: &mut Arena) -> Result<ArenaShape> {
    let shape = ArenaShape::of(columns, arena.rows());
    arena.seal(&shape.names)?;
    Ok(shape)
}

/// Lays built items out as arenas and holds them for JavaScript.
pub(crate) fn lay_out(built: Built) -> Result<BuiltItems> {
    let Built {
        items,
        links,
        transactions,
        blocks,
        last_block,
    } = built;
    let mut tapes: Vec<JsTape> = Vec::new();

    // Each format's rows, counted first so every arena is sized once.
    let (mut fuel_rows, mut svm_rows, mut svm_steps, mut svm_accounts) = (0, 0, 0, 0);
    let mut params_of: Vec<Option<(&ParamSchema, usize)>> = Vec::new();
    for item in &items {
        match item {
            Item::EvmLog {
                registration,
                params,
                ..
            } => {
                let index = *registration as usize;
                if params_of.len() <= index {
                    params_of.resize(index + 1, None);
                }
                params_of[index].get_or_insert((&params.schema, 0)).1 += 1;
            }
            Item::Fuel { .. } => fuel_rows += 1,
            Item::Svm { path, accounts, .. } => {
                svm_rows += 1;
                svm_steps += path.len();
                svm_accounts += accounts.len();
            }
            Item::Block { .. } | Item::Decoded { .. } | Item::Transaction { .. } => {}
        }
    }

    let mut writer = ArenaWriter::new(sized_arena(&item_columns(), items.len(), &[]));
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

    for item in &items {
        let unset: &[usize] = match item {
            Item::EvmLog {
                block_number,
                log_index,
                transaction_index,
                registration,
                src_address,
                params: log_params,
            } => {
                let (_, group) = params[*registration as usize]
                    .as_mut()
                    .expect("counted in the first pass");
                for (column, cell) in log_params.cells.iter().enumerate() {
                    match cell {
                        ParamCell::Bool(value) => group.bool(column, *value),
                        ParamCell::Text(value) => group.bytes(column, value.as_bytes()),
                        ParamCell::Tape(tape) => group.tape(column, &mut tapes, tape),
                    }
                }
                writer.num(item_column::BLOCK_NUMBER, *block_number as f64);
                writer.num(item_column::LOG_INDEX, *log_index as f64);
                writer.num(item_column::TRANSACTION_INDEX, *transaction_index as f64);
                writer.num(item_column::REGISTRATION_INDEX, *registration as f64);
                writer.bytes(item_column::SRC_ADDRESS, src_address.as_bytes());
                writer.num(
                    item_column::DETAIL,
                    pack_detail(ItemFormat::EvmLog, group.row),
                );
                group.end_row();
                &[item_column::SKIPPED, item_column::TAPE]
            }
            Item::Fuel {
                block_number,
                receipt_index,
                registration,
                tx_id,
                src_address,
                params,
            } => {
                fuel.num(0, *receipt_index as f64);
                fuel.bytes(1, tx_id.as_bytes());
                fuel.num(2, *block_number as f64);
                fuel.bytes(3, src_address.as_bytes());
                fuel.tape(4, &mut tapes, params);
                writer.num(item_column::BLOCK_NUMBER, *block_number as f64);
                writer.num(item_column::LOG_INDEX, *receipt_index as f64);
                writer.num(item_column::REGISTRATION_INDEX, *registration as f64);
                writer.num(
                    item_column::DETAIL,
                    pack_detail(ItemFormat::FuelReceipt, fuel.row),
                );
                fuel.end_row();
                &[
                    item_column::TRANSACTION_INDEX,
                    item_column::SRC_ADDRESS,
                    item_column::SKIPPED,
                    item_column::TAPE,
                ]
            }
            Item::Svm {
                slot,
                transaction_index,
                path,
                registration,
                program_id,
                accounts,
                data,
                is_inner,
                args,
                logs,
            } => {
                svm.num(0, *slot as f64);
                svm.num(1, *transaction_index as f64);
                svm.num_list(2, path);
                svm.bytes(3, program_id.as_bytes());
                svm.text_list(4, accounts);
                svm.bytes(5, data);
                svm.bool(6, *is_inner);
                svm.optional_tape(7, &mut tapes, args);
                svm.optional_tape(8, &mut tapes, logs);
                writer.num(item_column::BLOCK_NUMBER, *slot as f64);
                writer.num(item_column::LOG_INDEX, *transaction_index as f64);
                writer.num(item_column::TRANSACTION_INDEX, *transaction_index as f64);
                writer.num(item_column::REGISTRATION_INDEX, *registration as f64);
                writer.num(
                    item_column::DETAIL,
                    pack_detail(ItemFormat::SvmInstruction, svm.row),
                );
                svm.end_row();
                &[
                    item_column::SRC_ADDRESS,
                    item_column::SKIPPED,
                    item_column::TAPE,
                ]
            }
            Item::Block {
                block_number,
                registration,
                skipped,
            } => {
                writer.num(item_column::BLOCK_NUMBER, *block_number as f64);
                writer.num(item_column::LOG_INDEX, 0.0);
                writer.num(item_column::REGISTRATION_INDEX, *registration as f64);
                writer.bool(item_column::SKIPPED, *skipped);
                writer.num(item_column::DETAIL, pack_detail(ItemFormat::Block, 0));
                &[
                    item_column::TRANSACTION_INDEX,
                    item_column::SRC_ADDRESS,
                    item_column::TAPE,
                ]
            }
            Item::Transaction {
                block_number,
                transaction_index,
                registration,
            } => {
                writer.num(item_column::BLOCK_NUMBER, *block_number as f64);
                writer.num(item_column::LOG_INDEX, *transaction_index as f64);
                writer.num(item_column::TRANSACTION_INDEX, *transaction_index as f64);
                writer.num(item_column::REGISTRATION_INDEX, *registration as f64);
                writer.num(item_column::DETAIL, pack_detail(ItemFormat::Transaction, 0));
                &[
                    item_column::SRC_ADDRESS,
                    item_column::SKIPPED,
                    item_column::TAPE,
                ]
            }
            Item::Decoded {
                block_number,
                log_index,
                registration,
                tape,
                transaction_index,
                ..
            } => {
                writer.num(item_column::BLOCK_NUMBER, *block_number as f64);
                writer.num(item_column::LOG_INDEX, *log_index as f64);
                writer.num(item_column::REGISTRATION_INDEX, *registration as f64);
                writer.tape(item_column::TAPE, &mut tapes, tape);
                writer.num(item_column::DETAIL, pack_detail(ItemFormat::Decoded, 0));
                match transaction_index {
                    Some(index) => {
                        writer.num(item_column::TRANSACTION_INDEX, *index as f64);
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
            writer.null(*column);
        }
        writer.end_row();
    }

    let mut link_arena = sized_arena(&link_columns(), items.len(), &[]);
    for (row, ItemLinks { transaction, block }) in links.iter().enumerate() {
        match transaction {
            Some(link) => link_arena.set_f64(0, row, *link),
            None => link_arena.mark_null(0, row),
        }
        match block {
            Some(link) => link_arena.set_f64(1, row, *link),
            None => link_arena.mark_null(1, row),
        }
    }

    let mut items_arena = writer.arena;
    let items_shape = seal(&item_columns(), &mut items_arena)?;
    let mut arenas = vec![items_arena];
    let mut params_shapes = Vec::new();
    for (registration_index, group) in params.into_iter().enumerate() {
        if let Some((columns, mut group)) = group {
            params_shapes.push(ParamsShape {
                registration_index: registration_index as i64,
                shape: seal(&columns, &mut group.arena)?,
            });
            arenas.push(group.arena);
        }
    }
    let mut fuel_arena = fuel.arena;
    let fuel_shape = seal(&fuel_columns(), &mut fuel_arena)?;
    arenas.push(fuel_arena);
    let mut svm_arena = svm.arena;
    let svm_shape = seal(&svm_columns(), &mut svm_arena)?;
    arenas.push(svm_arena);
    let links_shape = seal(&link_columns(), &mut link_arena)?;
    arenas.push(link_arena);
    let transactions = match transactions {
        Some(columns) => {
            let (arena, rows) = columns.into_arena()?;
            arenas.push(arena);
            Some(rows)
        }
        None => None,
    };
    let blocks = match blocks {
        Some(columns) => {
            let (arena, rows) = columns.into_arena()?;
            arenas.push(arena);
            Some(rows)
        }
        None => None,
    };
    Ok(BuiltItems {
        handle: hold(arenas)?,
        items: items_shape,
        params: params_shapes,
        fuel: fuel_shape,
        svm: svm_shape,
        links: links_shape,
        transactions,
        blocks,
        tapes,
        last_block: last_block.map(|block| block as i64),
    })
}

/// One field across all rows, `None` where a row has no value.
pub enum Column {
    I64(Vec<Option<i64>>),
    F64(Vec<Option<f64>>),
    Bool(Vec<Option<bool>>),
    Big(Vec<Option<U256>>),
    Str(Vec<Option<String>>),
    StrVec(Vec<Option<Vec<String>>>),
    AccessList(Vec<Option<Vec<AccessListItem>>>),
    AuthList(Vec<Option<Vec<AuthorizationItem>>>),
    AccountActivities(Vec<Option<Vec<SvmAccountActivityOut>>>),
}

pub struct Columns {
    pub len: usize,
    pub columns: Vec<(&'static str, Column)>,
}

/// A field's cells across `rows`: `None` where the row's mask leaves the
/// field out or the table has no row.
pub(crate) fn cells<T>(
    rows: &[Option<RowRef>],
    masks: &[u64],
    bit: u64,
    read: impl Fn(&RowRef) -> Result<Option<T>>,
) -> Result<Vec<Option<T>>> {
    rows.iter()
        .zip(masks)
        .map(|(row, mask)| match row {
            Some(row) if mask & bit != 0 => read(row),
            _ => Ok(None),
        })
        .collect()
}

fn write_cells<T>(
    arena: &mut Arena,
    column: usize,
    cells: &[Option<T>],
    mut write: impl FnMut(&mut Arena, usize, &T),
) {
    for (row, cell) in cells.iter().enumerate() {
        match cell {
            Some(value) => write(arena, row, value),
            None => arena.mark_null(column, row),
        }
    }
}

impl Columns {
    /// Lays the flat columns out as a sealed arena; the nested ones travel
    /// beside it.
    pub fn into_arena(self) -> Result<(Arena, FieldRows)> {
        let mut reads = Vec::new();
        let mut flat = Vec::new();
        let mut rows = FieldRows {
            shape: ArenaShape::of(&[], self.len),
            access_list: None,
            authorization_list: None,
            account_activities: None,
        };
        for (name, column) in self.columns {
            let column = match column {
                Column::AccessList(values) => {
                    rows.access_list = Some(values);
                    continue;
                }
                Column::AuthList(values) => {
                    rows.authorization_list = Some(values);
                    continue;
                }
                Column::AccountActivities(values) => {
                    rows.account_activities = Some(values);
                    continue;
                }
                column => column,
            };
            reads.push(match &column {
                Column::Bool(_) => ColumnRead::scalar(name, ReadKind::Bool),
                Column::Big(_) => ColumnRead::scalar(name, ReadKind::BigInt),
                Column::Str(_) => ColumnRead::scalar(name, ReadKind::Text),
                Column::StrVec(_) => ColumnRead::list(name, ReadKind::Text),
                _ => ColumnRead::scalar(name, ReadKind::Float),
            });
            flat.push(column);
        }
        let specs: Vec<ColumnSpec> = reads
            .iter()
            .zip(&flat)
            .map(|(read, column)| match column {
                Column::StrVec(lists) => ColumnSpec::List {
                    element: ReadKind::Text.slot(),
                    elements: lists.iter().flatten().map(Vec::len).sum(),
                },
                _ => ColumnSpec::Scalar(read.kind.slot()),
            })
            .collect();
        let mut arena = Arena::new_filled(self.len, &specs);
        for (index, column) in flat.into_iter().enumerate() {
            match column {
                Column::I64(cells) => write_cells(&mut arena, index, &cells, |arena, row, v| {
                    arena.set_f64(index, row, *v as f64)
                }),
                Column::F64(cells) => write_cells(&mut arena, index, &cells, |arena, row, v| {
                    arena.set_f64(index, row, *v)
                }),
                Column::Bool(cells) => write_cells(&mut arena, index, &cells, |arena, row, v| {
                    arena.set_f64(index, row, if *v { 1.0 } else { 0.0 })
                }),
                Column::Big(cells) => write_cells(&mut arena, index, &cells, |arena, row, v| {
                    arena.set_bytes(index, row, v.to_string().as_bytes())
                }),
                Column::Str(cells) => write_cells(&mut arena, index, &cells, |arena, row, v| {
                    arena.set_bytes(index, row, v.as_bytes())
                }),
                Column::StrVec(cells) => {
                    let mut written = 0;
                    for (row, cell) in cells.iter().enumerate() {
                        match cell {
                            Some(values) => {
                                for value in values {
                                    arena.set_element_bytes(index, written, value.as_bytes());
                                    written += 1;
                                }
                            }
                            None => arena.mark_null(index, row),
                        }
                        arena.end_list_row(index, row, written);
                    }
                }
                Column::AccessList(_) | Column::AuthList(_) | Column::AccountActivities(_) => {
                    unreachable!("nested columns travel beside the arena")
                }
            }
        }
        rows.shape = ArenaShape::of(&reads, self.len);
        arena.seal(&rows.shape.names)?;
        Ok((arena, rows))
    }
}

/// Decodes each field of `variants` some mask selects.
pub fn build_columns<F: Copy>(
    variants: &'static [F],
    masks: &[u64],
    len: usize,
    ordinal: impl Fn(F) -> u32,
    name: impl Fn(F) -> &'static str,
    decode: impl Fn(F) -> Result<Column>,
) -> Result<Columns> {
    let union = masks.iter().fold(0u64, |acc, &mask| acc | mask);
    let mut columns = Vec::new();
    for &field in variants {
        if union & (1u64 << ordinal(field)) == 0 {
            continue;
        }
        let field_name = name(field);
        let column = decode(field).with_context(|| format!("decoding field '{field_name}'"))?;
        columns.push((field_name, column));
    }
    Ok(Columns { len, columns })
}

/// Quantity hex: leading zeros trimmed, zero itself "0x0".
pub(crate) fn hex_quantity(bytes: &[u8]) -> String {
    let hex = faster_hex::hex_string(bytes);
    match hex.find(|c| c != '0') {
        Some(index) => format!("0x{}", &hex[index..]),
        None => "0x0".into(),
    }
}

pub(crate) fn utf8(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// The arenas JavaScript has yet to read.
struct Lent {
    arenas: Vec<Arena>,
    buffer_counts: Vec<usize>,
}

/// Results in reused slots. A handle is its slot in the low `SLOT_BITS` and
/// the slot's generation above, so a handle released twice finds nothing
/// once its slot holds another result.
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
                anyhow::ensure!(
                    self.slots.len() < 1 << SLOT_BITS,
                    "{} results are waiting to be read, more than handles can address",
                    self.slots.len()
                );
                self.slots.push((0, None));
                (self.slots.len() - 1) as u32
            }
        };
        let (generation, entry) = &mut self.slots[slot as usize];
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

    fn remove(&mut self, handle: u32) -> Option<Lent> {
        let lent = self.entry(handle)?.take()?;
        self.free.push(handle & ((1 << SLOT_BITS) - 1));
        Some(lent)
    }
}

static RESULTS: LazyLock<Mutex<Results>> = LazyLock::new(Default::default);

/// Keeps sealed arenas until JavaScript has read them through `lend_rows` and
/// `release_rows`, by the handle this returns.
pub(crate) fn hold(arenas: Vec<Arena>) -> Result<u32> {
    RESULTS.lock().unwrap().insert(Lent {
        arenas,
        buffer_counts: Vec::new(),
    })
}

pub(crate) fn lend_rows<'env>(env: &'env Env, handle: u32) -> napi::Result<Vec<ArrayBuffer<'env>>> {
    let mut results = RESULTS.lock().unwrap();
    let lent = results
        .entry(handle)
        .and_then(Option::as_mut)
        .ok_or_else(|| napi::Error::from_reason(format!("Unknown rows {handle}")))?;
    let mut buffers = Vec::new();
    for arena in lent.arenas.iter_mut() {
        match columnar_js::lend_for_reading(env, arena) {
            Ok(lent_buffers) => {
                lent.buffer_counts.push(lent_buffers.len());
                buffers.extend(lent_buffers);
            }
            Err(error) => {
                let lent = results.remove(handle).unwrap();
                give_back(lent, buffers).ok();
                return Err(error);
            }
        }
    }
    Ok(buffers)
}

pub(crate) fn release_rows(handle: u32, buffers: Vec<ArrayBuffer>) -> napi::Result<()> {
    let Some(lent) = RESULTS.lock().unwrap().remove(handle) else {
        return Ok(());
    };
    give_back(lent, buffers)
}

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
            // A buffer not handed back may still be viewed: leak rather than
            // free under it.
            std::mem::forget(lent);
            Err(error)
        }
    }
}
