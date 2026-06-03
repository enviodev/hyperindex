use std::fmt::Write;

use arrow::array::{Array, AsArray, RecordBatch};
use arrow::datatypes::DataType;
use hypersync_client::ArrowResponse;

use super::client_filter::Masks;
use super::field_selection::{Column, Selection};
use super::mapping::{Section, ValueKind};

pub fn render_table(name: &str, columns: &[impl AsRef<str>], rows: &[Vec<String>]) -> String {
    let mut out = String::new();
    let _ = write!(out, "{name}[{n}]{{", n = rows.len());
    for (i, c) in columns.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(c.as_ref());
    }
    out.push_str("}:\n");
    for row in rows {
        out.push_str("  ");
        for (i, cell) in row.iter().enumerate() {
            if i > 0 {
                out.push(',');
            }
            out.push_str(&escape_cell(cell));
        }
        out.push('\n');
    }
    out
}

fn escape_cell(s: &str) -> String {
    let needs_quoting = s.contains(',')
        || s.contains('\n')
        || s.contains('"')
        || s.starts_with(' ')
        || s.ends_with(' ');
    if !needs_quoting {
        return s.to_string();
    }
    let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// A section's rendered rows, kept separate from the final TOON string so pages
/// can be accumulated before rendering a single table per section.
pub struct SectionTable {
    pub section: Section,
    pub plural: &'static str,
    pub col_names: Vec<String>,
    pub rows: Vec<Vec<String>>,
}

pub fn collect_sections(
    selection: &Selection,
    response: &ArrowResponse,
    masks: &Masks,
) -> Vec<SectionTable> {
    let mut section_order: Vec<Section> = Vec::new();
    for col in &selection.columns {
        if !section_order.contains(&col.section) {
            section_order.push(col.section);
        }
    }

    let mut tables = Vec::new();
    for section in &section_order {
        let cols: Vec<&Column> = selection
            .columns
            .iter()
            .filter(|c| c.section == *section)
            .collect();
        let col_names: Vec<String> = cols.iter().map(|c| c.display_name.clone()).collect();
        let (plural, batches, mask) = match section {
            Section::Block => ("blocks", &response.data.blocks, masks.block.as_deref()),
            Section::Transaction => (
                "transactions",
                &response.data.transactions,
                masks.transaction.as_deref(),
            ),
            Section::Log => ("logs", &response.data.logs, masks.log.as_deref()),
        };

        let column_keys: Vec<String> = cols.iter().map(|c| c.field.column_name()).collect();
        let column_kinds: Vec<ValueKind> = cols.iter().map(|c| c.field.spec().value_kind).collect();
        let rows = extract_rows(batches, &column_keys, &column_kinds, mask);
        tables.push(SectionTable {
            section: *section,
            plural,
            col_names,
            rows,
        });
    }
    tables
}

pub fn render_sections(tables: &[SectionTable]) -> String {
    let mut out = String::new();
    for table in tables {
        out.push_str(&render_table(table.plural, &table.col_names, &table.rows));
    }
    out
}

#[cfg(test)]
pub fn render_arrow_response(
    selection: &Selection,
    response: &ArrowResponse,
    masks: &Masks,
) -> String {
    render_sections(&collect_sections(selection, response, masks))
}

fn extract_rows(
    batches: &[RecordBatch],
    column_keys: &[String],
    column_kinds: &[ValueKind],
    mask: Option<&[bool]>,
) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row_offset = 0;
    for batch in batches {
        let arrays: Vec<Option<&dyn Array>> = column_keys
            .iter()
            .map(|key| batch.column_by_name(key).map(|c| c.as_ref()))
            .collect();
        for row_idx in 0..batch.num_rows() {
            let keep = mask.is_none_or(|m| m[row_offset + row_idx]);
            if !keep {
                continue;
            }
            let row: Vec<String> = arrays
                .iter()
                .zip(column_kinds.iter())
                .map(|(arr, kind)| match arr {
                    Some(col) => cell_to_string(*col, row_idx, *kind),
                    None => String::new(),
                })
                .collect();
            rows.push(row);
        }
        row_offset += batch.num_rows();
    }
    rows
}

fn cell_to_string(col: &dyn Array, row: usize, kind: ValueKind) -> String {
    if col.is_null(row) {
        return String::new();
    }
    match col.data_type() {
        DataType::UInt64 => col
            .as_primitive::<arrow::datatypes::UInt64Type>()
            .value(row)
            .to_string(),
        DataType::UInt8 => col
            .as_primitive::<arrow::datatypes::UInt8Type>()
            .value(row)
            .to_string(),
        DataType::Boolean => col.as_boolean().value(row).to_string(),
        DataType::Binary => {
            let bytes = col.as_binary::<i32>().value(row);
            match kind {
                ValueKind::Numeric => binary_as_decimal(bytes),
                ValueKind::Hex | ValueKind::Bool => format!("0x{}", faster_hex::hex_string(bytes)),
            }
        }
        dt => unreachable!("unexpected arrow data type {dt:?} for envio data column"),
    }
}

fn binary_as_decimal(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return "0".to_string();
    }
    let val = ruint::aliases::U256::try_from_be_slice(bytes).unwrap_or_default();
    val.to_string()
}

pub fn render_height(value: u64) -> String {
    format!("knownHeight: {value}\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn quotes_cells_with_commas() {
        let s = render_table("t", &["a"], &[vec!["x,y".into()]]);
        assert_eq!(s, "t[1]{a}:\n  \"x,y\"\n");
    }

    #[test]
    fn header_uses_field_name_as_typed() {
        use super::super::client_filter::Masks;
        use super::super::field_selection::Selection;
        use arrow::array::UInt64Array;
        use arrow::datatypes::{Field, Schema};
        use hypersync_client::{ArrowResponse, ArrowResponseData};
        use std::sync::Arc;

        let selection = Selection::parse(&["block.hash".into(), "block.NUMBER".into()]).unwrap();
        let schema = Schema::new(vec![
            Field::new("hash", DataType::Binary, false),
            Field::new("number", DataType::UInt64, false),
        ]);
        let blocks = RecordBatch::try_new(
            Arc::new(schema),
            vec![
                Arc::new(arrow::array::BinaryArray::from(vec![[0xaa].as_slice()])),
                Arc::new(UInt64Array::from(vec![100u64])),
            ],
        )
        .unwrap();
        let response = ArrowResponse {
            archive_height: Some(100),
            next_block: 100,
            total_execution_time: 0,
            data: ArrowResponseData {
                blocks: vec![blocks],
                ..Default::default()
            },
            rollback_guard: None,
        };

        let out = render_arrow_response(&selection, &response, &Masks::default());
        assert_eq!(out, "blocks[1]{hash,NUMBER}:\n  0xaa,100\n");
    }

    #[test]
    fn empty_batches_render_zero_rows() {
        let s = extract_rows(&[], &["number".to_string()], &[ValueKind::Numeric], None);
        assert!(s.is_empty());
    }
}
