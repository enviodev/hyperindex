use serde_json::Value;
use std::fmt::Write;

use super::field_selection::{Column, Selection};
use super::mapping::Section;

/// One tabular block in TOON form:
///
///     name[N]{col1,col2}:
///       v1,v2
///       v1,v2
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

/// Render the HS `/query` response data into one TOON block per section.
/// `selection` controls section order and column order (positional input order).
pub fn render_response(selection: &Selection, response: &Value) -> String {
    let data_arr = response
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    // Group columns by section in the order they appear in `selection.columns`.
    let mut section_order: Vec<Section> = Vec::new();
    for col in &selection.columns {
        if !section_order.contains(&col.section) {
            section_order.push(col.section);
        }
    }

    let mut out = String::new();
    for section in section_order {
        let cols: Vec<&Column> = selection
            .columns
            .iter()
            .filter(|c| c.section == section)
            .collect();
        let col_names: Vec<&str> = cols.iter().map(|c| c.indexer_name.as_str()).collect();
        let hs_key = section.as_hs_key();
        let plural = match section {
            Section::Block => "blocks",
            Section::Transaction => "transactions",
            Section::Log => "logs",
            Section::Receipt => "receipts",
            Section::Input => "inputs",
            Section::Output => "outputs",
        };

        let mut rows: Vec<Vec<String>> = Vec::new();
        for page in &data_arr {
            let Some(items) = page.get(plural).and_then(Value::as_array) else {
                continue;
            };
            for item in items {
                let row: Vec<String> = cols
                    .iter()
                    .map(|c| stringify(item.get(&c.hs_name)))
                    .collect();
                rows.push(row);
            }
        }

        // Always emit the section header — empty results stay visible.
        out.push_str(&render_table(plural, &col_names, &rows));
        // suppress unused warning for hs_key on Section variants we don't iterate by hs_key
        let _ = hs_key;
    }
    out
}

pub fn render_height(value: i64) -> String {
    render_table("height", &["value"], &[vec![value.to_string()]])
}

pub fn render_archive_height(value: i64) -> String {
    render_table("archiveHeight", &["value"], &[vec![value.to_string()]])
}

fn stringify(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::chain::ChainKind;
    use pretty_assertions::assert_eq;
    use serde_json::json;

    #[test]
    fn renders_two_section_response() {
        let sel = Selection::parse(
            ChainKind::Evm,
            &[
                "block.number".into(),
                "log.srcAddress".into(),
                "log.logIndex".into(),
            ],
        )
        .unwrap();

        let response = json!({
            "data": [
                {
                    "blocks": [{"number": 1700}, {"number": 1701}],
                    "logs": [
                        {"address": "0xaaa", "log_index": 0},
                        {"address": "0xbbb", "log_index": 3},
                    ]
                },
                {
                    "blocks": [{"number": 1702}],
                    "logs": []
                }
            ]
        });

        let toon = render_response(&sel, &response);
        assert_eq!(
            toon,
            "blocks[3]{number}:\n  1700\n  1701\n  1702\nlogs[2]{srcAddress,logIndex}:\n  0xaaa,0\n  0xbbb,3\n",
        );
    }

    #[test]
    fn renders_empty_sections_with_zero_count() {
        let sel = Selection::parse(ChainKind::Evm, &["log.srcAddress".into()]).unwrap();
        let response = json!({"data": []});
        assert_eq!(render_response(&sel, &response), "logs[0]{srcAddress}:\n",);
    }

    #[test]
    fn quotes_cells_with_commas() {
        let s = render_table("t", &["a"], &[vec!["x,y".into()]]);
        assert_eq!(s, "t[1]{a}:\n  \"x,y\"\n");
    }

    #[test]
    fn null_renders_as_empty_cell() {
        let sel = Selection::parse(ChainKind::Evm, &["block.baseFeePerGas".into()]).unwrap();
        let response = json!({"data": [{"blocks": [{"base_fee_per_gas": null}]}]});
        assert_eq!(
            render_response(&sel, &response),
            "blocks[1]{baseFeePerGas}:\n  \n",
        );
    }
}
