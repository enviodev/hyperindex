//! subgraph.yaml -> a model the config translator and the runtime both read.
//!
//! Parsed by hand off `serde_yaml::Value` rather than through serde structs:
//! every unknown key has to be reported with its YAML path, and a project needs
//! to see all of its problems in one run, which a `deny_unknown_fields` derive
//! can't do — it stops at the first one.

use std::collections::{BTreeMap, HashSet};
use std::str::FromStr;

use serde::Serialize;
use serde_yaml::Value;

use super::errors::Report;
use crate::config_parsing::chain_helpers::Network;

/// Highest manifest version this translator understands (§1).
pub const MAX_SPEC_VERSION: (u32, u32, u32) = (1, 3, 0);
/// graph-ts versions the runtime shim implements.
pub const MIN_API_VERSION: (u32, u32, u32) = (0, 0, 5);
pub const MAX_API_VERSION: (u32, u32, u32) = (0, 0, 9);

/// Manifest `features` entries graph-node knows about. Anything else is a typo
/// or newer than us.
const KNOWN_FEATURES: &[&str] = &[
    "nonFatalErrors",
    "fullTextSearch",
    "grafting",
    "ipfsOnEthereumContracts",
    "aggregations",
    "declaredEthCalls",
    "immutableEntities",
    "bytesAsIds",
];

fn parse_version(raw: &str) -> Option<(u32, u32, u32)> {
    let mut parts = raw.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((major, minor, patch))
}

/// The Graph's network names mostly match envio's kebab-cased `Network`, but a
/// few of the oldest ones don't.
fn network_to_chain_id(network: &str) -> Option<u64> {
    match network {
        "mainnet" => Some(1),
        "matic" => Some(137),
        "poa-core" => Some(99),
        "near-mainnet" | "near-testnet" => None,
        _ => Network::from_str(network).ok().map(|n| n.get_network_id()),
    }
}

/// A YAML mapping being read, tracking which keys were consumed so the rest can
/// be reported as unknown.
struct Obj<'a> {
    map: &'a serde_yaml::Mapping,
    path: String,
    seen: HashSet<String>,
}

impl<'a> Obj<'a> {
    fn new(value: &'a Value, path: &str, report: &mut Report) -> Option<Self> {
        match value.as_mapping() {
            Some(map) => Some(Obj {
                map,
                path: path.to_string(),
                seen: HashSet::new(),
            }),
            None => {
                report.unknown(format!("the value at \"{path}\""), path.to_string());
                None
            }
        }
    }

    fn child_path(&self, key: &str) -> String {
        if self.path.is_empty() {
            key.to_string()
        } else {
            format!("{}.{}", self.path, key)
        }
    }

