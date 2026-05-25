use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

use hypersync_client::net_types::{FieldSelection, LogFilter, Query, TransactionFilter};

use super::mapping::{self, FieldEntry, Section};

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
}

impl WhereFilter {
    pub fn parse(raw: Option<&str>) -> Result<Self> {
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
            let section = mapping::parse_section(&section_raw).ok_or_else(|| {
                anyhow!(
                    "Unknown section `{section_raw}` in --where. Valid sections: {sections}.",
                    sections = mapping::ALLOWED_SECTIONS.join(", "),
                )
            })?;
            let fields = match body {
                Value::Object(m) => m,
                other => bail!(
                    "Expected object under `{section_raw}` in --where, got {t}.",
                    t = type_name(&other),
                ),
            };
            for (field_raw, field_body) in fields {
                let entry = mapping::lookup(section, &field_raw).ok_or_else(|| {
                    let valid = mapping::valid_indexer_names(section).join(", ");
                    anyhow!("Unknown field `{section_raw}.{field_raw}` in --where. Valid: {valid}.")
                })?;
                apply_field(&mut out, entry, field_body)?;
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
        !self.log_filters.is_empty() || !self.transaction_filters.is_empty()
    }

    pub fn build_net_query(&self, field_selection: FieldSelection) -> Result<Query> {
        let mut query = Query::new().from_block(self.from_block.unwrap_or(0));
        if let Some(to) = self.to_block_exclusive {
            query = query.to_block_excl(to);
        }
        query.field_selection = field_selection;

        if !self.log_filters.is_empty() {
            let mut lf = LogFilter::all();
            for f in &self.log_filters {
                let str_values: Vec<String> = f
                    .values
                    .iter()
                    .map(|v| match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect();
                let refs: Vec<&str> = str_values.iter().map(|s| s.as_str()).collect();
                match f.indexer_name.as_str() {
                    "srcAddress" => {
                        lf = lf
                            .and_address(refs)
                            .context("invalid address in log filter")?;
                    }
                    "topic0" => {
                        lf = lf
                            .and_topic0(refs)
                            .context("invalid topic0 in log filter")?;
                    }
                    "topic1" => {
                        lf = lf
                            .and_topic1(refs)
                            .context("invalid topic1 in log filter")?;
                    }
                    "topic2" => {
                        lf = lf
                            .and_topic2(refs)
                            .context("invalid topic2 in log filter")?;
                    }
                    "topic3" => {
                        lf = lf
                            .and_topic3(refs)
                            .context("invalid topic3 in log filter")?;
                    }
                    other => bail!("Unsupported log filter field `{other}` for native query"),
                }
            }
            query = query.where_logs(lf);
        }

        if !self.transaction_filters.is_empty() {
            let mut tf = TransactionFilter::all();
            for f in &self.transaction_filters {
                let str_values: Vec<String> = f
                    .values
                    .iter()
                    .map(|v| match v {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    })
                    .collect();
                let refs: Vec<&str> = str_values.iter().map(|s| s.as_str()).collect();
                match f.indexer_name.as_str() {
                    "from" => {
                        tf = tf
                            .and_from(refs)
                            .context("invalid from address in transaction filter")?;
                    }
                    "to" => {
                        tf = tf
                            .and_to(refs)
                            .context("invalid to address in transaction filter")?;
                    }
                    "sighash" => {
                        tf = tf
                            .and_sighash(refs)
                            .context("invalid sighash in transaction filter")?;
                    }
                    other => {
                        bail!("Unsupported transaction filter field `{other}` for native query")
                    }
                }
            }
            query = query.where_transactions(tf);
        }

        Ok(query)
    }
}

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

fn apply_field(out: &mut WhereFilter, entry: FieldEntry, body: Value) -> Result<()> {
    if entry.section == Section::Block && entry.indexer_name == "number" {
        return apply_block_range(out, entry, body);
    }

    let dest = match entry.section {
        Section::Log => &mut out.log_filters,
        Section::Transaction => &mut out.transaction_filters,
        Section::Block => bail!(
            "Filtering on `block.{f}` is not supported. Only `block.number` (with _gte/_lt/_lte/_gt) is a block filter.",
            f = entry.indexer_name,
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
                out.from_block = Some(out.from_block.map_or(n, |cur| cur.max(n)));
            }
            "_gt" => {
                let c = n.saturating_add(1);
                out.from_block = Some(out.from_block.map_or(c, |cur| cur.max(c)));
            }
            "_lte" => {
                let c = n.saturating_add(1);
                out.to_block_exclusive = Some(out.to_block_exclusive.map_or(c, |cur| cur.min(c)));
            }
            "_lt" => {
                out.to_block_exclusive = Some(out.to_block_exclusive.map_or(n, |cur| cur.min(n)));
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
                                "`_in` on `{s}.{f}` expects an array, got {t}",
                                s = entry.section.as_indexer_str(),
                                f = entry.indexer_name,
                                t = type_name(v),
                            )
                        })?;
                        return Ok(arr.clone());
                    }
                    other => bail!(
                        "Unsupported operator `{other}` on `{s}.{f}`. Use a scalar, an array, `_eq`, or `_in`.",
                        s = entry.section.as_indexer_str(),
                        f = entry.indexer_name,
                    ),
                }
            }
            Ok(vec![])
        }
        Value::Null => bail!(
            "`{s}.{f}` cannot be null",
            s = entry.section.as_indexer_str(),
            f = entry.indexer_name,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    fn pf(raw: &str) -> WhereFilter {
        WhereFilter::parse(Some(raw)).unwrap()
    }

    #[test]
    fn json5_block_range_and_address() {
        let f =
            pf("{ block: { number: { _gte: 1000, _lte: 2000 } }, log: { srcAddress: '0xa0b8' } }");
        assert_eq!(
            (f.from_block, f.to_block_exclusive),
            (Some(1000), Some(2001))
        );
        assert_eq!(
            (f.log_filters.len(), f.log_filters[0].indexer_name.as_str()),
            (1, "srcAddress")
        );
    }

    #[test]
    fn gt_and_lt_off_by_one() {
        let f = pf("{ block: { number: { _gt: 100, _lt: 200 } } }");
        assert_eq!((f.from_block, f.to_block_exclusive), (Some(101), Some(200)));
    }

    #[test]
    fn empty_where_defaults() {
        let f = WhereFilter::parse(None).unwrap();
        let q = f.build_net_query(FieldSelection::default()).unwrap();
        assert_eq!((q.from_block, q.to_block), (0, None));
    }

    #[test]
    fn known_height_in_where_errors() {
        let err = WhereFilter::parse(Some("{ knownHeight: 100 }"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("positional"), "{err}");
    }

    #[test]
    fn unknown_field_errors() {
        let err = WhereFilter::parse(Some("{ log: { foo: 'x' } }"))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("Unknown field") && err.contains("srcAddress"),
            "{err}"
        );
    }

    #[test]
    fn empty_range_errors() {
        let err = WhereFilter::parse(Some("{ block: { number: { _gte: 100, _lt: 100 } } }"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("empty"), "{err}");
    }

    #[test]
    fn malformed_input_error() {
        let err = WhereFilter::parse(Some("{ block: }"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("--where"), "{err}");
    }

    #[test]
    fn transaction_filters() {
        let f = pf("{ transaction: { from: '0xa0b8', sighash: '0xdead' } }");
        assert_eq!(f.transaction_filters.len(), 2);
    }

    #[test]
    fn trailing_commas_and_comments() {
        let f = pf(
            "{ // comment\n  block: { number: { _gte: 100, } },\n  log: { srcAddress: '0xa', }, }",
        );
        assert_eq!((f.from_block, f.log_filters.len()), (Some(100), 1));
    }
}
