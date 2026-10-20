//! subgraph.yaml -> a model the config translator and the runtime both read.
//!
//! Parsed by hand off `serde_yaml::Value` rather than through serde structs:
//! every unknown key has to be reported with its YAML path, and a project needs
//! to see all of its problems in one run, which a `deny_unknown_fields` derive
//! can't do — it stops at the first one.

use std::collections::{BTreeMap, HashSet};
use std::str::FromStr;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use serde_yaml::Value;

use super::errors::{Finding, Report};
use crate::config_parsing::chain_helpers::Network;

/// Highest manifest version this translator understands (§1).
pub const MAX_SPEC_VERSION: (u32, u32, u32) = (1, 3, 0);
/// The newest graph-ts the runtime shim implements. There is no floor: older
/// versions expose a subset of the same API, and anything genuinely missing from
/// one is refused by name when the mapping reaches for it.
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

/// Networks The Graph indexes that aren't EVM chains at all. Recognising them
/// by name is what turns "unknown network" into an answer.
const NON_EVM_NETWORKS: &[(&str, &str)] = &[
    ("near-mainnet", "NEAR"),
    ("near-testnet", "NEAR"),
    ("cosmoshub-4", "Cosmos"),
    ("osmosis-1", "Cosmos"),
    ("injective-mainnet", "Cosmos"),
    ("arweave-mainnet", "Arweave"),
    ("starknet-mainnet", "Starknet"),
    ("starknet-testnet", "Starknet"),
    ("solana-mainnet-beta", "Solana"),
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GraphRegistryNetwork {
    chain_id: u64,
    aliases: Vec<String>,
}

/// The EVM networks of The Graph's networks registry, by id: the names a
/// subgraph.yaml's `network:` uses. `scripts/sync-graph-networks.mjs` refreshes
/// the snapshot, and CI runs it to report drift.
static GRAPH_NETWORKS: LazyLock<BTreeMap<String, GraphRegistryNetwork>> = LazyLock::new(|| {
    serde_json::from_str(include_str!("graph_networks.json"))
        .expect("graph_networks.json is the sync script's output")
});

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostNetwork {
    name: String,
    chain_id: u64,
}

/// Network slugs other hosts accept in `subgraph.yaml` that the Graph
/// registry doesn't list, with the chain id each stands for. Chain
/// ids were cross-checked against chainlist and, where dRPC serves the chain,
/// its `eth_chainId`.
static HOST_NETWORKS: LazyLock<BTreeMap<String, u64>> = LazyLock::new(|| {
    serde_json::from_str::<Vec<HostNetwork>>(include_str!("host_networks.json"))
        .expect("host_networks.json is valid")
        .into_iter()
        .map(|network| (network.name, network.chain_id))
        .collect()
});

/// The registry's id or one of its aliases first, then the slugs other hosts
/// use, then Envio's kebab-case so `hyperliquid` still works when someone
/// writes our name. A chain id Envio has no name for is fine: it indexes over
/// `ENVIO_SUBGRAPH_RPC` when HyperSync doesn't serve it.
fn network_to_chain_id(network: &str) -> Option<u64> {
    let registered = GRAPH_NETWORKS.iter().find(|(id, registered)| {
        *id == network || registered.aliases.iter().any(|alias| alias == network)
    });
    if let Some((_, registered)) = registered {
        return Some(registered.chain_id);
    }
    if let Some(chain_id) = HOST_NETWORKS.get(network) {
        return Some(*chain_id);
    }
    // The registry spells every chain `evm-<chain id>` too; for a chain it
    // doesn't list, that is a way to name one without a slug.
    if let Some(chain_id) = network
        .strip_prefix("evm-")
        .and_then(|id| id.parse::<u64>().ok())
        .filter(|id| *id > 0)
    {
        return Some(chain_id);
    }
    Network::from_str(network).ok().map(|n| n.get_network_id())
}

/// The chains the network names no table knows were resolved to — by asking
/// the RPC endpoint, or by the name they spell — or why asking failed.
pub type NetworksFromRpc = BTreeMap<String, Result<u64, String>>;

/// The known network a name spells in another case or with other separators
/// (`hyperEVM`, `base_sepolia`, `baseSepolia`), with its chain id.
pub fn network_spelled(network: &str) -> Option<(String, u64)> {
    let mut kebab = String::new();
    let mut previous: Option<char> = None;
    for c in network.chars() {
        if c.is_ascii_uppercase()
            && previous.is_some_and(|p| p.is_ascii_lowercase() || p.is_ascii_digit())
        {
            kebab.push('-');
        }
        kebab.push(if c == '_' {
            '-'
        } else {
            c.to_ascii_lowercase()
        });
        previous = Some(c);
    }
    // `hyperEVM` is `hyperevm`, not `hyper-evm`; try the plain lowercase first.
    [network.to_ascii_lowercase().replace('_', "-"), kebab]
        .into_iter()
        .filter(|candidate| candidate != network)
        .find_map(|candidate| network_to_chain_id(&candidate).map(|id| (candidate, id)))
}

/// The `network:` values of the manifest's chain data sources and templates
/// that neither the tables nor the non-EVM list know.
pub fn unknown_networks(yaml: &str) -> Vec<String> {
    let Ok(value) = serde_yaml::from_str::<Value>(yaml) else {
        return vec![];
    };
    let mut names = Vec::new();
    for key in ["dataSources", "templates"] {
        let Some(sources) = value.get(key).and_then(Value::as_sequence) else {
            continue;
        };
        for source in sources {
            let is_chain = matches!(
                source.get("kind").and_then(Value::as_str),
                Some("ethereum" | "ethereum/contract")
            );
            let Some(network) = source.get("network").and_then(Value::as_str) else {
                continue;
            };
            if is_chain
                && network_to_chain_id(network).is_none()
                && !NON_EVM_NETWORKS.iter().any(|(name, _)| *name == network)
                && !names.iter().any(|name| name == network)
            {
                names.push(network.to_string());
            }
        }
    }
    names
}

/// A YAML mapping being read, tracking which keys were consumed so the rest can
/// be reported as unknown.
struct Obj<'a> {
    map: &'a serde_yaml::Mapping,
    path: String,
    seen: HashSet<String>,
    /// Keys that are present but hold another YAML type, with what was
    /// expected. Reading one answers `None`, and the key counts as consumed —
    /// so without this the field would be neither applied nor reported.
    /// `address: 0x1` unquoted is the case that bites: serde_yaml reads an
    /// integer, and the contract silently loses its address.
    mistyped: Vec<(String, &'static str)>,
}

impl<'a> Obj<'a> {
    fn new(value: &'a Value, path: &str, report: &mut Report) -> Option<Self> {
        match value.as_mapping() {
            Some(map) => Some(Obj {
                map,
                path: path.to_string(),
                seen: HashSet::new(),
                mistyped: Vec::new(),
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

    /// Reads `key` as one YAML type, noting a mismatch for `finish` to report.
    fn typed<T>(
        &mut self,
        key: &str,
        expected: &'static str,
        read: impl Fn(&'a Value) -> Option<T>,
    ) -> Option<T> {
        let value = self.get(key)?;
        match read(value) {
            Some(read) => Some(read),
            None => {
                self.mistyped.push((key.to_string(), expected));
                None
            }
        }
    }

    fn string(&mut self, key: &str) -> Option<String> {
        self.typed(key, "a string", |v| v.as_str().map(|s| s.to_string()))
    }

    fn u64(&mut self, key: &str) -> Option<u64> {
        self.typed(key, "a number", Value::as_u64)
    }

    fn bool(&mut self, key: &str) -> Option<bool> {
        self.typed(key, "a boolean", Value::as_bool)
    }

    fn seq(&mut self, key: &str) -> Vec<&'a Value> {
        match self.typed(key, "a list", Value::as_sequence) {
            Some(items) => items.iter().collect(),
            None => vec![],
        }
    }

    fn keys(&self) -> Vec<String> {
        self.map
            .iter()
            .filter_map(|(key, _)| key.as_str().map(|key| key.to_string()))
            .collect()
    }

    /// Reports every key that wasn't read. Call once per mapping, last.
    fn finish(self, report: &mut Report) {
        for (key, expected) in &self.mistyped {
            report.unknown(
                format!("the value of \"{key}\", which has to be {expected}"),
                self.child_path(key),
            );
        }
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

impl DataSourceKind {
    /// A `file/ipfs` or `file/arweave` data source: no chain, no contract.
    pub fn is_file(self) -> bool {
        matches!(self, Self::FileIpfs | Self::FileArweave)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BlockFilter {
    /// No `filter`: graph-node runs the handler on every block.
    Every(u64),
    /// `filter: {kind: once}` — runs a single time at the start block.
    Once,
    /// `filter: {kind: call}` — runs once per call to the data source's address
    /// (any function, internal calls included) in a block that has one.
    Call,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventHandler {
    /// The signature exactly as the manifest spells it, param names optional.
    pub event: String,
    /// The name the runtime registers this handler under. Equal to the event
    /// name unless the ABI overloads it, when later overloads are suffixed so
    /// envio's routing can tell them apart.
    pub name: String,
    pub handler: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub receipt: bool,
    /// `topic1`/`topic2`/`topic3` values, keyed by indexed-parameter position.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub topics: BTreeMap<usize, Vec<String>>,
    /// The event's parameters in ABI order, which is what `event.parameters`
    /// indexes by. The manifest's own signature carries types without names,
    /// so this is filled in from the ABI.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub inputs: Vec<EventInput>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventInput {
    /// As the ABI spells it, empty when the ABI left it unnamed.
    pub name: String,
    /// What envio decodes it under: the name, or `_{index}` when there is none.
    pub key: String,
    #[serde(rename = "type")]
    pub abi_type: String,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub indexed: bool,
}

impl EventInput {
    /// Indexed as the keccak hash of its encoding, which can't be read back.
    pub fn is_hashed_in_topic(&self) -> bool {
        self.abi_type == "string"
            || self.abi_type == "bytes"
            || self.abi_type.ends_with(']')
            || self.abi_type.starts_with('(')
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockHandler {
    pub handler: String,
    pub filter: BlockFilter,
    /// The name of the call trigger that carries a `filter: call` handler;
    /// minted by the translator, empty for every other filter.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub call_event: String,
}

/// One `callHandlers` entry: the handler runs for a successful call to the data
/// source's address whose input starts with the function's 4-byte selector.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallHandler {
    /// The function signature exactly as the manifest spells it. graph-node
    /// takes the selector from the keccak of this text, as written.
    pub function: String,
    pub handler: String,
    /// The name the runtime registers the handler under: the call trigger the
    /// translator minted for it, which carries the call through envio's fetch.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    /// The function's parameters in ABI order, filled in from the ABI.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub inputs: Vec<CallParam>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub outputs: Vec<CallParam>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CallParam {
    /// As the ABI spells it, empty when the ABI left it unnamed.
    pub name: String,
    #[serde(rename = "type")]
    pub abi_type: String,
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
    pub call_handlers: Vec<CallHandler>,
    pub block_handlers: Vec<BlockHandler>,
    /// Values the manifest attaches to this data source, read back by
    /// `dataSource.context()`.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub context: BTreeMap<String, ContextValue>,
    /// Templates carry no address and are instantiated by `dataSource.create`.
    pub is_template: bool,
}

/// One `context` entry. graph-node types it in the manifest and hands the
/// mapping a `Value` of that type; the data is carried as written and converted
/// by the shim, which already owns every graph-ts scalar.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextValue {
    #[serde(rename = "type")]
    pub kind: String,
    pub data: String,
}

/// The manifest's `graft:` block: graph-node would start from a copy of the
/// `base` deployment's data up to `block`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Graft {
    pub base: String,
    pub block: u64,
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
    /// The `graft:` block, ignored by the indexer (it re-indexes from the
    /// data sources' start blocks) and reported once at startup.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub graft: Option<Graft>,
    /// The warning that goes with `graft`, worded once here so the CLI and the
    /// runtime say the same thing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub graft_notice: Option<String>,
}

/// What ignoring a `graft:` means for this manifest. The base text is always
/// shown; the loud part names data sources that start after the graft block.
pub fn graft_notice(graft: &Graft, sources: &[DataSource]) -> String {
    let mut text = format!(
        "WARNING: this subgraph grafts onto deployment {} at block {}. Envio cannot copy another \
         deployment's data, so the graft is IGNORED and the subgraph is indexed from its data \
         sources' own startBlocks, as a full re-index. The result equals the grafted deployment \
         only if the base deployment's mappings produced the same data as these mappings do \
         for blocks up to {}.",
        graft.base, graft.block, graft.block
    );
    let late: Vec<String> = sources
        .iter()
        .filter(|s| !s.is_template)
        .filter_map(|s| match s.start_block {
            Some(b) if b > graft.block => Some(format!("{} (startBlock {b})", s.name)),
            _ => None,
        })
        .collect();
    if !late.is_empty() {
        text.push_str(&format!(
            "\nWARNING, DATA MAY BE MISSING: {} start after the graft block {}. The base \
             deployment may hold data from before those start blocks (it was indexed under its own \
             manifest) that a re-index from the start blocks cannot reproduce. Lower the \
             startBlock to the base deployment's start block to rebuild that history.",
            late.join(", "),
            graft.block
        ));
    }
    text
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
    parse_with_networks(yaml, &NetworksFromRpc::new(), report)
}

/// `parse`, with the chains an RPC endpoint named for networks no table knows.
pub fn parse_with_networks(
    yaml: &str,
    networks: &NetworksFromRpc,
    report: &mut Report,
) -> Option<Manifest> {
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

    // A `features` entry declares what the subgraph is allowed to reach for, not
    // what it reaches for — Uniswap V3 and Lido both list grafting and never
    // graft. Whatever a feature enables is refused where the manifest or schema
    // actually uses it.
    for (idx, feature) in root.seq("features").iter().enumerate() {
        let location = format!("features[{idx}]");
        match feature.as_str() {
            Some(name) if KNOWN_FEATURES.contains(&name) => {}
            Some(name) => report.unknown(format!("the feature \"{name}\""), location),
            None => report.unknown("the feature entry", location),
        }
    }

    // Envio can't copy another deployment's data, so a graft is ignored and the
    // subgraph indexes from its own start blocks (see `graft_notice`).
    let graft = root.get("graft").and_then(|raw| {
        let mut obj = Obj::new(raw, "graft", report)?;
        let base = obj.string("base");
        let block = obj.u64("block");
        obj.finish(report);
        Some(Graft {
            base: base.unwrap_or_default(),
            block: block.unwrap_or(0),
        })
    });

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
            networks,
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
            networks,
            report,
        ) {
            templates.push(ds);
        }
    }

    root.finish(report);

    let graft_notice = graft
        .as_ref()
        .map(|graft| graft_notice(graft, &data_sources));
    Some(Manifest {
        spec_version,
        schema_file,
        data_sources,
        templates,
        declares_eth_calls,
        graft,
        graft_notice,
    })
}

fn parse_data_source(
    raw: &Value,
    path: &str,
    is_template: bool,
    declares_eth_calls: &mut bool,
    networks: &NetworksFromRpc,
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
        "near" | "cosmos" | "arweave" | "starknet" => {
            report.unsupported(
                format!("{kind_raw} subgraphs — Envio Subgraph indexes EVM chains"),
                where_("kind"),
            );
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
        (Some(network), DataSourceKind::Contract) => {
            match (network_to_chain_id(network), networks.get(network)) {
                (Some(id), _) => Some(id),
                (None, Some(Ok(id))) => Some(*id),
                (None, asked) => {
                    match NON_EVM_NETWORKS
                        .iter()
                        .find(|(name, _)| name == network)
                        .map(|(_, ecosystem)| *ecosystem)
                    {
                        Some(ecosystem) => report.unsupported(
                            format!("{ecosystem} subgraphs — Envio Subgraph indexes EVM chains"),
                            where_("network"),
                        ),
                        None => report.push(Finding::UnknownNetwork {
                            network: network.clone(),
                            location: where_("network"),
                            rpc_failure: asked.and_then(|asked| asked.clone().err()),
                        }),
                    }
                    None
                }
            }
        }
        _ => None,
    };

    let mut address = None;
    let mut start_block = None;
    let mut end_block = None;
    let mut abi = None;
    if let Some(source) = obj.get("source") {
        if let Some(mut source) = Obj::new(source, &format!("{path}.source"), report) {
            // graph-node parses the address as hex with or without the `0x`
            // (Livepeer writes it bare); envio requires the prefix.
            address = source.string("address").map(|address| {
                let bare = address.len() == 40 && address.chars().all(|c| c.is_ascii_hexdigit());
                if bare {
                    format!("0x{address}")
                } else {
                    address
                }
            });
            start_block = source.u64("startBlock");
            end_block = source.u64("endBlock");
            abi = source.string("abi");
            // File data sources point at a CID instead of a contract.
            source.get("file");
            // Not a graph-node field: its `Source` (graph/src/data/subgraph)
            // has `address` only and doesn't deny unknown keys, so a list here
            // is dropped and the data source matches every emitter, as one
            // without an address does. graph-cli lets it through when the
            // manifest has a file data source, which skips its validation
            // (flaunch). Read the same way, so the same events are indexed.
            source.get("addresses");
            source.finish(report);
        }
    }

    let mut abis = BTreeMap::new();
    let mut api_version = String::new();
    let mut mapping_file = String::new();
    let mut entities = Vec::new();
    let mut event_handlers = Vec::new();
    let mut call_handlers: Vec<CallHandler> = Vec::new();
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
                    // graph-node runs a handler on a template for each instance
                    // from its creation block; the runtime does so for an
                    // unfiltered one. A filtered one counts from the instance's
                    // own block, which envio's chain-wide filters don't know.
                    if is_template && handler.filter != BlockFilter::Every(1) {
                        report.unsupported(
                            "filtered block handlers on templates",
                            where_(&format!("blockHandlers → \"{}\"", handler.handler)),
                        );
                    }
                    block_handlers.push(handler);
                }
            }

            for (idx, raw) in mapping.seq("callHandlers").into_iter().enumerate() {
                if let Some(handler) = parse_call_handler(
                    raw,
                    &format!("{path}.mapping.callHandlers[{idx}]"),
                    &name,
                    report,
                ) {
                    call_handlers.push(handler);
                }
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
                    inputs: Vec::new(),
                });
            }

            mapping.finish(report);
        }
    }

    // graph-node creates a file data source only from a template; a static one
    // has no CID to read until something creates it.
    if matches!(kind, DataSourceKind::FileIpfs | DataSourceKind::FileArweave) && !is_template {
        report.unsupported(
            "file data sources outside `templates`",
            format!("data source \"{name}\" → kind: {kind_raw}"),
        );
    }

    let context = parse_context(&mut obj, &where_, report);

    obj.finish(report);

    // graph-node refuses a call trigger it has no address to look for.
    let needs_address = !call_handlers.is_empty()
        || block_handlers
            .iter()
            .any(|handler| handler.filter == BlockFilter::Call);
    if needs_address && address.is_none() && !is_template {
        report.unknown(
            "a call handler on a data source without `source.address`, which graph-node refuses \
             as well",
            where_("callHandlers"),
        );
    }

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
        call_handlers,
        block_handlers,
        context,
        is_template,
    })
}