    fn get(&mut self, key: &str) -> Option<&'a Value> {
        self.seen.insert(key.to_string());
        self.map.get(Value::String(key.to_string()))
    }

    fn string(&mut self, key: &str) -> Option<String> {
        self.get(key)
            .and_then(|v| v.as_str().map(|s| s.to_string()))
    }

    fn u64(&mut self, key: &str) -> Option<u64> {
        self.get(key).and_then(|v| v.as_u64())
    }

    fn bool(&mut self, key: &str) -> Option<bool> {
        self.get(key).and_then(|v| v.as_bool())
    }

    fn seq(&mut self, key: &str) -> Vec<&'a Value> {
        match self.get(key).and_then(|v| v.as_sequence()) {
            Some(items) => items.iter().collect(),
            None => vec![],
        }
    }

    /// Reports every key that wasn't read. Call once per mapping, last.
    fn finish(self, report: &mut Report) {
        for (key, _) in self.map.iter() {
            let Some(key) = key.as_str() else { continue };
            if !self.seen.contains(key) {
                report.unknown(
                    format!("the manifest field \"{key}\""),
                    self.child_path(key),
                );
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DataSourceKind {
    Contract,
    FileIpfs,
    FileArweave,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BlockFilter {
    /// No `filter`: graph-node runs the handler on every block.
    Every(u64),
    /// `filter: {kind: once}` — runs a single time at the start block.
    Once,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventHandler {
    /// The signature exactly as the manifest spells it, param names optional.
    pub event: String,
    /// Event name, which is all envio needs when the ABI isn't overloaded.
    pub name: String,
    pub handler: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub receipt: bool,
    /// `topic1`/`topic2`/`topic3` values, keyed by indexed-parameter position.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub topics: BTreeMap<usize, Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockHandler {
    pub handler: String,
    pub filter: BlockFilter,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DataSource {
    pub kind: DataSourceKind,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub network: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chain_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_block: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_block: Option<u64>,
    /// Which of `abis` the `source` binds to.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abi: Option<String>,
    pub abis: BTreeMap<String, String>,
    pub api_version: String,
    pub mapping_file: String,
    pub entities: Vec<String>,
    pub event_handlers: Vec<EventHandler>,
    pub block_handlers: Vec<BlockHandler>,
    /// Templates carry no address and are instantiated by `dataSource.create`.
    pub is_template: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub spec_version: String,
    pub schema_file: String,
    pub data_sources: Vec<DataSource>,
    pub templates: Vec<DataSource>,
    /// Set by the declared-eth_calls feature or any `calls:` block: makes the
    /// RPC requirement statically known, so a missing one fails at startup.
    pub declares_eth_calls: bool,
}

impl Manifest {
    /// Every data source and template, in manifest order.
    pub fn all_sources(&self) -> impl Iterator<Item = &DataSource> {
        self.data_sources.iter().chain(self.templates.iter())
    }
}

/// Parses subgraph.yaml, collecting every unsupported/unknown finding instead of
/// stopping at the first.
pub fn parse(yaml: &str, report: &mut Report) -> Option<Manifest> {
    let value: Value = match serde_yaml::from_str(yaml) {
        Ok(value) => value,
        Err(err) => {
            report.unknown(
                format!("how to read subgraph.yaml: {err}"),
                "subgraph.yaml".to_string(),
            );
            return None;
        }
    };

    let mut root = Obj::new(&value, "", report)?;

    let spec_version = root.string("specVersion").unwrap_or_default();
    match parse_version(&spec_version) {
        Some(version) if version <= MAX_SPEC_VERSION => {}
        Some(_) => report.unknown(
            format!("the manifest specVersion \"{spec_version}\""),
            "specVersion",
        ),
        None => report.unknown(
            format!("the manifest specVersion \"{spec_version}\""),
            "specVersion",
        ),
    }

    // Descriptive only; graph-node doesn't act on them and neither do we.
    root.get("description");
    root.get("repository");

    let schema_file = match root.get("schema") {
        Some(schema) => {
            let mut schema = Obj::new(schema, "schema", report)?;
            let file = schema.string("file").unwrap_or_default();
            schema.finish(report);
            file
        }
        None => String::new(),
    };

    for (idx, feature) in root.seq("features").iter().enumerate() {
        let location = format!("features[{idx}]");
        match feature.as_str() {
            Some("nonFatalErrors") => {
                report.unsupported("the \"nonFatalErrors\" feature", location)
            }
            Some("grafting") => report.unsupported("grafting", location),
            Some("aggregations") => {
                report.unsupported("timeseries and aggregations", location)
            }
            Some(name) if KNOWN_FEATURES.contains(&name) => {}
            Some(name) => report.unknown(format!("the feature \"{name}\""), location),
            None => report.unknown("the feature entry", location),
        }
    }

    if root.get("graft").is_some() {
        report.unsupported("grafting", "graft");
    }

    // `indexerHints.prune` only tunes how much history graph-node keeps; envio
    // prunes on its own schedule, so the hint is accepted and ignored.
    if let Some(hints) = root.get("indexerHints") {
        if let Some(mut hints) = Obj::new(hints, "indexerHints", report) {
            hints.get("prune");
            hints.finish(report);
        }
    }

    let mut declares_eth_calls = false;
    let mut data_sources = Vec::new();
    for (idx, raw) in root.seq("dataSources").into_iter().enumerate() {
        if let Some(ds) = parse_data_source(
            raw,
            &format!("dataSources[{idx}]"),
            false,
            &mut declares_eth_calls,
            report,
        ) {
            data_sources.push(ds);
        }
    }

    let mut templates = Vec::new();
    for (idx, raw) in root.seq("templates").into_iter().enumerate() {
        if let Some(ds) = parse_data_source(
            raw,
            &format!("templates[{idx}]"),
            true,
            &mut declares_eth_calls,
            report,
        ) {
            templates.push(ds);
        }
    }

    root.finish(report);

    Some(Manifest {
        spec_version,
        schema_file,
        data_sources,
        templates,
        declares_eth_calls,
    })
}

fn parse_data_source(
    raw: &Value,
    path: &str,
    is_template: bool,
    declares_eth_calls: &mut bool,
    report: &mut Report,
) -> Option<DataSource> {
    let mut obj = Obj::new(raw, path, report)?;

    let name = obj.string("name").unwrap_or_else(|| path.to_string());
    let where_ = |suffix: &str| format!("data source \"{name}\" → {suffix}");

    let kind_raw = obj.string("kind").unwrap_or_default();
    let kind = match kind_raw.as_str() {
        "ethereum" | "ethereum/contract" => DataSourceKind::Contract,
        "file/ipfs" => DataSourceKind::FileIpfs,
        "file/arweave" => DataSourceKind::FileArweave,
        "substreams" => {
            report.unsupported("substreams data sources", where_("kind"));
            return None;
        }
        "subgraph" => {
            report.unsupported("subgraph composition", where_("kind"));
            return None;
        }
        other => {
            report.unknown(format!("the data source kind \"{other}\""), where_("kind"));
            return None;
        }
    };

    let network = obj.string("network");
    let chain_id = match (&network, kind) {
        (Some(network), DataSourceKind::Contract) => match network_to_chain_id(network) {
            Some(id) => Some(id),
            None => {
                report.unknown(format!("the network \"{network}\""), where_("network"));
                None
            }
        },
        _ => None,
    };

    let mut address = None;
    let mut start_block = None;
    let mut end_block = None;
    let mut abi = None;
    if let Some(source) = obj.get("source") {
        if let Some(mut source) = Obj::new(source, &format!("{path}.source"), report) {
            address = source.string("address");
            start_block = source.u64("startBlock");
            end_block = source.u64("endBlock");
            abi = source.string("abi");
            // File data sources point at a CID instead of a contract.
            source.get("file");
            source.finish(report);
        }
    }

    let mut abis = BTreeMap::new();
    let mut api_version = String::new();
    let mut mapping_file = String::new();
    let mut entities = Vec::new();
    let mut event_handlers = Vec::new();
    let mut block_handlers = Vec::new();

    if let Some(mapping) = obj.get("mapping") {
        if let Some(mut mapping) = Obj::new(mapping, &format!("{path}.mapping"), report) {
            match mapping.string("kind").as_deref() {
                Some("ethereum/events") | Some("ethereum/contract") | Some("ethereum") | None => {}
                Some(other) => report.unknown(
                    format!("the mapping kind \"{other}\""),
                    where_("mapping → kind"),
                ),
            }
            match mapping.string("language").as_deref() {
                Some("wasm/assemblyscript") | None => {}
                Some(other) => report.unknown(
                    format!("the mapping language \"{other}\""),
                    where_("mapping → language"),
                ),
            }

            api_version = mapping.string("apiVersion").unwrap_or_default();
            match parse_version(&api_version) {
                Some(version) if version > MAX_API_VERSION => report.unknown(
                    format!("the graph-ts apiVersion \"{api_version}\""),
                    where_("mapping → apiVersion"),
                ),
                Some(version) if version < MIN_API_VERSION => report.unsupported(
                    format!("graph-ts apiVersion \"{api_version}\" (0.0.5 is the oldest supported)"),
                    where_("mapping → apiVersion"),
                ),
                Some(_) => {}
                None => report.unknown(
                    format!("the graph-ts apiVersion \"{api_version}\""),
                    where_("mapping → apiVersion"),
                ),
            }

            mapping_file = mapping.string("file").unwrap_or_default();
            entities = mapping
                .seq("entities")
                .iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect();

            for (idx, raw) in mapping.seq("abis").into_iter().enumerate() {
                if let Some(mut abi_obj) =
                    Obj::new(raw, &format!("{path}.mapping.abis[{idx}]"), report)
                {
                    let abi_name = abi_obj.string("name").unwrap_or_default();
                    let abi_file = abi_obj.string("file").unwrap_or_default();
                    abi_obj.finish(report);
                    abis.insert(abi_name, abi_file);
                }
            }

            for (idx, raw) in mapping.seq("eventHandlers").into_iter().enumerate() {
                if let Some(handler) = parse_event_handler(
                    raw,
                    &format!("{path}.mapping.eventHandlers[{idx}]"),
                    &name,
                    declares_eth_calls,
                    report,
                ) {
                    event_handlers.push(handler);
                }
            }

            for (idx, raw) in mapping.seq("blockHandlers").into_iter().enumerate() {
                if let Some(handler) = parse_block_handler(
                    raw,
                    &format!("{path}.mapping.blockHandlers[{idx}]"),
                    &name,
                    report,
                ) {
                    block_handlers.push(handler);
                }
            }

            for (idx, raw) in mapping.seq("callHandlers").into_iter().enumerate() {
                let handler = raw
                    .as_mapping()
                    .and_then(|m| m.get(Value::String("handler".into())))
                    .and_then(|v| v.as_str())
                    .map(|s| format!(" → \"{s}\""))
                    .unwrap_or_else(|| format!("[{idx}]"));
                report.unsupported(
                    "call handlers",
                    format!("data source \"{name}\" → callHandlers{handler}"),
                );
            }

            for (idx, raw) in mapping.seq("entityHandlers").into_iter().enumerate() {
                let _ = raw;
                report.unsupported(
                    "subgraph composition",
                    format!("data source \"{name}\" → entityHandlers[{idx}]"),
                );
            }

            // File data sources declare a single `handler` instead of a list.
            if let Some(handler) = mapping.string("handler") {
                event_handlers.push(EventHandler {
                    event: String::new(),
                    name: String::new(),
                    handler,
                    receipt: false,
                    topics: BTreeMap::new(),
                });
            }

            mapping.finish(report);
        }
    }

    if matches!(kind, DataSourceKind::FileIpfs | DataSourceKind::FileArweave) {
        report.unsupported(
            "file data sources",
            format!("data source \"{name}\" → kind: {kind_raw}"),
        );
    }

    obj.finish(report);

    Some(DataSource {
        kind,
        name,
        network,
        chain_id,
        address,
        start_block,
        end_block,
        abi,
        abis,
        api_version,
        mapping_file,
        entities,
        event_handlers,
        block_handlers,
        is_template,
    })
}

fn parse_event_handler(
    raw: &Value,
    path: &str,
    data_source: &str,
    declares_eth_calls: &mut bool,
    report: &mut Report,
) -> Option<EventHandler> {
    let mut obj = Obj::new(raw, path, report)?;

    let event = obj.string("event").unwrap_or_default();
    let handler = obj.string("handler").unwrap_or_default();
    let receipt = obj.bool("receipt").unwrap_or(false);

    let mut topics = BTreeMap::new();
    for position in 1..=3usize {
        let key = format!("topic{position}");
        if let Some(value) = obj.get(&key) {
            let values: Vec<String> = match value {
                Value::Sequence(items) => items
                    .iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect(),
                other => other.as_str().map(|s| vec![s.to_string()]).unwrap_or_default(),
            };
            if !values.is_empty() {
                topics.insert(position, values);
            }
        }
    }

    if obj.get("calls").is_some() {
        *declares_eth_calls = true;
    }

    obj.finish(report);

    let name = event
        .split('(')
        .next()
        .unwrap_or_default()
        .trim()
        .to_string();

    if name.is_empty() {
        report.unknown(
            "the event handler without an event signature",
            format!("data source \"{data_source}\" → eventHandlers → \"{handler}\""),
        );
        return None;
    }

    Some(EventHandler {
        event,
        name,
        handler,
        receipt,
        topics,
    })
}

fn parse_block_handler(
    raw: &Value,
    path: &str,
    data_source: &str,
    report: &mut Report,
) -> Option<BlockHandler> {
    let mut obj = Obj::new(raw, path, report)?;
    let handler = obj.string("handler").unwrap_or_default();
    let where_ = format!("data source \"{data_source}\" → blockHandlers → \"{handler}\"");

    let mut filter = BlockFilter::Every(1);
    if let Some(raw_filter) = obj.get("filter") {
        if let Some(mut filter_obj) = Obj::new(raw_filter, &format!("{path}.filter"), report) {
            let kind = filter_obj.string("kind").unwrap_or_default();
            let every = filter_obj.u64("every");
            match kind.as_str() {
                "call" => {
                    report.unsupported("block handlers with `filter: call`", where_.clone());
                }
                "polling" => filter = BlockFilter::Every(every.unwrap_or(1).max(1)),
                "once" => filter = BlockFilter::Once,
                other => report.unknown(
                    format!("the block handler filter kind \"{other}\""),
                    where_.clone(),
                ),
            }
            filter_obj.finish(report);
        }
    }

    obj.finish(report);

    Some(BlockHandler { handler, filter })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_ok(yaml: &str) -> (Option<Manifest>, Report) {
        let mut report = Report::new();
        let manifest = parse(yaml, &mut report);
        (manifest, report)
    }

    const GRAVITY: &str = r#"
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Gravity
    network: mainnet
    source:
      address: "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"
      abi: Gravity
      startBlock: 6175244
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Gravatar
      abis:
        - name: Gravity
          file: ./abis/Gravity.json
      eventHandlers:
        - event: NewGravatar(uint256,address,string,string)
          handler: handleNewGravatar
      blockHandlers:
        - handler: handleBlock
          filter:
            kind: polling
            every: 10
      file: ./src/gravity.ts
templates:
  - kind: ethereum/contract
    name: Exchange
    network: mainnet
    source:
      abi: Exchange
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis:
        - name: Exchange
          file: ./abis/Exchange.json
      eventHandlers:
        - event: Swap(indexed address,uint256)
          handler: handleSwap
      file: ./src/exchange.ts
"#;

    #[test]
    fn parses_a_manifest_with_a_template() {
        let (manifest, report) = parse_ok(GRAVITY);
        let manifest = manifest.unwrap();
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            (
                manifest.spec_version.as_str(),
                manifest.schema_file.as_str(),
                manifest.data_sources.len(),
                manifest.data_sources[0].chain_id,
                manifest.data_sources[0].start_block,
                manifest.data_sources[0].event_handlers[0].name.as_str(),
                manifest.data_sources[0].block_handlers[0].filter.clone(),
                manifest.templates[0].name.as_str(),
                manifest.templates[0].is_template,
                manifest.templates[0].address.clone(),
            ),
            (
                "0.0.5",
                "./schema.graphql",
                1,
                Some(1),
                Some(6175244),
                "NewGravatar",
                BlockFilter::Every(10),
                "Exchange",
                true,
                None,
            )
        );
    }

    #[test]
    fn reports_every_unsupported_feature_at_once() {
        let yaml = r#"
specVersion: 1.3.0
schema:
  file: ./schema.graphql
features:
  - nonFatalErrors
graft:
  base: QmBase
  block: 100
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1"
      abi: Token
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
      callHandlers:
        - function: approve(address,uint256)
          handler: handleApprove
      blockHandlers:
        - handler: handleBlockCall
          filter:
            kind: call
      file: ./src/token.ts
"#;
        let (_, report) = parse_ok(yaml);
        let rendered = report.to_string();
        assert_eq!(
            (
                report.findings().len(),
                rendered.contains("doesn't support the \"nonFatalErrors\" feature"),
                rendered.contains("doesn't support grafting"),
                rendered.contains("doesn't support call handlers"),
                rendered.contains("doesn't support block handlers with `filter: call`"),
                rendered.contains("data source \"Token\" → callHandlers → \"handleApprove\""),
            ),
            (4, true, true, true, true, true)
        );
    }

    #[test]
    fn rejects_unknown_fields_and_versions() {
        let yaml = r#"
specVersion: 9.9.9
schema:
  file: ./schema.graphql
speVersion: oops
dataSources:
  - kind: ethereum/teapot
    name: Token
    network: mainnet
"#;
        let (_, report) = parse_ok(yaml);
        let rendered = report.to_string();
        assert_eq!(
            (
                report.findings().len(),
                rendered.contains("doesn't know the manifest specVersion \"9.9.9\""),
                rendered.contains("doesn't know the manifest field \"speVersion\""),
                rendered.contains("doesn't know the data source kind \"ethereum/teapot\""),
            ),
            (3, true, true, true)
        );
    }

    #[test]
    fn rejects_a_too_new_api_version() {
        let yaml = r#"
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1"
      abi: Token
    mapping:
      kind: ethereum/events
      apiVersion: 0.1.0
      language: wasm/assemblyscript
      entities: []
      abis: []
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
      file: ./src/token.ts
"#;
        let (_, report) = parse_ok(yaml);
        assert!(
            report
                .to_string()
                .contains("doesn't know the graph-ts apiVersion \"0.1.0\""),
            "{report}"
        );
    }

    #[test]
    fn records_declared_eth_calls_and_topic_filters() {
        let yaml = r#"
specVersion: 1.2.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1"
      abi: Token
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
          receipt: true
          topic1:
            - "0x0000000000000000000000000000000000000000000000000000000000000001"
          calls:
            balance: Token[event.address].balanceOf(event.params.to)
      file: ./src/token.ts
"#;
        let (manifest, report) = parse_ok(yaml);
        let manifest = manifest.unwrap();
        let handler = &manifest.data_sources[0].event_handlers[0];
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            (
                manifest.declares_eth_calls,
                handler.receipt,
                handler.topics.get(&1).cloned(),
            ),
            (
                true,
                true,
                Some(vec![
                    "0x0000000000000000000000000000000000000000000000000000000000000001"
                        .to_string()
                ])
            )
        );
    }
}
