use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

use hypersync_client::net_types::{
    BlockFilter, FieldSelection, LogFilter, Query, TransactionFilter,
};

use super::mapping::{self, Section, ServerFilter, TypedField, ValueKind};

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
    pub server_filters: Vec<FieldFilter>,
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
        !self.server_filters.is_empty() || !self.client_filters.is_empty()
    }

    /// Which sections carry a row-level filter (server or client), indexed by
    /// `Section::index`. A pure `block.number` range desugars to the scan window
    /// and leaves no filter, so it does not mark the block section; a
    /// `block.number` set (`_in`) keeps a client filter and does.
    pub fn filtered_sections(&self) -> [bool; 3] {
        let mut sections = [false; 3];
        for section in self
            .server_filters
            .iter()
            .map(|f| f.field.section())
            .chain(self.client_filters.iter().map(|f| f.field.section()))
        {
            sections[section.index()] = true;
        }
        sections
    }

    fn narrow_from(&mut self, n: u64) {
        self.from_block = Some(self.from_block.map_or(n, |cur| cur.max(n)));
    }

    fn narrow_to_excl(&mut self, n: u64) {
        self.to_block_exclusive = Some(self.to_block_exclusive.map_or(n, |cur| cur.min(n)));
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

        let wants_log_fields = !field_selection.log.is_empty();
        let wants_tx_fields = !field_selection.transaction.is_empty();
        let wants_block_fields = !field_selection.block.is_empty();

        query.field_selection = field_selection;

        let mut logs = LogFilter::all();
        let mut transactions = TransactionFilter::all();
        let mut blocks = BlockFilter::all();
        let (mut has_log, mut has_tx, mut has_block) = (false, false, false);
        for f in &self.server_filters {
            match f.field.section() {
                Section::Log => {
                    logs = apply_log_filter(logs, f)?;
                    has_log = true;
                }
                Section::Transaction => {
                    transactions = apply_tx_filter(transactions, f)?;
                    has_tx = true;
                }
                Section::Block => {
                    blocks = apply_block_filter(blocks, f)?;
                    has_block = true;
                }
            }
        }

        // HyperSync returns only rows that match a selection, so request one for
        // every entity the user wants data for. Without a filter the `all()`
        // selection matches every row of that kind.
        if has_log || wants_log_fields {
            query = query.where_logs(logs);
        }
        if has_tx || wants_tx_fields {
            query = query.where_transactions(transactions);
        }
        if has_block {
            query = query.where_blocks(blocks);
        }

        // Block headers are otherwise returned only for blocks joined to a
        // matching log/transaction/block filter. When block fields are wanted but
        // no filter scopes the blocks, ask the server for every block in the range.
        if wants_block_fields && !has_log && !has_tx && !has_block {
            query = query.include_all_blocks();
        }

        Ok(query)
    }
}

fn server_tag(field: TypedField) -> ServerFilter {
    field
        .spec()
        .server
        .expect("server_filters only holds server-filterable fields")
}

fn str_refs(values: &[String]) -> Vec<&str> {
    values.iter().map(String::as_str).collect()
}

fn apply_log_filter(filter: LogFilter, f: &FieldFilter) -> Result<LogFilter> {
    let owned = filter_values_as_strs(&f.values);
    let refs = str_refs(&owned);
    let (filter, ctx) = match server_tag(f.field) {
        ServerFilter::LogAddress => (filter.and_address(refs), "invalid address"),
        ServerFilter::LogTopic0 => (filter.and_topic0(refs), "invalid topic0"),
        ServerFilter::LogTopic1 => (filter.and_topic1(refs), "invalid topic1"),
        ServerFilter::LogTopic2 => (filter.and_topic2(refs), "invalid topic2"),
        ServerFilter::LogTopic3 => (filter.and_topic3(refs), "invalid topic3"),
        _ => unreachable!("non-log server tag in log section"),
    };
    filter.context(ctx)
}

