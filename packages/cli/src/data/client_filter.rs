use std::collections::HashSet;

use anyhow::{anyhow, bail, Result};
use arrow::array::{Array, AsArray, RecordBatch};
use arrow::datatypes::DataType;
use hypersync_client::net_types::{
    block::BlockField, log::LogField, transaction::TransactionField,
};
use hypersync_client::ArrowResponse;
use ruint::aliases::U256;
use serde_json::Value;

use super::mapping::{Section, TypedField, ValueKind};
use super::where_filter::{ClientFilter, CmpOp, Cond};

/// Per-section keep masks, aligned with the row order produced when iterating a
/// section's record batches in order. `None` means the section has no client
/// filters and every row is kept.
#[derive(Default)]
pub struct Masks {
    pub block: Option<Vec<bool>>,
    pub transaction: Option<Vec<bool>>,
    pub log: Option<Vec<bool>>,
}

/// Decides whether filters on one section restrict rows of another via the
/// block/transaction/log foreign keys, and which join-key fields must be fetched
/// to evaluate it. A section is *filtered* if it carries a row-level filter, and
/// *relevant* if it is filtered or selected for output. Cross-section joining
/// kicks in once at least two sections are relevant and one is filtered.
#[derive(Debug, Clone, Copy)]
pub struct JoinPlan {
    block_filtered: bool,
    tx_filtered: bool,
    log_filtered: bool,
    block_relevant: bool,
    tx_relevant: bool,
    log_relevant: bool,
    pub active: bool,
}

impl JoinPlan {
    /// `filtered` and `output` are indexed by `Section::index` (`[block,
    /// transaction, log]`).
    pub fn new(filtered: [bool; 3], output: [bool; 3]) -> Self {
        let [block_filtered, tx_filtered, log_filtered] = filtered;
        let [block_out, tx_out, log_out] = output;
        let block_relevant = block_filtered || block_out;
        let tx_relevant = tx_filtered || tx_out;
        let log_relevant = log_filtered || log_out;
        let relevant = block_relevant as u8 + tx_relevant as u8 + log_relevant as u8;
        let active = (block_filtered || tx_filtered || log_filtered) && relevant >= 2;
        Self {
            block_filtered,
            tx_filtered,
            log_filtered,
            block_relevant,
            tx_relevant,
            log_relevant,
            active,
        }
    }

    /// Foreign-key columns that must be fetched on top of the user's output so
    /// the join can be evaluated client-side. Empty unless a join is active.
    /// `block.number` is added only when the block section participates with its
    /// own row-level predicate or output — a pure range never needs it.
    pub fn extra_fields(&self) -> Vec<TypedField> {
        if !self.active {
            return Vec::new();
        }
        let mut fields = Vec::new();
        if self.log_relevant {
            fields.push(TypedField::Log(LogField::BlockNumber));
            fields.push(TypedField::Log(LogField::TransactionIndex));
        }
        if self.tx_relevant {
            fields.push(TypedField::Transaction(TransactionField::BlockNumber));
            fields.push(TypedField::Transaction(TransactionField::TransactionIndex));
        }
        if self.block_relevant {
            fields.push(TypedField::Block(BlockField::Number));
        }
        fields
    }
}

pub fn compute_masks(
    response: &ArrowResponse,
    filters: &[ClientFilter],
    plan: &JoinPlan,
) -> Result<Masks> {
    let mut masks = Masks::default();

    for section in [Section::Block, Section::Transaction, Section::Log] {
        let compiled = filters
            .iter()
            .filter(|f| f.field.section() == section)
            .map(CompiledFilter::compile)
            .collect::<Result<Vec<_>>>()?;
        if compiled.is_empty() {
            continue;
        }
        let batches = section_batches(response, section);
        let mask = compute_section_mask(batches, &compiled)?;
        match section {
            Section::Block => masks.block = Some(mask),
            Section::Transaction => masks.transaction = Some(mask),
            Section::Log => masks.log = Some(mask),
        }
    }

    if plan.active {
        apply_join(response, plan, &mut masks);
    }

    Ok(masks)
}

fn section_batches(response: &ArrowResponse, section: Section) -> &[RecordBatch] {
    match section {
        Section::Block => &response.data.blocks,
        Section::Transaction => &response.data.transactions,
        Section::Log => &response.data.logs,
    }
}