/// graph-node's context value types. Anything else is newer than this parser.
const CONTEXT_TYPES: &[&str] = &[
    "Bool",
    "Boolean",
    "String",
    "Int",
    "Int8",
    "BigInt",
    "BigDecimal",
    "Bytes",
];

fn parse_context(
    obj: &mut Obj<'_>,
    where_: &impl Fn(&str) -> String,
    report: &mut Report,
) -> BTreeMap<String, ContextValue> {
    let mut context = BTreeMap::new();
    let Some(raw) = obj.get("context") else {
        return context;
    };
    let Some(mut entries) = Obj::new(raw, &obj.child_path("context"), report) else {
        return context;
    };

    for key in entries.keys() {
        let path = entries.child_path(&key);
        let Some(value) = entries.get(&key) else {
            continue;
        };
        let Some(mut entry) = Obj::new(value, &path, report) else {
            continue;
        };
        let kind = entry.string("type").unwrap_or_default();
        if !CONTEXT_TYPES.contains(&kind.as_str()) {
            report.unknown(
                format!("the context value type \"{kind}\""),
                where_(&format!("context → {key}")),
            );
            entry.finish(report);
            continue;
        }
        let data = match entry.get("data") {
            Some(Value::String(text)) => text.clone(),
            Some(Value::Number(number)) => number.to_string(),
            Some(Value::Bool(flag)) => flag.to_string(),
            _ => {
                report.unknown(
                    format!("the context value \"{key}\""),
                    where_(&format!("context → {key}")),
                );
                entry.finish(report);
                continue;
            }
        };
        entry.finish(report);
        context.insert(key, ContextValue { kind, data });
    }

    entries.finish(report);
    context
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
                other => other
                    .as_str()
                    .map(|s| vec![s.to_string()])
                    .unwrap_or_default(),
            };
            if !values.is_empty() {
                topics.insert(position, values);
            }
        }
    }

    if obj.get("calls").is_some() {
        *declares_eth_calls = true;
    }

    // graph-node matches a log on `topic0` instead of the signature's hash
    // when one is given (`MappingEventHandler::topic0`). Spelling out the
    // signature's own hash changes nothing; any other value selects logs envio
    // can't ask for by event, Balancer's anonymous LOG_CALL among them.
    if let Some(topic0) = obj.string("topic0") {
        let own = canonical_event_hash(&event);
        if own
            .as_deref()
            .is_some_and(|own| !own.eq_ignore_ascii_case(topic0.trim()))
        {
            report.unsupported(
                "event handlers whose topic0 is not the event signature's hash (anonymous \
                 events)",
                format!("data source \"{data_source}\" → eventHandlers → \"{handler}\" → topic0"),
            );
        }
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
        inputs: Vec::new(),
    })
}

