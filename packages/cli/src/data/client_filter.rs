use anyhow::{anyhow, bail, Result};
use arrow::array::{Array, AsArray, RecordBatch};
use arrow::datatypes::DataType;
use hypersync_client::ArrowResponse;
use ruint::aliases::U256;
use serde_json::Value;

use super::mapping::{Section, ValueKind};
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

pub fn compute_masks(response: &ArrowResponse, filters: &[ClientFilter]) -> Result<Masks> {
    let mut masks = Masks::default();
    if filters.is_empty() {
        return Ok(masks);
    }

    for section in [Section::Block, Section::Transaction, Section::Log] {
        let compiled = filters
            .iter()
            .filter(|f| f.field.section() == section)
            .map(CompiledFilter::compile)
            .collect::<Result<Vec<_>>>()?;
        if compiled.is_empty() {
            continue;
        }
        let batches = match section {
            Section::Block => &response.data.blocks,
            Section::Transaction => &response.data.transactions,
            Section::Log => &response.data.logs,
        };
        let mask = compute_section_mask(batches, &compiled)?;
        match section {
            Section::Block => masks.block = Some(mask),
            Section::Transaction => masks.transaction = Some(mask),
            Section::Log => masks.log = Some(mask),
        }
    }

    Ok(masks)
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
}