/// Propagates keep masks across the block ⊃ transaction ⊃ log hierarchy. A
/// filtered parent drops its children (down); a filtered child drops parents
/// that have no surviving descendant (up). Filtered sections act as inner joins,
/// unfiltered ones as optional, so a matching transaction with no logs survives
/// while logs whose transaction was dropped do not. Join keys absent from the
/// response leave the corresponding edge untouched.
fn apply_join(response: &ArrowResponse, plan: &JoinPlan, masks: &mut Masks) {
    let blocks = &response.data.blocks;
    let txs = &response.data.transactions;
    let logs = &response.data.logs;

    let mut mb = materialize(masks.block.take(), section_rows(blocks));
    let mut mt = materialize(masks.transaction.take(), section_rows(txs));
    let mut ml = materialize(masks.log.take(), section_rows(logs));

    let block_num = read_u64_col(blocks, "number");
    let tx_bn = read_u64_col(txs, "block_number");
    let tx_ti = read_u64_col(txs, "transaction_index");
    let log_bn = read_u64_col(logs, "block_number");
    let log_ti = read_u64_col(logs, "transaction_index");

    // Down: a kept parent is required for a child to survive.
    if plan.block_filtered {
        if let Some(block_num) = &block_num {
            let kept = kept_set(block_num, &mb);
            if let Some(tx_bn) = &tx_bn {
                retain(&mut mt, |i| kept.contains(&tx_bn[i]));
            }
            if let Some(log_bn) = &log_bn {
                retain(&mut ml, |j| kept.contains(&log_bn[j]));
            }
        }
    }
    if plan.tx_filtered {
        if let (Some(tx_bn), Some(tx_ti), Some(log_bn), Some(log_ti)) =
            (&tx_bn, &tx_ti, &log_bn, &log_ti)
        {
            let kept = kept_pair_set(tx_bn, tx_ti, &mt);
            retain(&mut ml, |j| kept.contains(&(log_bn[j], log_ti[j])));
        }
    }

    // Up: a filtered child requires its parents to hold a surviving descendant.
    if plan.log_filtered {
        if let (Some(log_bn), Some(log_ti)) = (&log_bn, &log_ti) {
            let surviving = kept_pair_set(log_bn, log_ti, &ml);
            if let (Some(tx_bn), Some(tx_ti)) = (&tx_bn, &tx_ti) {
                retain(&mut mt, |i| surviving.contains(&(tx_bn[i], tx_ti[i])));
            }
        }
        if let Some(log_bn) = &log_bn {
            let surviving = kept_set(log_bn, &ml);
            if let Some(block_num) = &block_num {
                retain(&mut mb, |i| surviving.contains(&block_num[i]));
            }
        }
    }
    if plan.tx_filtered {
        if let Some(tx_bn) = &tx_bn {
            let surviving = kept_set(tx_bn, &mt);
            if let Some(block_num) = &block_num {
                retain(&mut mb, |i| surviving.contains(&block_num[i]));
            }
        }
    }

    masks.block = Some(mb);
    masks.transaction = Some(mt);
    masks.log = Some(ml);
}

fn materialize(mask: Option<Vec<bool>>, rows: usize) -> Vec<bool> {
    mask.unwrap_or_else(|| vec![true; rows])
}

fn retain(mask: &mut [bool], keep: impl Fn(usize) -> bool) {
    for (i, m) in mask.iter_mut().enumerate() {
        if *m && !keep(i) {
            *m = false;
        }
    }
}

fn kept_set(keys: &[u64], mask: &[bool]) -> HashSet<u64> {
    keys.iter()
        .zip(mask)
        .filter(|(_, keep)| **keep)
        .map(|(k, _)| *k)
        .collect()
}

fn kept_pair_set(a: &[u64], b: &[u64], mask: &[bool]) -> HashSet<(u64, u64)> {
    (0..mask.len())
        .filter(|&i| mask[i])
        .map(|i| (a[i], b[i]))
        .collect()
}

fn section_rows(batches: &[RecordBatch]) -> usize {
    batches.iter().map(RecordBatch::num_rows).sum()
}

fn read_u64_col(batches: &[RecordBatch], column: &str) -> Option<Vec<u64>> {
    let mut out = Vec::new();
    for batch in batches {
        let col = batch.column_by_name(column)?;
        for row in 0..batch.num_rows() {
            out.push(read_u64(col.as_ref(), row));
        }
    }
    Some(out)
}

