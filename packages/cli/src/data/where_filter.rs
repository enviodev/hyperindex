use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Map, Value};

use super::chain::ChainKind;
use super::mapping::{self, FieldEntry, Section};

/// One field constraint inside `logs[]`/`transactions[]`/`receipts[]`. We
/// keep the indexer-side name verbatim so the pagination hint can echo back
/// what the user typed.
#[derive(Debug, Clone)]
pub struct FieldFilter {
    pub indexer_name: String,
    pub hs_name: String,
    pub values: Vec<Value>,
}

#[derive(Debug, Clone, Default)]
pub struct WhereFilter {
    pub from_block: Option<u64>,
    pub to_block_exclusive: Option<u64>,
    pub log_filters: Vec<FieldFilter>,
    pub transaction_filters: Vec<FieldFilter>,
    pub receipt_filters: Vec<FieldFilter>,
}

impl WhereFilter {
    pub fn parse(kind: ChainKind, raw: Option<&str>) -> Result<Self> {
        let Some(raw) = raw else {
            return Ok(Self::default());
        };
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return Ok(Self::default());
        }

        let value: Value = parse_where(trimmed)?;
        let root = match value {
            Value::Object(map) => map,
            _ => bail!("`--where` must be an object/mapping at the top level."),
        };

        let mut out = WhereFilter::default();
        for (section_raw, body) in root {
            if section_raw == "knownHeight" {
                bail!("`knownHeight` is not a filter — pass it as a positional field instead.");
            }
            let section = mapping::parse_section(kind, &section_raw).ok_or_else(|| {
                anyhow!(
                    "Unknown section `{section_raw}` in --where. Valid sections: {sections}.",
                    sections = mapping::allowed_sections(kind).join(", "),
                )
            })?;
            let fields = match body {
                Value::Object(m) => m,
                other => bail!(
                    "Expected object under `{section_raw}` in --where, got {kind}.",
                    kind = type_name(&other),
                ),
            };
            for (field_raw, field_body) in fields {
                let entry = mapping::lookup(kind, section, &field_raw).ok_or_else(|| {
                    let valid = mapping::valid_indexer_names(kind, section).join(", ");
                    anyhow!("Unknown field `{section_raw}.{field_raw}` in --where. Valid: {valid}.")
                })?;
                apply_field(kind, &mut out, entry, field_body)?;
            }
        }

        if let (Some(from), Some(to_excl)) = (out.from_block, out.to_block_exclusive) {
            if to_excl <= from {
                bail!("Block range is empty: from_block={from}, to_block(exclusive)={to_excl}.");
            }
        }

        Ok(out)
    }

    pub fn has_section_filters(&self) -> bool {
        !self.log_filters.is_empty()
            || !self.transaction_filters.is_empty()
            || !self.receipt_filters.is_empty()
    }

    /// Build the HS `/query` request body. `field_selection` is taken from the caller.
    pub fn build_query_body(&self, field_selection: Value) -> Value {
        let mut body = Map::new();
        body.insert(
            "from_block".to_string(),
            json!(self.from_block.unwrap_or(0)),
        );
        if let Some(to) = self.to_block_exclusive {
            body.insert("to_block".to_string(), json!(to));
        }
        if !self.log_filters.is_empty() {
            body.insert(
                "logs".to_string(),
                json!([build_log_selection(&self.log_filters)]),
            );
        }
        if !self.transaction_filters.is_empty() {
            body.insert(
                "transactions".to_string(),
                json!([build_flat_selection(&self.transaction_filters)]),
            );
        }
        if !self.receipt_filters.is_empty() {
            body.insert(
                "receipts".to_string(),
                json!([build_flat_selection(&self.receipt_filters)]),
            );
        }
        body.insert("field_selection".to_string(), field_selection);
        Value::Object(body)
    }
}

fn build_flat_selection(filters: &[FieldFilter]) -> Map<String, Value> {
    let mut out = Map::new();
    for f in filters {
        out.insert(f.hs_name.clone(), Value::Array(f.values.clone()));
    }
    out
}

fn build_log_selection(filters: &[FieldFilter]) -> Map<String, Value> {
    let mut out = Map::new();
    let mut topics: Vec<Vec<Value>> = Vec::new();
    for f in filters {
        if let Some(slot_str) = f.indexer_name.strip_prefix("topic") {
            if let Ok(slot) = slot_str.parse::<usize>() {
                while topics.len() <= slot {
                    topics.push(Vec::new());
                }
                topics[slot] = f.values.clone();
                continue;
            }
        }
        out.insert(f.hs_name.clone(), Value::Array(f.values.clone()));
    }
    if !topics.is_empty() {
        out.insert(
            "topics".to_string(),
            Value::Array(topics.into_iter().map(Value::Array).collect()),
        );
    }
    out
}

