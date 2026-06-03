use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

use hypersync_client::net_types::{
    BlockFilter, FieldSelection, LogFilter, Query, TransactionFilter,
};

use super::mapping::{self, ColumnFormat, Section, TypedField};

#[derive(Debug, Clone)]
pub struct FieldFilter {
    pub field: TypedField,
    pub values: Vec<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CmpOp {
    Gt,
    Gte,
    Lt,
    Lte,
}

impl CmpOp {
    pub fn as_str(self) -> &'static str {
        match self {
            CmpOp::Gt => "_gt",
            CmpOp::Gte => "_gte",
            CmpOp::Lt => "_lt",
            CmpOp::Lte => "_lte",
        }
    }
}

#[derive(Debug, Clone)]
pub enum Cond {
    In(Vec<Value>),
    Cmp(CmpOp, Value),
}

/// A filter evaluated client-side because the field or operator can't be pushed
/// to the Hypersync query. All conditions are AND'd together.
#[derive(Debug, Clone)]
pub struct ClientFilter {
    pub field: TypedField,
    pub conds: Vec<Cond>,
}

#[derive(Debug, Clone, Default)]
pub struct WhereFilter {
    pub from_block: Option<u64>,
    pub to_block_exclusive: Option<u64>,
    pub log_filters: Vec<FieldFilter>,
    pub transaction_filters: Vec<FieldFilter>,
    pub block_filters: Vec<FieldFilter>,
    pub client_filters: Vec<ClientFilter>,
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
                let typed_field = mapping::lookup(section, &field_raw).ok_or_else(|| {
                    let valid = mapping::valid_indexer_names(section).join(", ");
                    anyhow!("Unknown field `{section_raw}.{field_raw}` in --where. Valid: {valid}.")
                })?;
                apply_field(&mut out, section, &field_raw, typed_field, field_body)?;
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
            || !self.block_filters.is_empty()
            || !self.client_filters.is_empty()
    }

    /// Fields referenced by client-side filters. These must be fetched even when
    /// not part of the user's output selection so the predicate can be evaluated.
    pub fn client_filter_fields(&self) -> Vec<TypedField> {
        self.client_filters.iter().map(|f| f.field).collect()
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
                lf = apply_log_filter(lf, f)?;
            }
            query = query.where_logs(lf);
        }

        if !self.transaction_filters.is_empty() {
            let mut tf = TransactionFilter::all();
            for f in &self.transaction_filters {
                tf = apply_tx_filter(tf, f)?;
            }
            query = query.where_transactions(tf);
        }

        if !self.block_filters.is_empty() {
            let mut bf = BlockFilter::all();
            for f in &self.block_filters {
                bf = apply_block_filter(bf, f)?;
            }
            query = query.where_blocks(bf);
        }

        Ok(query)
    }
}

fn apply_log_filter(filter: LogFilter, f: &FieldFilter) -> Result<LogFilter> {
    use hypersync_client::net_types::log::LogField;
    let TypedField::Log(log_field) = f.field else {
        unreachable!("log_filters only holds Log fields")
    };
    let owned = filter_values_as_strs(&f.values);
    let refs: Vec<&str> = owned.iter().map(String::as_str).collect();
    let (filter, ctx) = match log_field {
        LogField::Address => (filter.and_address(refs), "invalid address"),
        LogField::Topic0 => (filter.and_topic0(refs), "invalid topic0"),
        LogField::Topic1 => (filter.and_topic1(refs), "invalid topic1"),
        LogField::Topic2 => (filter.and_topic2(refs), "invalid topic2"),
        LogField::Topic3 => (filter.and_topic3(refs), "invalid topic3"),
        _ => unreachable!("log_filters only holds server-filterable fields"),
    };
    filter.context(ctx)
}

fn apply_tx_filter(filter: TransactionFilter, f: &FieldFilter) -> Result<TransactionFilter> {
    use hypersync_client::net_types::transaction::TransactionField;
    let TypedField::Transaction(tx_field) = f.field else {
        unreachable!("transaction_filters only holds Transaction fields")
    };
    match tx_field {
        TransactionField::Status => {
            let [value] = f.values.as_slice() else {
                bail!("`transaction.status` accepts a single value server-side.");
            };
            Ok(filter.and_status(value_to_u8(value)?))
        }
        TransactionField::Type => Ok(filter.and_type(values_to_u8(&f.values)?)),
        _ => {
            let owned = filter_values_as_strs(&f.values);
            let refs: Vec<&str> = owned.iter().map(String::as_str).collect();
            let (filter, ctx) = match tx_field {
                TransactionField::From => (filter.and_from(refs), "invalid from address"),
                TransactionField::To => (filter.and_to(refs), "invalid to address"),
                TransactionField::Sighash => (filter.and_sighash(refs), "invalid sighash"),
                TransactionField::Hash => (filter.and_hash(refs), "invalid transaction hash"),
                TransactionField::ContractAddress => (
                    filter.and_contract_address(refs),
                    "invalid contract address",
                ),
                _ => unreachable!("transaction_filters only holds server-filterable fields"),
            };
            filter.context(ctx)
        }
    }
}