/// `keccak256` of an event signature as the manifest spells it: `indexed` and
/// parameter names dropped. `None` when the signature isn't one this reads.
pub fn canonical_event_hash(event: &str) -> Option<String> {
    let open = event.find('(')?;
    let close = event.rfind(')')?;
    let name = event[..open].trim();
    let mut types = Vec::new();
    let (mut depth, mut start) = (0usize, open + 1);
    let params = &event[..close];
    for (at, c) in params.char_indices().skip(open + 1) {
        match c {
            '(' => depth += 1,
            ')' => depth = depth.checked_sub(1)?,
            ',' if depth == 0 => {
                types.push(&params[start..at]);
                start = at + 1;
            }
            _ => {}
        }
    }
    if !params[start..].trim().is_empty() {
        types.push(&params[start..]);
    }
    let types: Option<Vec<String>> = types
        .into_iter()
        .map(|param| {
            // A tuple is `(a,b)[]`-shaped: only a plain parameter loses its words.
            let param = param.trim();
            if param.starts_with('(') {
                return None;
            }
            param
                .split_whitespace()
                .find(|word| *word != "indexed")
                .map(str::to_string)
        })
        .collect();
    let signature = format!("{name}({})", types?.join(","));
    Some(alloy_primitives::keccak256(signature.as_bytes()).to_string())
}