/// Parse `--where` as JSON5 — same braces/brackets as JSON but with relaxed
/// quoting (unquoted keys, single quotes), trailing commas, and comments.
fn parse_where(raw: &str) -> Result<Value> {
    json5::from_str::<Value>(raw).context(
        "Failed to parse --where. Expected JSON-like object, e.g.\n\
         --where='{ block: { number: { _gte: 1000, _lte: 2000 } }, log: { srcAddress: \"0xabc\" } }'",
    )
}

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn apply_field(
    kind: ChainKind,
    out: &mut WhereFilter,
    entry: FieldEntry,
    body: Value,
) -> Result<()> {
    // Block-range fields get special treatment — they collapse into from_block/to_block.
    let is_block_range_field = entry.section == Section::Block
        && match kind {
            ChainKind::Evm => entry.indexer_name == "number",
            ChainKind::Fuel => entry.indexer_name == "height",
        };

    if is_block_range_field {
        return apply_block_range(out, entry, body);
    }

    let dest = match entry.section {
        Section::Log => &mut out.log_filters,
        Section::Transaction => &mut out.transaction_filters,
        Section::Receipt => &mut out.receipt_filters,
        Section::Block => bail!(
            "Filtering on `block.{f}` is not supported. Only `block.{range_field}` (with _gte/_lt/_lte/_gt) is a block filter.",
            f = entry.indexer_name,
            range_field = match kind { ChainKind::Evm => "number", ChainKind::Fuel => "height" },
        ),
        Section::Input | Section::Output => bail!(
            "Filtering on `{section}.*` is not supported yet.",
            section = entry.section.as_indexer_str(),
        ),
    };

    let values = normalize_to_list(&entry, body)?;
    dest.push(FieldFilter {
        indexer_name: entry.indexer_name.to_string(),
        hs_name: entry.hs_name.to_string(),
        values,
    });
    Ok(())
}

fn apply_block_range(out: &mut WhereFilter, entry: FieldEntry, body: Value) -> Result<()> {
    let map = match body {
        Value::Object(m) => m,
        _ => bail!(
            "Expected operator object under `block.{f}` (e.g. `_gte: 1000`).",
            f = entry.indexer_name,
        ),
    };

    for (op, val) in map {
        let n = value_to_u64(&val).with_context(|| {
            format!(
                "Operator `{op}` on `block.{f}` expects a non-negative integer, got {val}",
                f = entry.indexer_name,
            )
        })?;
        match op.as_str() {
            "_gte" => {
                let candidate = n;
                out.from_block = Some(out.from_block.map_or(candidate, |cur| cur.max(candidate)));
            }
            "_gt" => {
                let candidate = n.saturating_add(1);
                out.from_block = Some(out.from_block.map_or(candidate, |cur| cur.max(candidate)));
            }
            "_lte" => {
                let candidate = n.saturating_add(1);
                out.to_block_exclusive = Some(
                    out.to_block_exclusive
                        .map_or(candidate, |cur| cur.min(candidate)),
                );
            }
            "_lt" => {
                let candidate = n;
                out.to_block_exclusive = Some(
                    out.to_block_exclusive
                        .map_or(candidate, |cur| cur.min(candidate)),
                );
            }
            other => bail!(
                "Unsupported operator `{other}` on `block.{f}`. Use `_gte`, `_gt`, `_lte`, `_lt`.",
                f = entry.indexer_name,
            ),
        }
    }

    Ok(())
}

fn value_to_u64(v: &Value) -> Result<u64> {
    match v {
        Value::Number(n) => n
            .as_u64()
            .ok_or_else(|| anyhow!("Expected non-negative integer, got {n}")),
        Value::String(s) => s.parse::<u64>().context("Failed to parse integer"),
        _ => Err(anyhow!("Expected integer, got {}", type_name(v))),
    }
}