fn apply_tx_filter(filter: TransactionFilter, f: &FieldFilter) -> Result<TransactionFilter> {
    match server_tag(f.field) {
        ServerFilter::TxStatus => {
            let [value] = f.values.as_slice() else {
                bail!("`transaction.status` accepts a single value server-side.");
            };
            Ok(filter.and_status(value_to_u8(value)?))
        }
        ServerFilter::TxType => Ok(filter.and_type(values_to_u8(&f.values)?)),
        tag => {
            let owned = filter_values_as_strs(&f.values);
            let refs = str_refs(&owned);
            let (filter, ctx) = match tag {
                ServerFilter::TxFrom => (filter.and_from(refs), "invalid from address"),
                ServerFilter::TxTo => (filter.and_to(refs), "invalid to address"),
                ServerFilter::TxSighash => (filter.and_sighash(refs), "invalid sighash"),
                ServerFilter::TxHash => (filter.and_hash(refs), "invalid transaction hash"),
                ServerFilter::TxContractAddress => (
                    filter.and_contract_address(refs),
                    "invalid contract address",
                ),
                _ => unreachable!("non-transaction server tag in transaction section"),
            };
            filter.context(ctx)
        }
    }
}

fn apply_block_filter(filter: BlockFilter, f: &FieldFilter) -> Result<BlockFilter> {
    let owned = filter_values_as_strs(&f.values);
    let refs = str_refs(&owned);
    let (filter, ctx) = match server_tag(f.field) {
        ServerFilter::BlockHash => (filter.and_hash(refs), "invalid block hash"),
        ServerFilter::BlockMiner => (filter.and_miner(refs), "invalid miner address"),
        _ => unreachable!("non-block server tag in block section"),
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
    if matches!(typed_field, TypedField::Block(BlockField::Number)) {
        return apply_block_number(out, typed_field, body);
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
    let server = typed_field.spec().server;
    let status_multi = server == Some(ServerFilter::TxStatus) && membership != 1;

    if server.is_some() && !has_cmp && !status_multi {
        let values = conds
            .into_iter()
            .flat_map(|c| match c {
                Cond::In(v) => v,
                Cond::Cmp(..) => Vec::new(),
            })
            .collect();
        out.server_filters.push(FieldFilter {
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
                        if field.spec().value_kind != ValueKind::Numeric {
                            bail!(
                                "Comparison operators are only supported on numeric fields; `{}` is not numeric. Use `_eq` or `_in`.",
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

/// `block.number` scopes the scan window rather than mapping to a row filter, so
/// it desugars to `from_block`/`to_block`. A scalar or `_eq` pins a single block;
/// an array or `_in` scans `[min, max]` and drops the rest with a client filter.
fn apply_block_number(out: &mut WhereFilter, field: TypedField, body: Value) -> Result<()> {
    let to_block = |v: &Value| {
        value_to_u64(v)
            .with_context(|| format!("`block.number` expects a non-negative integer, got {v}"))
    };
    for cond in parse_conditions(Section::Block, "number", field, body)? {
        match cond {
            Cond::Cmp(op, v) => {
                let n = to_block(&v)?;
                match op {
                    CmpOp::Gte => out.narrow_from(n),
                    CmpOp::Gt => out.narrow_from(n.saturating_add(1)),
                    CmpOp::Lte => out.narrow_to_excl(n.saturating_add(1)),
                    CmpOp::Lt => out.narrow_to_excl(n),
                }
            }
            Cond::In(vals) => {
                let nums = vals.iter().map(to_block).collect::<Result<Vec<_>>>()?;
                match (nums.iter().min(), nums.iter().max()) {
                    (Some(&min), Some(&max)) => {
                        out.narrow_from(min);
                        out.narrow_to_excl(max.saturating_add(1));
                        // A single value is already an exact range; only a set
                        // needs the leftover blocks dropped client-side.
                        if nums.len() > 1 {
                            out.client_filters.push(ClientFilter {
                                field,
                                conds: vec![Cond::In(vals)],
                            });
                        }
                    }
                    // Empty `_in` matches no block; the client filter drops all rows.
                    _ => out.client_filters.push(ClientFilter {
                        field,
                        conds: vec![Cond::In(vals)],
                    }),
                }
            }
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
            (
                f.server_filters.len(),
                f.server_filters[0].field.camel_name()
            ),
            (1, "srcAddress".to_string())
        );
    }

    #[test]
    fn gt_and_lt_off_by_one() {
        let f = pf("{ block: { number: { _gt: 100, _lt: 200 } } }");
        assert_eq!((f.from_block, f.to_block_exclusive), (Some(101), Some(200)));
    }

    #[test]
    fn block_number_eq_pins_single_block() {
        let f = pf("{ block: { number: { _eq: 100 } } }");
        assert_eq!(
            (f.from_block, f.to_block_exclusive, f.client_filters.len()),
            (Some(100), Some(101), 0),
        );
    }

    #[test]
    fn block_number_scalar_shorthand_pins_single_block() {
        let f = pf("{ block: { number: 100 } }");
        assert_eq!(
            (f.from_block, f.to_block_exclusive, f.client_filters.len()),
            (Some(100), Some(101), 0),
        );
    }

    #[test]
    fn block_number_in_scans_range_and_filters_rest_client_side() {
        let f = pf("{ block: { number: { _in: [100, 50, 200] } } }");
        assert_eq!(
            (
                f.from_block,
                f.to_block_exclusive,
                f.client_filters.len(),
                f.client_filters[0].field.camel_name(),
            ),
            (Some(50), Some(201), 1, "number".to_string()),
        );
    }

    #[test]
    fn block_number_array_shorthand_matches_in() {
        let f = pf("{ block: { number: [100, 50, 200] } }");
        assert_eq!(
            (f.from_block, f.to_block_exclusive, f.client_filters.len()),
            (Some(50), Some(201), 1),
        );
    }

    #[test]
    fn block_number_single_element_in_needs_no_client_filter() {
        let f = pf("{ block: { number: { _in: [42] } } }");
        assert_eq!(
            (f.from_block, f.to_block_exclusive, f.client_filters.len()),
            (Some(42), Some(43), 0),
        );
    }

    #[test]
    fn block_number_in_builds_full_block_scan_over_range() {
        use hypersync_client::net_types::block::BlockField;
        let mut fs = FieldSelection::default();
        fs.block.insert(BlockField::Number);
        let q = pf("{ block: { number: { _in: [10, 12] } } }")
            .build_net_query(fs)
            .unwrap();
        assert_eq!(
            (q.from_block, q.to_block, q.include_all_blocks),
            (10, Some(13), true),
        );
    }

    #[test]
    fn block_number_unsupported_operator_errors() {
        let err = WhereFilter::parse(Some("{ block: { number: { _like: 5 } } }"))
            .unwrap_err()
            .to_string();
        insta::assert_snapshot!(err, @"Unsupported operator `_like` on `block.number`. Use a scalar, an array, `_eq`, `_in`, `_gt`, `_gte`, `_lt`, or `_lte`.");
    }

    #[test]
    fn empty_where_defaults() {
        let f = WhereFilter::parse(None).unwrap();
        let q = f.build_net_query(FieldSelection::default()).unwrap();
        assert_eq!((q.from_block, q.to_block), (0, None));
    }

    #[test]
    fn block_only_selection_requests_all_blocks() {
        use hypersync_client::net_types::block::BlockField;
        let mut fs = FieldSelection::default();
        fs.block.insert(BlockField::Hash);
        let q = WhereFilter::parse(None)
            .unwrap()
            .build_net_query(fs)
            .unwrap();
        assert_eq!(
            (
                q.include_all_blocks,
                q.blocks.len(),
                q.logs.len(),
                q.transactions.len(),
            ),
            (true, 0, 0, 0),
        );
    }

    #[test]
    fn log_only_selection_requests_all_logs() {
        use hypersync_client::net_types::log::LogField;
        let mut fs = FieldSelection::default();
        fs.log.insert(LogField::Data);
        let q = WhereFilter::parse(None)
            .unwrap()
            .build_net_query(fs)
            .unwrap();
        assert_eq!(
            (q.include_all_blocks, q.logs.len(), q.transactions.len()),
            (false, 1, 0),
        );
    }

    #[test]
    fn transaction_only_selection_requests_all_transactions() {
        use hypersync_client::net_types::transaction::TransactionField;
        let mut fs = FieldSelection::default();
        fs.transaction.insert(TransactionField::Hash);
        let q = WhereFilter::parse(None)
            .unwrap()
            .build_net_query(fs)
            .unwrap();
        assert_eq!(
            (q.include_all_blocks, q.transactions.len(), q.logs.len()),
            (false, 1, 0),
        );
    }

    #[test]
    fn block_fields_scoped_by_log_filter_skip_all_blocks() {
        use hypersync_client::net_types::block::BlockField;
        let mut fs = FieldSelection::default();
        fs.block.insert(BlockField::Hash);
        let q = pf("{ log: { srcAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7' } }")
            .build_net_query(fs)
            .unwrap();
        assert_eq!((q.include_all_blocks, q.logs.len()), (false, 1));
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
        assert_eq!(f.server_filters.len(), 2);
    }

    #[test]
    fn hash_and_contract_address_are_server_side() {
        let f = pf("{ transaction: { hash: '0xa0b8', contractAddress: '0xdead' } }");
        assert_eq!((f.server_filters.len(), f.client_filters.len()), (2, 0));
    }

    #[test]
    fn numeric_field_with_membership_is_client_side() {
        // `transaction.gas` has no Hypersync builder → client-side even for `_in`.
        let f = pf("{ transaction: { gas: [21000, 50000] } }");
        assert_eq!((f.server_filters.len(), f.client_filters.len()), (0, 1));
    }

    #[test]
    fn status_and_type_are_server_side() {
        let f = pf("{ transaction: { status: 1, type: [0, 2] } }");
        let q = f.build_net_query(FieldSelection::default()).unwrap();
        assert_eq!(
            (
                f.server_filters.len(),
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
        assert_eq!((f.server_filters.len(), f.client_filters.len()), (0, 1));
    }

    #[test]
    fn block_hash_and_miner_are_server_side() {
        let f = pf("{ block: { \
             hash: '0x1111111111111111111111111111111111111111111111111111111111111111', \
             miner: '0x2222222222222222222222222222222222222222' } }");
        let q = f.build_net_query(FieldSelection::default()).unwrap();
        assert_eq!(
            (
                f.server_filters.len(),
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
        assert_eq!((f.server_filters.len(), f.client_filters.len()), (0, 1));
    }

    #[test]
    fn trailing_commas_and_comments() {
        let f = pf(
            "{ // comment\n  block: { number: { _gte: 100, } },\n  log: { srcAddress: '0xa', }, }",
        );
        assert_eq!((f.from_block, f.server_filters.len()), (Some(100), 1));
    }

    #[test]
    fn case_insensitive_block_range() {
        let f = pf("{ block: { NUMBER: { _gte: 500 } } }");
        assert_eq!(f.from_block, Some(500));
    }

    #[test]
    fn case_insensitive_where_fields() {
        let f = pf("{ log: { src_address: '0xa', TOPIC0: '0xb' } }");
        let names: Vec<String> = f
            .server_filters
            .iter()
            .map(|f| f.field.camel_name())
            .collect();
        assert_eq!(names, vec!["srcAddress", "topic0"]);
    }
}