fn read_u64(col: &dyn Array, row: usize) -> u64 {
    if col.is_null(row) {
        return 0;
    }
    match col.data_type() {
        DataType::UInt64 => col
            .as_primitive::<arrow::datatypes::UInt64Type>()
            .value(row),
        DataType::UInt8 => col.as_primitive::<arrow::datatypes::UInt8Type>().value(row) as u64,
        DataType::Binary => {
            let bytes = col.as_binary::<i32>().value(row);
            let mut buf = [0u8; 8];
            let n = bytes.len().min(8);
            buf[8 - n..].copy_from_slice(&bytes[bytes.len() - n..]);
            u64::from_be_bytes(buf)
        }
        _ => 0,
    }
}

struct CompiledFilter {
    column: String,
    kind: ValueKind,
    conds: Vec<CompiledCond>,
}

enum CompiledCond {
    In(Vec<Cell>),
    Cmp(CmpOp, U256),
}

impl CompiledFilter {
    fn compile(f: &ClientFilter) -> Result<Self> {
        let kind = f.field.spec().value_kind;
        let label = format!(
            "{}.{}",
            f.field.section().as_indexer_str(),
            f.field.camel_name(),
        );
        let conds = f
            .conds
            .iter()
            .map(|cond| match cond {
                Cond::In(vals) => Ok(CompiledCond::In(
                    vals.iter()
                        .map(|v| filter_cell(v, kind, &label))
                        .collect::<Result<Vec<_>>>()?,
                )),
                Cond::Cmp(op, v) => Ok(CompiledCond::Cmp(*op, filter_u256(v, &label)?)),
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(Self {
            column: f.field.column_name(),
            kind,
            conds,
        })
    }
}

fn compute_section_mask(batches: &[RecordBatch], filters: &[CompiledFilter]) -> Result<Vec<bool>> {
    let mut mask = Vec::new();
    for batch in batches {
        let cols: Vec<&dyn Array> = filters
            .iter()
            .map(|f| {
                batch
                    .column_by_name(&f.column)
                    .map(|c| c.as_ref())
                    .ok_or_else(|| {
                        anyhow!("filter column `{}` missing from query response", f.column)
                    })
            })
            .collect::<Result<Vec<_>>>()?;
        for row in 0..batch.num_rows() {
            let keep = filters.iter().zip(cols.iter()).all(|(f, col)| {
                let cell = read_cell(*col, row, f.kind);
                cell_passes(&cell, &f.conds)
            });
            mask.push(keep);
        }
    }
    Ok(mask)
}

#[derive(Debug, Clone, PartialEq)]
enum Cell {
    Num(U256),
    Hex(String),
    Bool(bool),
    Null,
}

fn read_cell(col: &dyn Array, row: usize, kind: ValueKind) -> Cell {
    if col.is_null(row) {
        return Cell::Null;
    }
    match col.data_type() {
        DataType::UInt64 => Cell::Num(U256::from(
            col.as_primitive::<arrow::datatypes::UInt64Type>()
                .value(row),
        )),
        DataType::UInt8 => Cell::Num(U256::from(
            col.as_primitive::<arrow::datatypes::UInt8Type>().value(row),
        )),
        DataType::Boolean => Cell::Bool(col.as_boolean().value(row)),
        DataType::Binary => {
            let bytes = col.as_binary::<i32>().value(row);
            match kind {
                ValueKind::Numeric => Cell::Num(U256::try_from_be_slice(bytes).unwrap_or_default()),
                ValueKind::Hex | ValueKind::Bool => Cell::Hex(faster_hex::hex_string(bytes)),
            }
        }
        dt => unreachable!("unexpected arrow data type {dt:?} for envio data column"),
    }
}

fn cell_passes(cell: &Cell, conds: &[CompiledCond]) -> bool {
    conds.iter().all(|cond| match cond {
        CompiledCond::In(vals) => vals.iter().any(|v| v == cell),
        CompiledCond::Cmp(op, target) => match cell {
            Cell::Num(n) => match op {
                CmpOp::Gt => n > target,
                CmpOp::Gte => n >= target,
                CmpOp::Lt => n < target,
                CmpOp::Lte => n <= target,
            },
            _ => false,
        },
    })
}

fn filter_cell(v: &Value, kind: ValueKind, label: &str) -> Result<Cell> {
    match kind {
        ValueKind::Numeric => Ok(Cell::Num(filter_u256(v, label)?)),
        ValueKind::Hex => match v {
            Value::String(s) => Ok(Cell::Hex(normalize_hex(s, label)?)),
            other => bail!(
                "Filter on `{label}` expects a hex string, got {}",
                json_type(other),
            ),
        },
        ValueKind::Bool => match v {
            Value::Bool(b) => Ok(Cell::Bool(*b)),
            other => bail!(
                "Filter on `{label}` expects true or false, got {}",
                json_type(other),
            ),
        },
    }
}

fn filter_u256(v: &Value, label: &str) -> Result<U256> {
    match v {
        Value::Number(n) => match n.as_u64() {
            Some(u) => Ok(U256::from(u)),
            None => U256::from_str_radix(&n.to_string(), 10)
                .map_err(|_| anyhow!("Filter on `{label}` expects an integer, got {n}")),
        },
        Value::String(s) => parse_u256_str(s)
            .ok_or_else(|| anyhow!("Filter on `{label}` expects an integer, got \"{s}\"")),
        other => bail!(
            "Filter on `{label}` expects a number, got {}",
            json_type(other),
        ),
    }
}

fn parse_u256_str(s: &str) -> Option<U256> {
    let s = s.trim();
    match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        Some(hex) => U256::from_str_radix(hex, 16).ok(),
        None => U256::from_str_radix(s, 10).ok(),
    }
}

fn normalize_hex(s: &str, label: &str) -> Result<String> {
    let t = s.trim();
    let hex = t
        .strip_prefix("0x")
        .or_else(|| t.strip_prefix("0X"))
        .unwrap_or(t);
    if hex.is_empty() || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("Filter on `{label}` expects a hex string, got \"{s}\"");
    }
    Ok(hex.to_ascii_lowercase())
}