fn normalize_to_list(entry: &FieldEntry, body: Value) -> Result<Vec<Value>> {
    match body {
        Value::String(_) | Value::Number(_) | Value::Bool(_) => Ok(vec![body]),
        Value::Array(arr) => Ok(arr),
        Value::Object(map) => {
            for (k, v) in &map {
                match k.as_str() {
                    "_eq" => return Ok(vec![v.clone()]),
                    "_in" => {
                        let arr = v.as_array().ok_or_else(|| {
                            anyhow!(
                                "`_in` on `{section}.{f}` expects an array, got {kind}",
                                section = entry.section.as_indexer_str(),
                                f = entry.indexer_name,
                                kind = type_name(v),
                            )
                        })?;
                        return Ok(arr.clone());
                    }
                    other => bail!(
                        "Unsupported operator `{other}` on `{section}.{f}`. Use a scalar, an array, `_eq`, or `_in`.",
                        section = entry.section.as_indexer_str(),
                        f = entry.indexer_name,
                    ),
                }
            }
            Ok(vec![])
        }
        Value::Null => bail!(
            "`{section}.{f}` cannot be null",
            section = entry.section.as_indexer_str(),
            f = entry.indexer_name,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    fn parse(raw: &str) -> WhereFilter {
        WhereFilter::parse(ChainKind::Evm, Some(raw)).unwrap()
    }

    fn body_for(raw: &str) -> Value {
        parse(raw).build_query_body(json!({"log": ["address"]}))
    }

    #[test]
    fn json5_block_range_and_address() {
        // Unquoted keys, single quotes — JSON5 lenience.
        let body = body_for(
            "{ block: { number: { _gte: 1000, _lte: 2000 } }, log: { srcAddress: '0xa0b8' } }",
        );
        assert_eq!(
            body,
            json!({
                "from_block": 1000,
                "to_block": 2001,
                "logs": [{"address": ["0xa0b8"]}],
                "field_selection": {"log": ["address"]},
            }),
        );
    }

    #[test]
    fn strict_json_still_parses() {
        let body = body_for(
            "{\"log\": {\"srcAddress\": {\"_in\": [\"0x1\", \"0x2\"]}, \"topic0\": {\"_eq\": \"0xabc\"}}}",
        );
        assert_eq!(
            body,
            json!({
                "from_block": 0,
                "logs": [{
                    "address": ["0x1", "0x2"],
                    "topics": [["0xabc"]],
                }],
                "field_selection": {"log": ["address"]},
            }),
        );
    }

    #[test]
    fn trailing_commas_and_comments() {
        let body = body_for(
            "{ // page over USDC transfers\n  block: { number: { _gte: 100, } },\n  log: { srcAddress: '0xa', }, }",
        );
        assert_eq!(
            (
                body["from_block"].clone(),
                body["logs"][0]["address"].clone()
            ),
            (json!(100), json!(["0xa"])),
        );
    }

    #[test]
    fn topic_slots_populate_correctly() {
        let body = body_for("{ log: { topic0: ['0xa'], topic2: '0xc' } }");
        assert_eq!(body["logs"][0]["topics"], json!([["0xa"], [], ["0xc"]]),);
    }

    #[test]
    fn array_value_becomes_in() {
        let body = body_for("{ log: { srcAddress: ['0xa', '0xb'] } }");
        assert_eq!(body["logs"][0]["address"], json!(["0xa", "0xb"]));
    }

    #[test]
    fn transaction_filters() {
        let body = body_for("{ transaction: { from: '0xa0b8', sighash: '0xdead' } }");
        assert_eq!(
            body["transactions"][0],
            json!({"from": ["0xa0b8"], "sighash": ["0xdead"]}),
        );
    }

    #[test]
    fn gt_and_lt_off_by_one_translation() {
        let body = body_for("{ block: { number: { _gt: 100, _lt: 200 } } }");
        assert_eq!(
            (body["from_block"].clone(), body["to_block"].clone()),
            (json!(101), json!(200)),
        );
    }

    #[test]
    fn empty_where_defaults_to_from_block_zero() {
        let body = WhereFilter::parse(ChainKind::Evm, None)
            .unwrap()
            .build_query_body(json!({"log": ["address"]}));
        assert_eq!(
            body,
            json!({"from_block": 0, "field_selection": {"log": ["address"]}}),
        );
    }

    #[test]
    fn known_height_in_where_errors() {
        let err = WhereFilter::parse(ChainKind::Evm, Some("{ knownHeight: 100 }"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("positional"), "{err}");
    }

    #[test]
    fn fuel_uses_block_height_for_range() {
        let f = WhereFilter::parse(
            ChainKind::Fuel,
            Some("{ block: { height: { _gte: 5, _lte: 9 } } }"),
        )
        .unwrap();
        assert_eq!((f.from_block, f.to_block_exclusive), (Some(5), Some(10)),);
    }

    #[test]
    fn unknown_field_errors_with_hint() {
        let err = WhereFilter::parse(ChainKind::Evm, Some("{ log: { foo: 'x' } }"))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("Unknown field") && err.contains("srcAddress"),
            "{err}"
        );
    }

    #[test]
    fn empty_block_range_errors() {
        let err = WhereFilter::parse(
            ChainKind::Evm,
            Some("{ block: { number: { _gte: 100, _lt: 100 } } }"),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("empty"), "{err}");
    }

    #[test]
    fn malformed_input_has_friendly_error() {
        let err = WhereFilter::parse(ChainKind::Evm, Some("{ block: }"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("--where"), "{err}");
    }
}
