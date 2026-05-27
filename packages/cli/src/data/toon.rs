use std::fmt::Write;

use arrow::array::{Array, AsArray, RecordBatch};
use arrow::datatypes::DataType;
use hypersync_client::ArrowResponse;

use super::field_selection::{Column, Selection};
use super::mapping::{ColumnFormat, Section};

pub fn render_table(name: &str, columns: &[&str], rows: &[Vec<String>]) -> String {
    let mut out = String::new();
    let _ = write!(out, "{name}[{n}]{{", n = rows.len());
    for (i, c) in columns.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push_str(c);
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

pub fn render_arrow_response(selection: &Selection, response: &ArrowResponse) -> String {
    let mut section_order: Vec<Section> = Vec::new();
    for col in &selection.columns {
        if !section_order.contains(&col.section) {
            section_order.push(col.section);
        }
    }

    let mut out = String::new();
    for section in &section_order {
        let cols: Vec<&Column> = selection
            .columns
            .iter()
            .filter(|c| c.section == *section)
            .collect();
        let col_names: Vec<&str> = cols.iter().map(|c| c.indexer_name.as_str()).collect();
        let (plural, batches) = match section {
            Section::Block => ("blocks", &response.data.blocks),
            Section::Transaction => ("transactions", &response.data.transactions),
            Section::Log => ("logs", &response.data.logs),
        };

        let column_keys: Vec<String> = cols.iter().map(|c| c.field.column_name()).collect();
        let column_formats: Vec<ColumnFormat> =
            cols.iter().map(|c| c.field.column_format()).collect();
        let rows = extract_rows(batches, &column_keys, &column_formats);
        out.push_str(&render_table(plural, &col_names, &rows));
    }
    out
}

fn extract_rows(
    batches: &[RecordBatch],
    column_keys: &[String],
    column_formats: &[ColumnFormat],
) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    for batch in batches {
        let arrays: Vec<Option<&dyn Array>> = column_keys
            .iter()
            .map(|key| batch.column_by_name(key).map(|c| c.as_ref()))
            .collect();
        for row_idx in 0..batch.num_rows() {
            let row: Vec<String> = arrays
                .iter()
                .zip(column_formats.iter())
                .map(|(arr, fmt)| match arr {
                    Some(col) => cell_to_string(*col, row_idx, *fmt),
                    None => String::new(),
                })
                .collect();
            rows.push(row);
        }
    }
    rows
}

fn cell_to_string(col: &dyn Array, row: usize, fmt: ColumnFormat) -> String {
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
            match fmt {
                ColumnFormat::Decimal => binary_as_decimal(bytes),
                ColumnFormat::Hex => format!("0x{}", faster_hex::hex_string(bytes)),
            }
        }
        _ => String::new(),
    }
}

fn binary_as_decimal(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return "0".to_string();
    }
    let val = ruint::aliases::U256::try_from_be_slice(bytes).unwrap_or_default();
    val.to_string()
}

pub fn render_height(value: i64) -> String {
    render_table("height", &["value"], &[vec![value.to_string()]])
}

pub fn render_archive_height(value: i64) -> String {
    render_table("archiveHeight", &["value"], &[vec![value.to_string()]])
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
    fn empty_batches_render_zero_rows() {
        let s = extract_rows(&[], &["number".to_string()], &[ColumnFormat::Decimal]);
        assert!(s.is_empty());
    }
}