fn json_type(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::mapping::lookup;
    use crate::data::where_filter::WhereFilter;
    use arrow::array::{BinaryArray, RecordBatch, UInt64Array};
    use arrow::datatypes::{DataType, Field, Schema};
    use pretty_assertions::assert_eq;
    use std::sync::Arc;

    fn client_filters(raw: &str) -> Vec<ClientFilter> {
        WhereFilter::parse(Some(raw)).unwrap().client_filters
    }

    fn log_batch_value(values: &[u64]) -> RecordBatch {
        let schema = Schema::new(vec![Field::new("block_number", DataType::UInt64, false)]);
        RecordBatch::try_new(
            Arc::new(schema),
            vec![Arc::new(UInt64Array::from(values.to_vec()))],
        )
        .unwrap()
    }

    #[test]
    fn numeric_range_mask() {
        let filters = client_filters("{ log: { blockNumber: { _gte: 10, _lt: 20 } } }");
        let batches = vec![log_batch_value(&[5, 10, 15, 19, 20, 25])];
        let mask = compute_section_mask(
            &batches,
            &filters
                .iter()
                .map(CompiledFilter::compile)
                .collect::<Result<Vec<_>>>()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(mask, vec![false, true, true, true, false, false]);
    }

    #[test]
    fn numeric_in_mask() {
        let filters = client_filters("{ transaction: { value: { _in: [100, 300] } } }");
        let schema = Schema::new(vec![Field::new("value", DataType::UInt64, false)]);
        let batch = RecordBatch::try_new(
            Arc::new(schema),
            vec![Arc::new(UInt64Array::from(vec![100u64, 200, 300, 400]))],
        )
        .unwrap();
        let mask = compute_section_mask(
            &[batch],
            &filters
                .iter()
                .map(CompiledFilter::compile)
                .collect::<Result<Vec<_>>>()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(mask, vec![true, false, true, false]);
    }

    #[test]
    fn block_number_in_mask() {
        let filters = client_filters("{ block: { number: { _in: [10, 12] } } }");
        let schema = Schema::new(vec![Field::new("number", DataType::UInt64, false)]);
        let batch = RecordBatch::try_new(
            Arc::new(schema),
            vec![Arc::new(UInt64Array::from(vec![10u64, 11, 12]))],
        )
        .unwrap();
        let mask = compute_section_mask(
            &[batch],
            &filters
                .iter()
                .map(CompiledFilter::compile)
                .collect::<Result<Vec<_>>>()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(mask, vec![true, false, true]);
    }

    #[test]
    fn hex_eq_mask() {
        let filters = client_filters("{ log: { data: '0xABCD' } }");
        let schema = Schema::new(vec![Field::new("data", DataType::Binary, false)]);
        let batch = RecordBatch::try_new(
            Arc::new(schema),
            vec![Arc::new(BinaryArray::from(vec![
                [0xab, 0xcd].as_slice(),
                [0x00, 0x01].as_slice(),
            ]))],
        )
        .unwrap();
        let mask = compute_section_mask(
            &[batch],
            &filters
                .iter()
                .map(CompiledFilter::compile)
                .collect::<Result<Vec<_>>>()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(mask, vec![true, false]);
    }

    #[test]
    fn data_field_is_client_side() {
        // `log.data` has no Hypersync builder, so it must route to client filters.
        let f = WhereFilter::parse(Some("{ log: { data: '0xabcd' } }")).unwrap();
        let routed = (
            f.server_filters.len(),
            f.client_filters.len(),
            f.client_filters[0].field.section(),
        );
        assert_eq!(routed, (0, 1, Section::Log));
    }

    #[test]
    fn address_stays_server_side() {
        let f = WhereFilter::parse(Some("{ log: { srcAddress: '0xa0b8' } }")).unwrap();
        assert_eq!((f.server_filters.len(), f.client_filters.len()), (1, 0));
    }

    #[test]
    fn comparison_on_numeric_field_is_client_side() {
        let f = WhereFilter::parse(Some("{ transaction: { value: { _gt: 1000 } } }")).unwrap();
        assert_eq!((f.server_filters.len(), f.client_filters.len()), (0, 1));
    }

    #[test]
    fn comparison_on_hex_field_is_rejected() {
        let err = WhereFilter::parse(Some("{ log: { srcAddress: { _gt: '0xa' } } }"))
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @"Comparison operators are only supported on numeric fields; `log.srcAddress` is not numeric. Use `_eq` or `_in`.");
    }

    #[test]
    fn lookup_is_used_for_section() {
        // sanity: the helper used by classification resolves to the Log section.
        assert_eq!(
            lookup(Section::Log, "data").unwrap().section(),
            Section::Log,
        );
    }

    // End-to-end: parse a `--where` with several client-only filters, build an
    // Arrow response, then mask + render. Exercises numeric range, `_in`, and a
    // big-endian binary numeric comparison across two independent sections.
    #[test]
    fn advanced_client_filtering_end_to_end() {
        use crate::data::field_selection::Selection;
        use crate::data::toon::render_arrow_response;
        use hypersync_client::{ArrowResponse, ArrowResponseData};

        let selection = Selection::parse(&[
            "log.blockNumber".into(),
            "log.logIndex".into(),
            "transaction.value".into(),
        ])
        .unwrap();

        let filter = WhereFilter::parse(Some(
            "{ log: { blockNumber: { _gte: 10, _lt: 20 }, logIndex: { _in: [0, 2] } }, \
               transaction: { value: { _gt: 100 } } }",
        ))
        .unwrap();
        assert_eq!(
            (filter.server_filters.len(), filter.client_filters.len()),
            (0, 3),
        );

        let log_schema = Schema::new(vec![
            Field::new("block_number", DataType::UInt64, false),
            Field::new("log_index", DataType::UInt64, false),
        ]);
        let logs = RecordBatch::try_new(
            Arc::new(log_schema),
            vec![
                Arc::new(UInt64Array::from(vec![5u64, 10, 15, 15, 20, 19])),
                Arc::new(UInt64Array::from(vec![0u64, 0, 1, 2, 2, 0])),
            ],
        )
        .unwrap();

        // `transaction.value` is a numeric field stored as big-endian bytes.
        let value_bytes: Vec<Vec<u8>> = [50u64, 150, 100, 200]
            .iter()
            .map(|n| n.to_be_bytes().to_vec())
            .collect();
        let tx_schema = Schema::new(vec![Field::new("value", DataType::Binary, false)]);
        let transactions = RecordBatch::try_new(
            Arc::new(tx_schema),
            vec![Arc::new(BinaryArray::from(
                value_bytes.iter().map(|v| v.as_slice()).collect::<Vec<_>>(),
            ))],
        )
        .unwrap();

        let response = ArrowResponse {
            archive_height: Some(1000),
            next_block: 1000,
            total_execution_time: 0,
            data: ArrowResponseData {
                logs: vec![logs],
                transactions: vec![transactions],
                ..Default::default()
            },
            rollback_guard: None,
        };

        let plan = JoinPlan::new(filter.filtered_sections(), selection.output_sections());
        let masks = compute_masks(&response, &filter.client_filters, &plan).unwrap();
        let out = render_arrow_response(&selection, &response, &masks);

        assert_eq!(
            out,
            "logs[3]{blockNumber,logIndex}:\n  10,0\n  15,2\n  19,0\n\
             transactions[2]{value}:\n  150\n  200\n",
        );
    }

    fn u64_batch(columns: &[(&str, &[u64])]) -> RecordBatch {
        let fields: Vec<Field> = columns
            .iter()
            .map(|(name, _)| Field::new(*name, DataType::UInt64, false))
            .collect();
        let arrays: Vec<Arc<dyn Array>> = columns
            .iter()
            .map(|(_, vals)| Arc::new(UInt64Array::from(vals.to_vec())) as Arc<dyn Array>)
            .collect();
        RecordBatch::try_new(Arc::new(Schema::new(fields)), arrays).unwrap()
    }

    fn response_of(
        blocks: Vec<RecordBatch>,
        transactions: Vec<RecordBatch>,
        logs: Vec<RecordBatch>,
    ) -> hypersync_client::ArrowResponse {
        use hypersync_client::{ArrowResponse, ArrowResponseData};
        ArrowResponse {
            archive_height: Some(1000),
            next_block: 1000,
            total_execution_time: 0,
            data: ArrowResponseData {
                blocks,
                transactions,
                logs,
                ..Default::default()
            },
            rollback_guard: None,
        }
    }

    // A transaction filter keeps only logs whose transaction matches (down) and
    // only transactions that still hold a matching log (up): tx (1,1) has no
    // surviving log, log (1,5) has no matching transaction, so both drop.
    #[test]
    fn cross_section_join_is_bidirectional() {
        let transactions = u64_batch(&[("block_number", &[1, 1]), ("transaction_index", &[0, 1])]);
        let logs = u64_batch(&[("block_number", &[1, 1]), ("transaction_index", &[0, 5])]);
        let response = response_of(vec![], vec![transactions], vec![logs]);

        // transaction + log filtered server-side, no client filters.
        let plan = JoinPlan::new([false, true, true], [false, true, true]);
        let masks = compute_masks(&response, &[], &plan).unwrap();

        assert_eq!(
            (masks.block, masks.transaction, masks.log),
            (
                Some(vec![]),
                Some(vec![true, false]),
                Some(vec![true, false])
            ),
        );
    }

    // A `block.number` set filters the block section and, cross-section, restricts
    // logs to the surviving blocks.
    #[test]
    fn cross_section_block_filter_restricts_logs() {
        let client = client_filters("{ block: { number: { _in: [10, 99] } } }");
        let blocks = u64_batch(&[("number", &[10, 11])]);
        let logs = u64_batch(&[("block_number", &[10, 10, 11])]);
        let response = response_of(vec![blocks], vec![], vec![logs]);

        // block filtered; block + log relevant (log selected for output).
        let plan = JoinPlan::new([true, false, false], [true, false, true]);
        let masks = compute_masks(&response, &client, &plan).unwrap();

        assert_eq!(
            (masks.block, masks.transaction, masks.log),
            (
                Some(vec![true, false]),
                Some(vec![]),
                Some(vec![true, true, false]),
            ),
        );
    }

    #[test]
    fn single_relevant_section_skips_join() {
        let plan = JoinPlan::new([false, false, true], [false, false, true]);
        assert_eq!((plan.active, plan.extra_fields().len()), (false, 0));
    }

    #[test]
    fn join_injects_keys_for_relevant_sections() {
        let plan = JoinPlan::new([false, true, false], [false, false, true]);
        let names: Vec<String> = plan
            .extra_fields()
            .iter()
            .map(|f| format!("{}.{}", f.section().as_indexer_str(), f.camel_name()))
            .collect();
        assert_eq!(
            names,
            vec![
                "log.blockNumber",
                "log.transactionIndex",
                "transaction.blockNumber",
                "transaction.transactionIndex",
            ],
        );
    }
}