fn apply_block_filter(filter: BlockFilter, f: &FieldFilter) -> Result<BlockFilter> {
    use hypersync_client::net_types::block::BlockField;
    let TypedField::Block(block_field) = f.field else {
        unreachable!("block_filters only holds Block fields")
    };
    let owned = filter_values_as_strs(&f.values);
    let refs: Vec<&str> = owned.iter().map(String::as_str).collect();
    let (filter, ctx) = match block_field {
        BlockField::Hash => (filter.and_hash(refs), "invalid block hash"),
        BlockField::Miner => (filter.and_miner(refs), "invalid miner address"),
        _ => unreachable!("block_filters only holds server-filterable fields"),
    };
    filter.context(ctx)
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

fn filter_values_as_strs(values: &[Value]) -> Vec<String> {
    values
        .iter()
        .map(|v| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .collect()
}

fn apply_field(
    out: &mut WhereFilter,
    section: Section,
    indexer_name: &str,
    typed_field: TypedField,
    body: Value,
) -> Result<()> {
    use hypersync_client::net_types::block::BlockField;
    use hypersync_client::net_types::transaction::TransactionField;
    if matches!(typed_field, TypedField::Block(BlockField::Number)) {
        return apply_block_range(out, indexer_name, body);
    }

    let conds = parse_conditions(section, indexer_name, typed_field, body)?;
    let has_cmp = conds.iter().any(|c| matches!(c, Cond::Cmp(..)));
    let membership: usize = conds
        .iter()
        .map(|c| match c {
            Cond::In(v) => v.len(),
            Cond::Cmp(..) => 0,
        })
        .sum();
    // `transaction.status` maps to a single `u8` server-side, so a multi-value
    // set must fall back to client-side filtering.
    let status_multi = matches!(
        typed_field,
        TypedField::Transaction(TransactionField::Status)
    ) && membership != 1;

    if typed_field.server_filterable() && !has_cmp && !status_multi {
        let values = conds
            .into_iter()
            .flat_map(|c| match c {
                Cond::In(v) => v,
                Cond::Cmp(..) => Vec::new(),
            })
            .collect();
        let dest = match section {
            Section::Log => &mut out.log_filters,
            Section::Transaction => &mut out.transaction_filters,
            Section::Block => &mut out.block_filters,
        };
        dest.push(FieldFilter {
            field: typed_field,
            values,
        });
    } else {
        out.client_filters.push(ClientFilter {
            field: typed_field,
            conds,
        });
    }
    Ok(())
}

fn parse_conditions(
    section: Section,
    name: &str,
    field: TypedField,
    body: Value,
) -> Result<Vec<Cond>> {
    let label = || format!("{}.{name}", section.as_indexer_str());
    match body {
        Value::String(_) | Value::Number(_) | Value::Bool(_) => Ok(vec![Cond::In(vec![body])]),
        Value::Array(arr) => Ok(vec![Cond::In(arr)]),
        Value::Object(map) => {
            let mut conds = Vec::new();
            for (k, v) in map {
                let cond = match k.as_str() {
                    "_eq" => Cond::In(vec![v]),
                    "_in" => {
                        let arr = v.as_array().ok_or_else(|| {
                            anyhow!("`_in` on `{}` expects an array, got {}", label(), type_name(&v))
                        })?;
                        Cond::In(arr.clone())
                    }
                    "_gt" | "_gte" | "_lt" | "_lte" => {
                        if field.column_format() == ColumnFormat::Hex {
                            bail!(
                                "Comparison operators are not supported on hex field `{}`. Use `_eq` or `_in`.",
                                label(),
                            );
                        }
                        let op = match k.as_str() {
                            "_gt" => CmpOp::Gt,
                            "_gte" => CmpOp::Gte,
                            "_lt" => CmpOp::Lt,
                            _ => CmpOp::Lte,
                        };
                        Cond::Cmp(op, v)
                    }
                    other => bail!(
                        "Unsupported operator `{other}` on `{}`. Use a scalar, an array, `_eq`, `_in`, `_gt`, `_gte`, `_lt`, or `_lte`.",
                        label(),
                    ),
                };
                conds.push(cond);
            }
            Ok(conds)
        }
        Value::Null => bail!("`{}` cannot be null", label()),
    }
}

fn apply_block_range(out: &mut WhereFilter, field_name: &str, body: Value) -> Result<()> {
    let map = match body {
        Value::Object(m) => m,
        _ => bail!("Expected operator object under `block.{field_name}` (e.g. `_gte: 1000`).",),
    };

    for (op, val) in map {
        let n = value_to_u64(&val).with_context(|| {
            format!(
                "Operator `{op}` on `block.{field_name}` expects a non-negative integer, got {val}",
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
                "Unsupported operator `{other}` on `block.{field_name}`. Use `_gte`, `_gt`, `_lte`, `_lt`.",
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

fn value_to_u8(v: &Value) -> Result<u8> {
    match v {
        Value::Number(n) => n
            .as_u64()
            .and_then(|x| u8::try_from(x).ok())
            .ok_or_else(|| anyhow!("Expected an integer between 0 and 255, got {n}")),
        Value::String(s) => {
            let s = s.trim();
            match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
                Some(hex) => u8::from_str_radix(hex, 16),
                None => s.parse::<u8>(),
            }
            .with_context(|| format!("Expected an integer between 0 and 255, got \"{s}\""))
        }
        _ => Err(anyhow!(
            "Expected an integer between 0 and 255, got {}",
            type_name(v)
        )),
    }
}

fn values_to_u8(values: &[Value]) -> Result<Vec<u8>> {
    values.iter().map(value_to_u8).collect()
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
            (f.log_filters.len(), f.log_filters[0].field.camel_name()),
            (1, "srcAddress".to_string())
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
        insta::assert_snapshot!(err, @"`knownHeight` is not a filter — pass it as a positional field instead.");
    }

    #[test]
    fn unknown_field_errors() {
        let err = WhereFilter::parse(Some("{ log: { foo: 'x' } }"))
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @"Unknown field `log.foo` in --where. Valid: transactionHash, blockHash, blockNumber, transactionIndex, logIndex, srcAddress, data, removed, topic0, topic1, topic2, topic3.");
    }

    #[test]
    fn empty_range_errors() {
        let err = WhereFilter::parse(Some("{ block: { number: { _gte: 100, _lt: 100 } } }"))
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @"Block range is empty: from_block=100, to_block(exclusive)=100.");
    }

    #[test]
    fn malformed_input_error() {
        let err = WhereFilter::parse(Some("{ block: }"))
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @r#"Failed to parse --where. Expected JSON-like object, e.g.
--where='{ block: { number: { _gte: 1000, _lte: 2000 } }, log: { srcAddress: "0xabc" } }'"#);
    }

    #[test]
    fn transaction_filters() {
        let f = pf("{ transaction: { from: '0xa0b8', sighash: '0xdead' } }");
        assert_eq!(f.transaction_filters.len(), 2);
    }

    #[test]
    fn hash_and_contract_address_are_server_side() {
        let f = pf("{ transaction: { hash: '0xa0b8', contractAddress: '0xdead' } }");
        assert_eq!(
            (f.transaction_filters.len(), f.client_filters.len()),
            (2, 0),
        );
    }

    #[test]
    fn numeric_field_with_membership_is_client_side() {
        // `transaction.gas` has no Hypersync builder → client-side even for `_in`.
        let f = pf("{ transaction: { gas: [21000, 50000] } }");
        assert_eq!(
            (f.transaction_filters.len(), f.client_filters.len()),
            (0, 1),
        );
    }

    #[test]
    fn status_and_type_are_server_side() {
        let f = pf("{ transaction: { status: 1, type: [0, 2] } }");
        let q = f.build_net_query(FieldSelection::default()).unwrap();
        assert_eq!(
            (
                f.transaction_filters.len(),
                f.client_filters.len(),
                q.transactions.len(),
            ),
            (2, 0, 1),
        );
    }

    #[test]
    fn multi_value_status_falls_back_to_client() {
        // `and_status` takes a single value, so a set must filter client-side.
        let f = pf("{ transaction: { status: { _in: [0, 1] } } }");
        assert_eq!(
            (f.transaction_filters.len(), f.client_filters.len()),
            (0, 1),
        );
    }

    #[test]
    fn block_hash_and_miner_are_server_side() {
        let f = pf("{ block: { \
             hash: '0x1111111111111111111111111111111111111111111111111111111111111111', \
             miner: '0x2222222222222222222222222222222222222222' } }");
        let q = f.build_net_query(FieldSelection::default()).unwrap();
        assert_eq!(
            (
                f.block_filters.len(),
                f.client_filters.len(),
                q.blocks.len(),
            ),
            (2, 0, 1),
        );
    }

    #[test]
    fn other_block_field_is_client_side() {
        // `block.timestamp` has no Hypersync builder → client-side.
        let f = pf("{ block: { timestamp: { _gte: 1000 } } }");
        assert_eq!((f.block_filters.len(), f.client_filters.len()), (0, 1));
    }

    #[test]
    fn trailing_commas_and_comments() {
        let f = pf(
            "{ // comment\n  block: { number: { _gte: 100, } },\n  log: { srcAddress: '0xa', }, }",
        );
        assert_eq!((f.from_block, f.log_filters.len()), (Some(100), 1));
    }

    #[test]
    fn case_insensitive_block_range() {
        let f = pf("{ block: { NUMBER: { _gte: 500 } } }");
        assert_eq!(f.from_block, Some(500));
    }

    #[test]
    fn case_insensitive_where_fields() {
        let f = pf("{ log: { src_address: '0xa', TOPIC0: '0xb' } }");
        let names: Vec<String> = f.log_filters.iter().map(|f| f.field.camel_name()).collect();
        assert_eq!(names, vec!["srcAddress", "topic0"]);
    }
}