fn parse_call_handler(
    raw: &Value,
    path: &str,
    data_source: &str,
    report: &mut Report,
) -> Option<CallHandler> {
    let mut obj = Obj::new(raw, path, report)?;
    let function = obj.string("function").unwrap_or_default();
    let handler = obj.string("handler").unwrap_or_default();
    obj.finish(report);

    if function.trim().is_empty() || !function.contains('(') || !function.trim_end().ends_with(')')
    {
        report.unknown(
            "the call handler without a function signature",
            format!("data source \"{data_source}\" → callHandlers → \"{handler}\""),
        );
        return None;
    }

    Some(CallHandler {
        function,
        handler,
        name: String::new(),
        inputs: Vec::new(),
        outputs: Vec::new(),
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
                "call" => filter = BlockFilter::Call,
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

    Some(BlockHandler {
        handler,
        filter,
        call_event: String::new(),
    })
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
    fn maps_graph_network_names_to_chain_ids() {
        assert_eq!(
            [
                network_to_chain_id("ethereum"),
                network_to_chain_id("mainnet"),
                network_to_chain_id("matic"),
                network_to_chain_id("arbitrum-one"),
                network_to_chain_id("hyperevm"),
                network_to_chain_id("hyper-evm"),
                network_to_chain_id("hyperliquid"),
                network_to_chain_id("ethereum-mainnet"),
                network_to_chain_id("polygon"),
                network_to_chain_id("apechain"),
                network_to_chain_id("pulsechain"),
                network_to_chain_id("pulse"),
                // Aliases the registry added in 0.8.7.
                network_to_chain_id("arctest"),
                network_to_chain_id("basesepolia"),
                network_to_chain_id("not-a-chain"),
            ],
            [
                Some(1),
                Some(1),
                Some(137),
                Some(42161),
                Some(999),
                Some(999),
                Some(999),
                Some(1),
                Some(137),
                Some(33139),
                Some(369),
                Some(369),
                Some(5042002),
                Some(84532),
                None,
            ]
        );
    }

    #[test]
    fn resolves_every_network_the_graph_registry_lists() {
        let wrong: Vec<_> = GRAPH_NETWORKS
            .iter()
            .flat_map(|(id, network)| {
                std::iter::once(id)
                    .chain(&network.aliases)
                    .map(move |name| (name.clone(), network.chain_id))
            })
            .filter(|(name, chain_id)| network_to_chain_id(name) != Some(*chain_id))
            .collect();
        assert_eq!(wrong, Vec::<(String, u64)>::new());
    }

    // The slugs other hosts' subgraph.yaml files use, with the chain ids the
    // hosts' own docs and chainlist give (each also checked with eth_chainId).
    #[test]
    fn resolves_the_network_slugs_other_hosts_use() {
        let expected = [
            ("filecoin", 314),
            ("plasma-mainnet", 9745),
            ("manta-pacific-mainnet", 169),
            ("manta-pacific-sepolia", 3441006),
            ("mezo-testnet", 31611),
            ("fluent", 25363),
            ("story", 1514),
            ("citrea-testnet-tangerine", 5115),
            ("kite-ai-testnet", 2368),
            ("andromeda", 1088),
            ("telos", 40),
            ("mantle-sepolia", 5003),
            ("pulse", 369),
            // Any chain by id, for one no host's slug list has.
            ("evm-9999991", 9999991),
        ];
        let wrong: Vec<_> = expected
            .iter()
            .filter(|(name, id)| network_to_chain_id(name) != Some(*id))
            .collect();
        assert!(wrong.is_empty(), "{wrong:?}");
    }

    // The table only adds names: a slug the registry already knows keeps the
    // registry's chain id, and no two slugs for a chain id disagree on a name.
    #[test]
    fn host_networks_never_shadow_the_registry() {
        let table: Vec<HostNetwork> = serde_json::from_str(include_str!("host_networks.json"))
            .expect("host_networks.json is valid");
        let mut seen = HashSet::new();
        for network in &table {
            assert!(network.chain_id > 0, "{}", network.name);
            assert!(seen.insert(network.name.clone()), "{} twice", network.name);
            let in_registry = GRAPH_NETWORKS.iter().any(|(id, registered)| {
                *id == network.name || registered.aliases.contains(&network.name)
            });
            assert!(
                !in_registry,
                "{} is in the registry; drop it from host_networks.json",
                network.name
            );
        }
    }

    #[test]
    fn accepts_a_pre_feature_spec_version() {
        let yaml = GRAVITY.replace("specVersion: 0.0.5", "specVersion: 0.0.2");
        let (manifest, report) = parse_ok(&yaml);
        assert_eq!(
            (manifest.unwrap().spec_version.as_str(), report.is_empty()),
            ("0.0.2", true)
        );
    }

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
                rendered.contains("doesn't support grafting"),
            ),
            (0, false)
        );
    }

    #[test]
    fn reads_call_handlers_and_call_filtered_block_handlers() {
        let yaml = r#"
specVersion: 0.0.8
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
      callHandlers:
        - function: approve(address,uint256)
          handler: handleApprove
      blockHandlers:
        - handler: handleBlockCall
          filter:
            kind: call
      file: ./src/token.ts
  - kind: ethereum/contract
    name: Anywhere
    network: mainnet
    source:
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
      file: ./src/token.ts
"#;
        let (manifest, report) = parse_ok(yaml);
        let manifest = manifest.unwrap();
        let token = &manifest.data_sources[0];
        assert_eq!(
            (
                token.call_handlers[0].function.as_str(),
                token.call_handlers[0].handler.as_str(),
                token.block_handlers[0].filter.clone(),
            ),
            (
                "approve(address,uint256)",
                "handleApprove",
                BlockFilter::Call
            )
        );
        // graph-node refuses a call trigger on a data source with no address.
        let rendered = report.to_string();
        assert!(
            report.findings().len() == 1 && rendered.contains("data source \"Anywhere\""),
            "{rendered}"
        );
    }

    fn graft_manifest(start_block: u64) -> String {
        format!(
            r#"
specVersion: 1.3.0
schema:
  file: ./schema.graphql
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
      startBlock: {start_block}
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
      file: ./src/token.ts
"#
        )
    }

    #[test]
    fn a_graft_is_ignored_with_a_full_reindex_notice() {
        let (manifest, report) = parse_ok(&graft_manifest(10));
        let manifest = manifest.unwrap();
        let notice = manifest.graft_notice.clone().unwrap_or_default();
        assert_eq!(
            (
                report.findings().len(),
                manifest.graft,
                notice.contains("IGNORED"),
                notice.contains("full re-index"),
                notice.contains("QmBase"),
                notice.contains("DATA MAY BE MISSING"),
            ),
            (
                0,
                Some(Graft {
                    base: "QmBase".into(),
                    block: 100
                }),
                true,
                true,
                true,
                false
            )
        );
    }

    #[test]
    fn a_graft_with_a_source_starting_after_the_graft_block_warns_loudly() {
        let (manifest, _) = parse_ok(&graft_manifest(500));
        let manifest = manifest.unwrap();
        let notice = manifest.graft_notice.unwrap_or_default();
        assert!(notice.contains("DATA MAY BE MISSING"), "{notice}");
        assert!(notice.contains("Token (startBlock 500)"), "{notice}");
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
    fn refuses_non_evm_networks_by_name() {
        let yaml = GRAVITY
            .replace("network: mainnet", "network: near-mainnet")
            .replace("kind: ethereum/contract", "kind: near");
        let (_, report) = parse_ok(&yaml);
        let rendered = report.to_string();
        assert_eq!(
            (
                rendered
                    .contains("doesn't support near subgraphs — Envio Subgraph indexes EVM chains"),
                rendered.contains("doesn't know"),
            ),
            (true, false)
        );
    }

    #[test]
    fn accepts_envio_network_names_as_a_fallback() {
        let yaml = GRAVITY.replace("network: mainnet", "network: hyperliquid");
        let (manifest, report) = parse_ok(&yaml);
        assert_eq!(
            (
                manifest.unwrap().data_sources[0].chain_id,
                report.is_empty()
            ),
            (Some(999), true)
        );
    }

    #[test]
    fn refuses_a_non_evm_network_on_an_ethereum_data_source() {
        let yaml = GRAVITY.replace("network: mainnet", "network: arweave-mainnet");
        assert!(
            parse_ok(&yaml)
                .1
                .to_string()
                .contains("doesn't support Arweave subgraphs"),
            "expected an Arweave finding"
        );
    }

    // `features` is a declaration, not a use: Uniswap V3 and Lido both list
    // grafting without a `graft` block, and nothing in the subgraph reaches for
    // it. What the manifest actually does is refused where it does it.
    #[test]
    fn accepts_declared_features_that_the_manifest_never_uses() {
        let yaml = r#"
specVersion: 1.3.0
schema:
  file: ./schema.graphql
features:
  - nonFatalErrors
  - grafting
  - aggregations
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
      file: ./src/token.ts
"#;
        let (_, report) = parse_ok(yaml);
        assert_eq!(report.findings().len(), 0, "{report}");
    }

    #[test]
    fn reads_a_data_source_context() {
        let yaml = r#"
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    context:
      storeEventsFrom:
        type: BigInt
        data: '25144091'
      poolKind:
        type: String
        data: weighted
    source:
      address: "0x1"
      abi: Vault
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
      eventHandlers:
        - event: Swap(indexed address,uint256)
          handler: handleSwap
      file: ./src/vault.ts
"#;
        let (manifest, report) = parse_ok(yaml);
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            manifest.unwrap().data_sources[0].context,
            BTreeMap::from([
                (
                    "poolKind".to_string(),
                    ContextValue {
                        kind: "String".to_string(),
                        data: "weighted".to_string(),
                    }
                ),
                (
                    "storeEventsFrom".to_string(),
                    ContextValue {
                        kind: "BigInt".to_string(),
                        data: "25144091".to_string(),
                    }
                ),
            ])
        );
    }

    #[test]
    fn accepts_an_old_api_version() {
        let yaml = r#"
specVersion: 0.0.4
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
      apiVersion: 0.0.3
      language: wasm/assemblyscript
      entities: []
      abis: []
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          handler: handleTransfer
      file: ./src/token.ts
"#;
        let (_, report) = parse_ok(yaml);
        assert_eq!(report.findings().len(), 0, "{report}");
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

    const TOPIC0_MANIFEST: &str = r#"
specVersion: 1.2.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "35Bcf3c30594191d53231E4FF333E8A770453e40"
      abi: Token
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis: []
      eventHandlers:
        - event: Transfer(indexed address,indexed address,uint256)
          topic0: "TOPIC0"
          handler: handleTransfer
      file: ./src/token.ts
"#;

    // Livepeer writes its addresses without `0x`, which graph-node accepts.
    // A topic0 equal to the signature's hash (any case) matches what the
    // signature already selects.
    #[test]
    fn accepts_a_bare_address_and_the_signature_topic0() {
        let yaml = TOPIC0_MANIFEST.replace(
            "TOPIC0",
            "0xDDF252AD1BE2C89B69C2B068FC378DAA952BA7F163C4A11628F55A4DF523B3EF",
        );
        let (manifest, report) = parse_ok(&yaml);
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            manifest.unwrap().data_sources[0].address.clone(),
            Some("0x35Bcf3c30594191d53231E4FF333E8A770453e40".to_string())
        );
    }

    // flaunch's BidWall1 lists `addresses:`, which graph-node never reads: the
    // data source has no address there, so it has none here either.
    #[test]
    fn reads_a_source_addresses_list_as_graph_node_does() {
        let yaml = TOPIC0_MANIFEST
            .replace(
                "      address: \"35Bcf3c30594191d53231E4FF333E8A770453e40\"",
                "      addresses:\n        - \"0x66681f10BA90496241A25e33380004f30Dfd8aa8\"",
            )
            .replace("          topic0: \"TOPIC0\"\n", "");
        let (manifest, report) = parse_ok(&yaml);
        assert!(report.is_empty(), "{report}");
        assert_eq!(manifest.unwrap().data_sources[0].address, None);
    }

    // Balancer's cow-amm matches its anonymous LOG_CALL on topic0, the called
    // selector: not an event envio can select by signature.
    #[test]
    fn refuses_a_topic0_other_than_the_signature_hash() {
        let yaml = TOPIC0_MANIFEST.replace(
            "TOPIC0",
            "0x4bb278f300000000000000000000000000000000000000000000000000000000",
        );
        let (_, report) = parse_ok(&yaml);
        assert_eq!(
            report.findings(),
            &[crate::subgraph::errors::Finding::unsupported(
                "event handlers whose topic0 is not the event signature's hash (anonymous events)",
                "data source \"Token\" → eventHandlers → \"handleTransfer\" → topic0",
            )]
        );
    }
}

#[cfg(test)]
mod topic0_tests {
    use super::*;

    #[test]
    fn hashes_a_signature_without_indexed_or_names() {
        assert_eq!(
            canonical_event_hash("Deposit(indexed bytes32,address,address,uint256)").as_deref(),
            Some("0xc95ddcaddf83340b68d0d44c01b1703f5d28d0611a3fd87e69d79ba7e2ac21d3")
        );
        assert_eq!(
            canonical_event_hash("Deposit(indexed bytes32 id, address a, address b, uint256 c)")
                .as_deref(),
            Some("0xc95ddcaddf83340b68d0d44c01b1703f5d28d0611a3fd87e69d79ba7e2ac21d3")
        );
    }
}
