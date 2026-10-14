//! Subgraph mode: run an unmodified subgraph project on HyperIndex.
//!
//! The CLI detects `subgraph.yaml`, translates the manifest into an envio
//! config and the schema into an envio schema, and points the handler entry at
//! the subgraph runtime that ships inside the `envio` package.

pub mod abi;
pub mod assemblyscript;
pub mod creates;
pub mod errors;
pub mod manifest;
pub mod schema;
pub mod usage;

use std::collections::{BTreeMap, HashMap, HashSet};

use anyhow::{anyhow, Result};
use serde::Serialize;

use crate::config_parsing::chain_helpers::get_max_reorg_depth_from_id;
use crate::config_parsing::human_config::{
    evm::{
        AddressFormat, BlockField, Chain, ContractConfig, EventConfig, FieldSelection, HumanConfig,
        RpcSelection, TransactionField,
    },
    BaseConfig, BytesType, ChainContract, GlobalContract, StartBlock,
};
use crate::utils::normalized_list::NormalizedList;
use crate::utils::text::Capitalize;

use errors::Report;
use manifest::{DataSource, Manifest};
use schema::SchemaTranslation;

/// The env var carrying an RPC endpoint. subgraph.yaml has no place for
/// provider config — graph-node keeps it in its own config, not the project.
pub const RPC_ENV_VAR: &str = "ENVIO_SUBGRAPH_RPC";
/// envio's `maxReorgDepth` for a chain it has no figure for.
const DEFAULT_MAX_REORG_DEPTH: u32 = 200;
pub const BATCH_SIZE_ENV_VAR: &str = "ENVIO_SUBGRAPH_BATCH_SIZE";
/// Events per batch for a mapping that calls contracts.
const CALLING_BATCH_SIZE: u64 = 500;
pub const BLOCK_LAG_ENV_VAR: &str = "ENVIO_SUBGRAPH_BLOCK_LAG";
pub const API_TOKEN_ENV_VAR: &str = "ENVIO_API_TOKEN";

/// The transaction fields graph-ts exposes on `event.receipt`. A mapping can
/// read the hash, index and root there without the usage scan seeing a read
/// of `event.transaction`.
const RECEIPT_TRANSACTION_FIELDS: &[TransactionField] = &[
    TransactionField::Hash,
    TransactionField::TransactionIndex,
    TransactionField::Root,
    TransactionField::Status,
    TransactionField::GasUsed,
    TransactionField::CumulativeGasUsed,
    TransactionField::LogsBloom,
    TransactionField::ContractAddress,
];

/// `event.transaction` in graph-ts is always fully populated, so every event
/// selects the fields the shim can serve.
const DEFAULT_TRANSACTION_FIELDS: &[TransactionField] = &[
    TransactionField::Hash,
    TransactionField::TransactionIndex,
    TransactionField::From,
    TransactionField::To,
    TransactionField::Value,
    TransactionField::Gas,
    TransactionField::GasPrice,
    TransactionField::Input,
    TransactionField::Nonce,
];

/// Same for `event.block`.
const DEFAULT_BLOCK_FIELDS: &[BlockField] = &[
    BlockField::ParentHash,
    BlockField::Miner,
    BlockField::Difficulty,
    BlockField::TotalDifficulty,
    BlockField::GasLimit,
    BlockField::GasUsed,
    BlockField::Size,
    BlockField::BaseFeePerGas,
    BlockField::StateRoot,
    BlockField::ReceiptsRoot,
    BlockField::TransactionsRoot,
];

/// What the runtime reads back out of the public config to register handlers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubgraphRuntimeConfig {
    #[serde(flatten)]
    pub manifest: Manifest,
    #[serde(flatten)]
    pub schema: SchemaTranslation,
    /// Project-relative directory the mapping files resolve against.
    pub root: String,
    /// The name envio generated each accessor under, keyed by the name the
    /// subgraph gives it — the only one its mappings know.
    pub entity_accessors: BTreeMap<String, String>,
    pub contract_accessors: BTreeMap<String, String>,
    /// `ENVIO_SUBGRAPH_RPC` flattened to plain URLs, in order. The shim's call
    /// effects use them as a viem fallback transport; empty means the mapping's
    /// first contract call raises the missing-RPC error.
    pub rpc_urls: Vec<String>,
    /// How far, per chain, a block handler that reads header fields trails the
    /// head: the runtime refuses to serve a header from inside that distance.
    pub block_header_lag: BTreeMap<u64, u32>,
}

#[derive(Debug)]
pub struct Translation {
    pub human_config: HumanConfig,
    pub schema_text: String,
    pub runtime: SubgraphRuntimeConfig,
}

/// Parsed `ENVIO_SUBGRAPH_RPC`: a bare URL, one rpc object, or a list of both —
/// the same shape and deny-unknown rules as config.yaml's `rpc` field.
pub fn parse_rpc_env(raw: &str) -> Result<RpcSelection> {
    let trimmed = raw.trim();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        let invalid = |err: serde_json::Error| {
            anyhow!(
                "Invalid {RPC_ENV_VAR}: {err}. It takes an RPC URL, or JSON matching envio's rpc \
                 config (a single entry or an array of entries and URLs)."
            )
        };
        let mut value: serde_json::Value = serde_json::from_str(trimmed).map_err(invalid)?;
        // A bare URL in the list means what a bare URL alone means: an entry
        // with only `url`, whose `for` takes the chain's default.
        if let serde_json::Value::Array(entries) = &mut value {
            for entry in entries.iter_mut() {
                if let serde_json::Value::String(url) = entry {
                    *entry = serde_json::json!({ "url": url.trim() });
                }
            }
        }
        serde_json::from_value::<RpcSelection>(value).map_err(invalid)
    } else if trimmed.is_empty() {
        Err(anyhow!("{RPC_ENV_VAR} is set but empty."))
    } else {
        Ok(RpcSelection::Url(trimmed.to_string()))
    }
}

/// The error raised when a mapping performs a contract call with no RPC
/// configured. Emitted eagerly when the manifest declares `eth_calls`, lazily
/// (from the runtime) otherwise.
pub fn missing_rpc_message(call_site: &str) -> String {
    format!(
        "This subgraph performs contract calls ({call_site}), which need an\n\
         RPC endpoint — HyperSync and HyperRPC serve logs and blocks, not eth_call.\n\
         Set one in .env or the environment:\n  \
         {RPC_ENV_VAR}=https://...\n\
         Advanced (matches envio's rpc config; single entry or array):\n  \
         {RPC_ENV_VAR}={{\"url\":\"https://...\",\"for\":\"fallback\",\"headers\":{{...}}}}"
    )
}

pub fn missing_api_token_message() -> String {
    format!(
        "Envio Subgraph needs a HyperSync API token to sync.\n\
         Create one at https://envio.dev/app/api-tokens, then add it to .env:\n  \
         {API_TOKEN_ENV_VAR}=<your token>"
    )
}

/// The same words the runtime uses when it can't build the generated code.
pub fn missing_graph_cli_message(generated: &str) -> String {
    format!(
        "Envio Subgraph needs the project's generated code, but \"{generated}/\" is\n\
         missing and @graphprotocol/graph-cli isn't installed in the project or any\n\
         directory above it. Install the project's dependencies and try again:\n  \
         npm install   (or yarn / pnpm install)\n\
         Or generate manually:\n  \
         npx graph codegen --output-dir {generated}"
    )
}

/// Where the mappings import `graph codegen`'s output from — their imports of
/// `schema`/`templates`, followed breadth first through relative imports —
/// as `subgraph/graph-cli.ts` reads it at startup.
pub fn generated_dir(root: &std::path::Path, mapping_files: &[String]) -> std::path::PathBuf {
    let import = regex::Regex::new(r#"\bfrom\s*["'](\.\.?/[^"']+)["']"#).expect("valid pattern");
    let mut queue: std::collections::VecDeque<std::path::PathBuf> =
        mapping_files.iter().map(|file| root.join(file)).collect();
    let mut seen: HashSet<std::path::PathBuf> = queue.iter().cloned().collect();
    let mut scanned = 0;
    while let Some(file) = queue.pop_front() {
        scanned += 1;
        if scanned > 2_000 {
            break;
        }
        let Ok(source) = std::fs::read_to_string(&file) else {
            continue;
        };
        let dir = file
            .parent()
            .map(|dir| dir.to_path_buf())
            .unwrap_or_default();
        for capture in import.captures_iter(&source) {
            let specifier = std::path::Path::new(&capture[1]);
            let base = specifier
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.trim_end_matches(".ts"));
            if matches!(base, Some("schema") | Some("templates")) {
                return dir.join(specifier.parent().unwrap_or(std::path::Path::new(".")));
            }
            let target = dir.join(specifier);
            let candidates = [
                target.clone(),
                std::path::PathBuf::from(format!("{}.ts", target.display())),
                target.join("index.ts"),
            ];
            if let Some(found) = candidates.into_iter().find(|candidate| candidate.is_file()) {
                if seen.insert(found.clone()) {
                    queue.push_back(found);
                }
            }
        }
    }
    root.join("generated")
}

/// Whether Node would resolve graph-cli from the project directory.
pub fn graph_cli_installed(root: &std::path::Path) -> bool {
    root.ancestors().any(|dir| {
        dir.join("node_modules/@graphprotocol/graph-cli/package.json")
            .is_file()
    })
}

/// `envio codegen` and `envio start` refuse alike when the generated code is
/// missing and nothing can build it: codegen used to pass, and only the
/// indexer found out.
pub fn check_generated_code(runtime: &SubgraphRuntimeConfig) -> Result<()> {
    // Absolute, so its ancestors are the directories above the project.
    let root = std::fs::canonicalize(&runtime.root)
        .unwrap_or_else(|_| std::path::PathBuf::from(&runtime.root));
    let root = root.as_path();
    let mapping_files: Vec<String> = runtime
        .manifest
        .all_sources()
        .map(|source| source.mapping_file.clone())
        .collect();
    let generated = generated_dir(root, &mapping_files);
    // Every generated tree has a schema.ts; Envio Cloud leaves the directory
    // itself behind empty.
    if generated.join("schema.ts").is_file() || graph_cli_installed(root) {
        return Ok(());
    }
    let relative = pathdiff_relative(&generated, root);
    Err(anyhow!("{}", missing_graph_cli_message(&relative)))
}

fn pathdiff_relative(path: &std::path::Path, root: &std::path::Path) -> String {
    let normalize = |path: &std::path::Path| {
        let mut out = std::path::PathBuf::new();
        for part in path.components() {
            match part {
                std::path::Component::ParentDir => {
                    out.pop();
                }
                std::path::Component::CurDir => {}
                other => out.push(other),
            }
        }
        out
    };
    let (path, root) = (normalize(path), normalize(root));
    path.strip_prefix(&root)
        .map(|relative| relative.display().to_string())
        .unwrap_or_else(|_| path.display().to_string())
}

pub fn graph_codegen_failed_message() -> String {
    "Envio Subgraph ran `graph codegen` to build \"generated/\", but it failed —\n\
     the error above comes from The Graph's own codegen, so fix it there and\n\
     rerun. If `graph codegen` succeeds on its own but fails through envio,\n\
     please open an issue: https://github.com/enviodev/hyperindex/issues"
        .to_string()
}

/// The name envio routes an event by: its own unless one was minted.
fn envio_event_name(event: &EventConfig) -> String {
    event
        .name
        .clone()
        .unwrap_or_else(|| abi::event_name(&event.event))
}

fn field_selection_for(receipt: bool, usage: &usage::FieldUsage) -> FieldSelection {
    let mut transaction_fields = match &usage.transaction {
        Some(fields) => fields.clone(),
        None => DEFAULT_TRANSACTION_FIELDS.to_vec(),
    };
    if receipt {
        for field in RECEIPT_TRANSACTION_FIELDS {
            if !transaction_fields.contains(field) {
                transaction_fields.push(field.clone());
            }
        }
    }
    let block_fields = match &usage.block {
        Some(fields) => fields.clone(),
        None => DEFAULT_BLOCK_FIELDS.to_vec(),
    };
    FieldSelection {
        transaction_fields: Some(transaction_fields),
        block_fields: Some(block_fields),
    }
}

fn contract_config(
    source: &mut DataSource,
    files: &HashMap<String, String>,
    usage: &usage::FieldUsage,
    report: &mut Report,
) -> ContractConfig {
    let abi_path = source
        .abi
        .as_ref()
        .and_then(|abi| source.abis.get(abi))
        .cloned();
    let abi_json = abi_path.as_ref().and_then(|path| {
        files
            .get(path)
            .or_else(|| files.get(path.trim_start_matches("./")))
            .cloned()
    });
    let source_name = source.name.clone();

    // An overloaded name needs a unique envio name as well as a spelled-out
    // signature: the generated routing keys off the name, and the runtime has
    // to register the handler under the same one.
    let mut resolved: Vec<(String, Option<String>)> = Vec::new();
    let mut ordinals: HashMap<String, usize> = HashMap::new();
    for handler in source.event_handlers.iter_mut() {
        if handler.name.is_empty() {
            continue;
        }
        let base = handler.name.clone();
        let event = abi::resolve_event(
            &handler.event,
            abi_json.as_deref(),
            &format!(
                "data source \"{source_name}\" → eventHandlers → \"{}\"",
                handler.handler
            ),
            report,
        );
        let ordinal = ordinals.entry(base.clone()).or_insert(0);
        let unique = if *ordinal == 0 {
            base.clone()
        } else {
            format!("{base}_{ordinal}")
        };
        *ordinal += 1;
        handler.name = unique.clone();
        handler.inputs = abi::event_inputs(&handler.event, abi_json.as_deref());
        // The generated config needs the same unique name whenever one was
        // minted, overloaded or not — two handlers can name the same event, and
        // the runtime registers under the name the config carries.
        let renamed = unique != base;
        resolved.push((event, renamed.then_some(unique)));
    }

    let events = source
        .event_handlers
        .iter()
        .filter(|handler| !handler.name.is_empty())
        .zip(resolved)
        .map(|(handler, (event, name))| {
            // The runtime turns each filter into a `where` on the indexed
            // parameter it narrows — except one hashed into its topic, whose
            // value envio can't match against.
            let indexed: Vec<_> = handler.inputs.iter().filter(|input| input.indexed).collect();
            for position in handler.topics.keys() {
                let location = format!(
                    "data source \"{}\" → eventHandlers → \"{}\" → topic{position}",
                    source.name, handler.handler
                );
                match indexed.get(position - 1) {
                    None => report.unknown(
                        format!("which indexed parameter of \"{}\" topic{position} filters", handler.event),
                        location,
                    ),
                    Some(input) if input.is_hashed_in_topic() => report.unsupported(
                        format!(
                            "topic filters on a {} indexed parameter, which the log carries only as a hash",
                            input.abi_type
                        ),
                        location,
                    ),
                    Some(_) => {}
                }
            }
            EventConfig {
                event,
                name,
                field_selection: Some(field_selection_for(handler.receipt, usage)),
            }
        })
        .collect();

    ContractConfig {
        abi_file_path: abi_path,
        // Every mapping is loaded by the subgraph runtime, not by envio's
        // per-contract handler resolution.
        handler: None,
        events,
    }
}

/// A mapping that calls contracts commits a batch only once every call in it has
/// been answered, and a handler's calls run one after another. At envio's 5,000
/// events a batch, an endpoint a second away took minutes to commit the first,
/// with nothing to show for it meanwhile (harvest-base, dhedge, gooddollar). A
/// smaller batch commits sooner and costs no calls: they all run concurrently
/// either way. `ENVIO_SUBGRAPH_BATCH_SIZE` overrides it.
fn calling_batch_size(mapping_sources: &[String]) -> Option<u64> {
    let configured = std::env::var(BATCH_SIZE_ENV_VAR)
        .ok()
        .and_then(|raw| raw.trim().parse::<u64>().ok())
        .filter(|size| *size > 0);
    configured.or_else(|| {
        usage::rpc_call_site(mapping_sources)
            .is_some()
            .then_some(CALLING_BATCH_SIZE)
    })
}

/// Builds the envio config a translated manifest indexes with.
pub fn translate(
    manifest_yaml: &str,
    schema_text: &str,
    project_name: &str,
    rpc_env: Option<&str>,
    root: &str,
    files: &HashMap<String, String>,
    mapping_sources: &[String],
) -> Result<Translation> {
    let mut report = Report::new();
    let usage = usage::scan(mapping_sources);

    let Some(manifest) = manifest::parse(manifest_yaml, &mut report) else {
        report.into_result()?;
        return Err(anyhow!("Failed to read subgraph.yaml"));
    };
    let schema = schema::translate(schema_text, &mut report);

    let rpc = match rpc_env {
        Some(raw) => Some(parse_rpc_env(raw)?),
        None => None,
    };
    let rpc_urls = match &rpc {
        Some(RpcSelection::Url(url)) => vec![url.clone()],
        Some(RpcSelection::Single(rpc)) => vec![rpc.url.clone()],
        Some(RpcSelection::List(rpcs)) => rpcs.iter().map(|rpc| rpc.url.clone()).collect(),
        None => vec![],
    };

    let mut contracts: Vec<GlobalContract<ContractConfig>> = Vec::new();
    let mut chains: BTreeMap<u64, Chain> = BTreeMap::new();

    let mut manifest = manifest;
    for source in manifest.data_sources.iter_mut() {
        contracts.push(GlobalContract {
            name: source.name.clone(),
            config: contract_config(source, files, &usage, &mut report),
        });

        let Some(chain_id) = source.chain_id else {
            continue;
        };
        let start_block = source.start_block.unwrap_or(0);
        let is_first = !chains.contains_key(&chain_id);
        let chain = chains.entry(chain_id).or_insert_with(|| Chain {
            id: chain_id,
            skip: None,
            rpc: rpc.clone(),
            hypersync_config: None,
            max_reorg_depth: None,
            block_lag: None,
            start_block: StartBlock::Number(start_block),
            end_block: source.end_block,
            contracts: Some(vec![]),
        });
        if !is_first {
            // A subgraph names only block numbers, so every chain it opens
            // starts at one.
            if let StartBlock::Number(current) = chain.start_block {
                chain.start_block = StartBlock::Number(current.min(start_block));
            }
            // A chain stops only once every data source on it has, so one
            // open-ended source keeps the whole chain open-ended.
            chain.end_block = match (chain.end_block, source.end_block) {
                (Some(current), Some(next)) => Some(current.max(next)),
                _ => None,
            };
        }
        if let Some(chain_contracts) = chain.contracts.as_mut() {
            chain_contracts.push(ChainContract {
                name: source.name.clone(),
                address: NormalizedList::from(
                    source.address.clone().into_iter().collect::<Vec<_>>(),
                ),
                start_block: source.start_block,
                config: None,
            });
        }
    }

    // A template has no address until `dataSource.create` registers one, so it
    // joins every chain it's declared on as an address-less contract.
    let template_chain_ids: Vec<u64> = if chains.is_empty() {
        vec![]
    } else {
        chains.keys().cloned().collect()
    };
    for source in manifest.templates.iter_mut() {
        let config = contract_config(source, files, &usage, &mut report);

        // graph-node keeps `dataSources` and `templates` in separate namespaces,
        // so a name can appear in both — Balancer's FXPoolDeployer is a fixed
        // deployment and a template over the same mapping and ABI. envio has one
        // namespace, and one contract with a static address plus dynamically
        // registered ones is exactly what that describes, so the two are folded
        // together and only the events are unioned.
        match contracts
            .iter_mut()
            .find(|contract| contract.name == source.name)
        {
            Some(existing) => {
                // The template's own names were minted against its handlers
                // alone, so each is re-resolved against the folded contract:
                // a known signature takes that event's name, a new one the
                // next free suffix.
                let handlers = source
                    .event_handlers
                    .iter_mut()
                    .filter(|handler| !handler.name.is_empty());
                for (handler, mut event) in handlers.zip(config.events) {
                    let known = existing
                        .config
                        .events
                        .iter()
                        .find(|known| known.event == event.event);
                    handler.name = match known {
                        Some(known) => envio_event_name(known),
                        None => {
                            let base = envio_event_name(&event);
                            let taken: HashSet<String> = existing
                                .config
                                .events
                                .iter()
                                .map(envio_event_name)
                                .collect();
                            let name = (0..)
                                .map(|ordinal| match ordinal {
                                    0 => base.clone(),
                                    _ => format!("{base}_{ordinal}"),
                                })
                                .find(|name| !taken.contains(name))
                                .unwrap_or(base.clone());
                            event.name = (name != base).then(|| name.clone());
                            existing.config.events.push(event);
                            name
                        }
                    };
                }
                continue;
            }
            None => contracts.push(GlobalContract {
                name: source.name.clone(),
                config,
            }),
        }

        let ids = match source.chain_id {
            Some(id) => vec![id],
            None => template_chain_ids.clone(),
        };
        for chain_id in ids {
            // A template's network has to be one a data source already put on
            // the config: only `dataSources` open a chain. Naming any other
            // leaves the template attached to nothing, so nothing it creates is
            // ever indexed — silently, since the translation otherwise
            // succeeds.
            let Some(chain) = chains.get_mut(&chain_id) else {
                report.unsupported(
                    format!(
                        "the template \"{}\" on network \"{}\", which no data source indexes",
                        source.name,
                        source.network.as_deref().unwrap_or("")
                    ),
                    format!("subgraph.yaml → templates → {}", source.name),
                );
                continue;
            };
            if let Some(chain_contracts) = chain.contracts.as_mut() {
                chain_contracts.push(ChainContract {
                    name: source.name.clone(),
                    address: NormalizedList::from(Vec::<String>::new()),
                    start_block: None,
                    config: None,
                });
            }
        }
    }

    report.into_result()?;

    if chains.is_empty() {
        return Err(anyhow!(
            "subgraph.yaml declares no indexable data source. Add at least one `dataSources` \
             entry with a `network` and a contract address."
        ));
    }

    // One endpoint, and nothing in it says which chain it serves. Over several
    // chains the runtime would send every eth_call, getBalance and block
    // lookup to it and answer the mapping with another chain's state — so this
    // is refused here rather than answered wrongly at runtime.
    if !rpc_urls.is_empty() && chains.len() > 1 {
        let networks = chains
            .keys()
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        return Err(anyhow!(
            "{RPC_ENV_VAR} names one endpoint, but this subgraph indexes {} chains ({networks}). \
             An RPC call from a mapping has no way to pick between them. Index one network per \
             project, or drop {RPC_ENV_VAR} and let HyperSync serve every chain.",
            chains.len()
        ));
    }

    // A block handler gets only the block number from envio; its header is
    // fetched afterwards, outside the reorg guard that validates event blocks
    // (spec/BLOCK_HASH.md). So a chain whose block handlers read the header
    // trails its head by the reorg depth, where envio itself assumes nothing
    // reorgs. `ENVIO_SUBGRAPH_BLOCK_LAG` overrides the depth; 0 turns it off.
    let mut block_header_lag: BTreeMap<u64, u32> = BTreeMap::new();
    for source in manifest.all_sources() {
        let handlers: Vec<String> = source
            .block_handlers
            .iter()
            .map(|handler| handler.handler.clone())
            .collect();
        if handlers.is_empty() || !usage::block_handlers_read_headers(mapping_sources, &handlers) {
            continue;
        }
        let chain_ids: Vec<u64> = match source.chain_id {
            Some(id) => vec![id],
            None => chains.keys().cloned().collect(),
        };
        for id in chain_ids {
            let lag = std::env::var(BLOCK_LAG_ENV_VAR)
                .ok()
                .and_then(|raw| raw.trim().parse::<u32>().ok())
                .or_else(|| get_max_reorg_depth_from_id(id))
                .unwrap_or(DEFAULT_MAX_REORG_DEPTH);
            if lag > 0 {
                block_header_lag.insert(id, lag);
                if let Some(chain) = chains.get_mut(&id) {
                    chain.block_lag = Some(chain.block_lag.unwrap_or(0).max(lag));
                }
            }
        }
    }

    let human_config = HumanConfig {
        base: BaseConfig {
            name: project_name.to_string(),
            description: None,
            schema: None,
            handlers: None,
            full_batch_size: calling_batch_size(mapping_sources),
            storage: None,
            disable_default_cross_chain: None,
        },
        ecosystem: None,
        contracts: Some(contracts),
        chains: chains.into_values().collect(),
        rollback_on_reorg: None,
        save_full_history: None,
        field_selection: None,
        raw_events: None,
        // graph-ts renders addresses lowercase, and id/derived-key parity
        // depends on it. Not overridable.
        address_format: Some(AddressFormat::Lowercase),
        // graph-ts `Bytes` is a `Uint8Array`, so a `Bytes` column holds the
        // bytes themselves rather than a hex rendering of them.
        bytes_type: Some(BytesType::Uint8Array),
    };

    let accessor = |name: &String| (name.clone(), name.capitalize());
    let entity_accessors = schema.entity_fields.keys().map(accessor).collect();
    let contract_accessors = manifest
        .all_sources()
        .map(|source| accessor(&source.name))
        .collect();

    Ok(Translation {
        schema_text: schema.text.clone(),
        runtime: SubgraphRuntimeConfig {
            manifest,
            schema,
            entity_accessors,
            contract_accessors,
            root: root.to_string(),
            rpc_urls,
            block_header_lag,
        },
        human_config,
    })
}

#[cfg(test)]
mod generated_code_tests {
    use super::*;
    use tempdir::TempDir;

    fn project(files: &[(&str, &str)]) -> TempDir {
        let dir = TempDir::new("envio_subgraph_generated").unwrap();
        for (path, source) in files {
            let file = dir.path().join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, source).unwrap();
        }
        dir
    }

    #[test]
    fn finds_generated_code_past_a_reexporting_entry() {
        let dir = project(&[
            (
                "pkg/src/index.ts",
                "export { handle } from \"./handlers/a\";\n",
            ),
            (
                "pkg/src/handlers/a.ts",
                "import { T } from \"../types/schema\";\n",
            ),
        ]);
        let root = dir.path().join("pkg");
        assert_eq!(
            pathdiff_relative(
                &generated_dir(&root, &["./src/index.ts".to_string()]),
                &root
            ),
            "src/types"
        );
        assert!(!graph_cli_installed(&root));
        std::fs::create_dir_all(dir.path().join("node_modules/@graphprotocol/graph-cli")).unwrap();
        std::fs::write(
            dir.path()
                .join("node_modules/@graphprotocol/graph-cli/package.json"),
            "{}",
        )
        .unwrap();
        assert!(graph_cli_installed(&root));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_parsing::human_config::evm::{For, Rpc};

    /// Mapping source the usage scan can't account for, so these cases see the
    /// full selection rather than a narrowed one.
    fn ambiguous() -> Vec<String> {
        vec!["helper(event.transaction); helper(event.block);".to_string()]
    }

    const MANIFEST: &str = r#"
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
        - event: UpdatedGravatar(uint256,address,string,string)
          handler: handleUpdatedGravatar
          receipt: true
      file: ./src/gravity.ts
templates:
  - kind: ethereum/contract
    name: Wallet
    network: mainnet
    source:
      abi: Wallet
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities: []
      abis:
        - name: Wallet
          file: ./abis/Wallet.json
      eventHandlers:
        - event: Deposit(indexed address,uint256)
          handler: handleDeposit
      file: ./src/wallet.ts
"#;

    const SCHEMA: &str = r#"
type Gravatar @entity {
  id: Bytes!
  owner: Bytes!
  displayName: String!
}
"#;

    // A static filter becomes the handler's `where`; one on a parameter the log
    // carries only as a hash is refused, naming that topic and why.
    #[test]
    fn refuses_a_topic_filter_only_on_a_hashed_parameter() {
        let manifest = MANIFEST.replace(
            "        - event: NewGravatar(uint256,address,string,string)\n          handler: handleNewGravatar",
            "        - event: Named(indexed string,indexed address)\n          handler: handleNamed\n          topic1: [\"0x01\"]\n          topic2: [\"0x02\"]",
        );
        let files = HashMap::from([(
            "./abis/Gravity.json".to_string(),
            r#"[{"type":"event","name":"Named","anonymous":false,"inputs":[
              {"name":"label","type":"string","indexed":true},
              {"name":"owner","type":"address","indexed":true}]}]"#
                .to_string(),
        )]);
        let error = translate(
            &manifest,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &files,
            &ambiguous(),
        )
        .unwrap_err()
        .to_string();
        assert_eq!(
            (
                error.contains(
                    "topic filters on a string indexed parameter, which the log carries only as a hash"
                ),
                error.contains("\"handleNamed\" → topic1"),
                error.contains("topic2"),
            ),
            (true, true, false),
            "{error}"
        );
    }

    #[test]
    fn maps_the_ethereum_network_alias_to_chain_1() {
        let yaml = MANIFEST.replace("network: mainnet", "network: ethereum");
        let translation = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        assert_eq!(translation.human_config.chains[0].id, 1);
    }

    #[test]
    fn refuses_to_run_when_a_data_source_has_call_handlers() {
        let manifest = MANIFEST.replace(
            "      eventHandlers:",
            "      callHandlers:\n        - function: setGravatar(string)\n          handler: \
             handleSetGravatar\n      eventHandlers:",
        );
        let error = translate(
            &manifest,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap_err()
        .to_string();
        assert_eq!(
            (
                error.contains("doesn't support call handlers"),
                error.contains("callHandlers → \"handleSetGravatar\""),
            ),
            (true, true)
        );
    }

    #[test]
    fn maps_hyperevm_to_hyperliquid() {
        let yaml = MANIFEST.replace("network: mainnet", "network: hyperevm");
        let translation = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        assert_eq!(translation.human_config.chains[0].id, 999);
    }

    #[test]
    fn builds_an_evm_config_from_a_manifest() {
        let translation = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        let config = &translation.human_config;
        let chain = &config.chains[0];
        let contract_names: Vec<&str> = config
            .contracts
            .as_ref()
            .unwrap()
            .iter()
            .map(|c| c.name.as_str())
            .collect();
        let chain_contracts = chain.contracts.as_ref().unwrap();

        assert_eq!(
            (
                config.base.name.as_str(),
                config.address_format.clone(),
                contract_names,
                chain.id,
                chain.start_block,
                chain_contracts.len(),
                Vec::from(chain_contracts[0].address.clone()),
                chain_contracts[1].name.as_str(),
                Vec::from(chain_contracts[1].address.clone()),
            ),
            (
                "gravatar",
                Some(AddressFormat::Lowercase),
                vec!["Gravity", "Wallet"],
                1,
                StartBlock::Number(6175244),
                2,
                vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()],
                "Wallet",
                Vec::<String>::new(),
            )
        );
    }

    #[test]
    fn carries_a_data_source_end_block_onto_its_chain() {
        let single = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();

        let bounded_source = MANIFEST.replace(
            "      startBlock: 6175244",
            "      startBlock: 6175244\n      endBlock: 6180000",
        );
        let bounded = translate(
            &bounded_source,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();

        assert_eq!(
            (
                single.human_config.chains[0].end_block,
                bounded.human_config.chains[0].end_block,
            ),
            (None, Some(6180000))
        );
    }

    #[test]
    fn a_block_handler_that_reads_the_header_holds_its_chain_back() {
        let manifest = MANIFEST.replacen(
            "      file: ./src/gravity.ts",
            "      blockHandlers:\n        - handler: handleBlock\n      file: ./src/gravity.ts",
            1,
        );
        let lag = |source: &str| {
            let translation = translate(
                &manifest,
                SCHEMA,
                "gravatar",
                None,
                ".",
                &HashMap::new(),
                &[source.to_string()],
            )
            .unwrap();
            (
                translation.human_config.chains[0].block_lag,
                translation.runtime.block_header_lag.get(&1).copied(),
            )
        };
        let depth = Some(DEFAULT_MAX_REORG_DEPTH);

        assert_eq!(
            lag("export function handleBlock(block: ethereum.Block): void { block.number; block.timestamp; }"),
            (None, None)
        );
        assert_eq!(
            lag("export function handleBlock(block: ethereum.Block): void { new Block(block.hash); }"),
            (depth, depth)
        );
    }

    #[test]
    fn a_mapping_that_calls_contracts_batches_fewer_events() {
        let batch_size = |source: &str| {
            translate(
                MANIFEST,
                SCHEMA,
                "gravatar",
                None,
                ".",
                &HashMap::new(),
                &[source.to_string()],
            )
            .unwrap()
            .human_config
            .base
            .full_batch_size
        };
        assert_eq!(
            (
                batch_size("let token = Token.bind(event.address); token.try_decimals();"),
                batch_size("store.set('A', 'b', entity);"),
            ),
            (Some(CALLING_BATCH_SIZE), None)
        );
    }

    #[test]
    fn selects_receipt_fields_only_where_declared() {
        let translation = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        let gravity = &translation.human_config.contracts.as_ref().unwrap()[0];
        let plain = gravity.config.events[0]
            .field_selection
            .as_ref()
            .unwrap()
            .transaction_fields
            .as_ref()
            .unwrap();
        let with_receipt = gravity.config.events[1]
            .field_selection
            .as_ref()
            .unwrap()
            .transaction_fields
            .as_ref()
            .unwrap();

        assert_eq!(
            (
                plain.contains(&TransactionField::Status),
                with_receipt.contains(&TransactionField::Status),
                with_receipt.contains(&TransactionField::LogsBloom),
                with_receipt.contains(&TransactionField::ContractAddress),
            ),
            (false, true, true, true)
        );
    }

    // Balancer names FXPoolDeployer both a data source and a template over the
    // same mapping: one fixed deployment, plus the ones it announces.
    #[test]
    fn folds_a_template_into_the_data_source_it_shares_a_name_with() {
        // The template renamed onto the data source's name, sharing its ABI.
        let manifest = MANIFEST
            .replace("    name: Wallet", "    name: Gravity")
            .replace("      abi: Wallet", "      abi: Gravity")
            .replace("        - name: Wallet", "        - name: Gravity")
            .replace("./abis/Wallet.json", "./abis/Gravity.json");
        let translation = translate(
            &manifest,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        let contracts = translation.human_config.contracts.as_ref().unwrap();

        assert_eq!(
            contracts
                .iter()
                .map(|contract| (
                    contract.name.clone(),
                    contract
                        .config
                        .events
                        .iter()
                        .map(|event| event.event.clone())
                        .collect::<Vec<_>>()
                ))
                .collect::<Vec<_>>(),
            vec![(
                "Gravity".to_string(),
                vec![
                    "NewGravatar".to_string(),
                    "UpdatedGravatar".to_string(),
                    "Deposit".to_string(),
                ]
            )]
        );
    }

    // A mapping can read the transaction's hash, index and root off
    // `event.receipt` alone, which the usage scan doesn't count as a read of
    // `event.transaction`.
    #[test]
    fn selects_what_the_receipt_reads_off_the_transaction() {
        let mappings = vec!["let receipt = event.receipt!; receipt.transactionHash;".to_string()];
        let translation = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &mappings,
        )
        .unwrap();
        let selection = translation.human_config.contracts.as_ref().unwrap()[0]
            .config
            .events[1]
            .field_selection
            .clone()
            .unwrap();

        assert_eq!(
            selection,
            FieldSelection {
                transaction_fields: Some(vec![
                    TransactionField::Hash,
                    TransactionField::TransactionIndex,
                    TransactionField::Root,
                    TransactionField::Status,
                    TransactionField::GasUsed,
                    TransactionField::CumulativeGasUsed,
                    TransactionField::LogsBloom,
                    TransactionField::ContractAddress,
                ]),
                block_fields: Some(vec![]),
            }
        );
    }

    #[test]
    fn selects_only_what_the_mappings_read() {
        let mappings = vec![
            "entity.hash = event.transaction.hash; entity.time = event.block.timestamp;"
                .to_string(),
        ];
        let translation = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &mappings,
        )
        .unwrap();
        let selection = translation.human_config.contracts.as_ref().unwrap()[0]
            .config
            .events[0]
            .field_selection
            .clone()
            .unwrap();

        assert_eq!(
            selection,
            FieldSelection {
                transaction_fields: Some(vec![TransactionField::Hash]),
                block_fields: Some(vec![]),
            }
        );
    }

    // ENVIO_SUBGRAPH_RPC is one endpoint and says nothing about which chain it
    // serves, so over several chains the runtime would answer an eth_call with
    // another chain's state.
    #[test]
    fn refuses_an_rpc_endpoint_across_several_chains() {
        // Gravity twice, on two networks, and no templates — so the only thing
        // under test is the endpoint.
        let one_source = MANIFEST.split("templates:").next().unwrap();
        let second = one_source
            .split("dataSources:")
            .nth(1)
            .unwrap()
            .replace("network: mainnet", "network: matic")
            .replace("name: Gravity", "name: GravityOnPolygon");
        let two_chains = format!("{one_source}{second}");

        let err = translate(
            &two_chains,
            SCHEMA,
            "gravatar",
            Some("https://rpc.example.test"),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .expect_err("expected one endpoint over two chains to be refused");

        let message = format!("{err:#}");
        assert!(
            message.contains("names one endpoint, but this subgraph indexes 2 chains"),
            "unexpected error: {message}"
        );
    }

    // Only `dataSources` open a chain, so a template on any other network is
    // attached to nothing and never fires.
    #[test]
    fn refuses_a_template_on_a_network_no_data_source_indexes() {
        let yaml = MANIFEST.replace(
            "    name: Wallet\n    network: mainnet",
            "    name: Wallet\n    network: matic",
        );
        let err = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .expect_err("expected an unindexed template network to be refused");

        let message = format!("{err:#}");
        assert!(
            message.contains("the template \"Wallet\" on network \"matic\""),
            "unexpected error: {message}"
        );
    }

    #[test]
    fn injects_the_rpc_env_var_into_every_chain() {
        let translation = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            Some(r#"{"url":"https://rpc.example.test","for":"fallback"}"#),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        assert_eq!(
            translation.human_config.chains[0].rpc.clone(),
            Some(RpcSelection::Single(Rpc {
                url: "https://rpc.example.test".to_string(),
                source_for: Some(For::Fallback),
                ws: None,
                headers: None,
                initial_block_interval: None,
                backoff_multiplicative: None,
                acceleration_additive: None,
                interval_ceiling: None,
                backoff_millis: None,
                fallback_stall_timeout: None,
                query_timeout_millis: None,
                polling_interval: None,
            }))
        );
    }

    #[test]
    fn accepts_an_array_mixing_urls_and_entries() {
        let parsed = parse_rpc_env(
            r#"["https://a.example.test", {"url":"https://b.example.test","for":"fallback"}]"#,
        )
        .unwrap();
        let RpcSelection::List(rpcs) = parsed else {
            panic!("expected a list, got {parsed:?}");
        };
        assert_eq!(
            rpcs.iter()
                .map(|rpc| (rpc.url.as_str(), rpc.source_for.clone()))
                .collect::<Vec<_>>(),
            vec![
                ("https://a.example.test", None),
                ("https://b.example.test", Some(For::Fallback)),
            ]
        );
    }

    #[test]
    fn accepts_a_bare_rpc_url() {
        assert_eq!(
            parse_rpc_env("  https://rpc.example.test ").unwrap(),
            RpcSelection::Url("https://rpc.example.test".to_string())
        );
    }

    #[test]
    fn reports_manifest_and_schema_findings_together() {
        let manifest = MANIFEST.replace(
            "      file: ./src/gravity.ts",
            "      callHandlers:\n        - function: setGravatar(string)\n          handler: \
             handleSetGravatar\n      file: ./src/gravity.ts",
        );
        let error = translate(
            &manifest,
            "type Gravatar @entity { id: ID! bad: NotAType! }",
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap_err()
        .to_string();

        assert_eq!(
            (
                error.contains("doesn't support call handlers"),
                error.contains("doesn't know the type NotAType"),
            ),
            (true, true)
        );
    }
}

#[cfg(test)]
mod project_tests {
    use crate::config_parsing::system_config::SystemConfig;
    use crate::project_paths::ParsedProjectPaths;
    use std::fs;

    /// A subgraph project has no config.yaml, so `subgraph.yaml` beside it is
    /// what the CLI keys off — which is what makes `dev`/`start`/`codegen` work
    /// inside one unchanged.
    #[test]
    fn parses_a_subgraph_project_from_disk() {
        let dir = tempdir::TempDir::new("envio-subgraph").unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("abis")).unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(
            root.join("abis/Gravity.json"),
            r#"[{"type":"event","name":"NewGravatar","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]"#,
        )
        .unwrap();
        fs::write(
            root.join("src/gravity.ts"),
            "export function handleNewGravatar() {}",
        )
        .unwrap();
        fs::write(
            root.join("schema.graphql"),
            "type Gravatar @entity {\n  id: Bytes!\n  owner: Bytes!\n}\n",
        )
        .unwrap();
        fs::write(
            root.join("subgraph.yaml"),
            r#"
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
        - event: NewGravatar(uint256)
          handler: handleNewGravatar
      file: ./src/gravity.ts
"#,
        )
        .unwrap();

        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let json = config.to_public_config_json(false).unwrap();

        assert_eq!(
            (
                config.subgraph.is_some(),
                config.lowercase_addresses,
                config.contracts.contains_key("Gravity"),
                config.schema.entities.contains_key("Gravatar"),
                json.contains("\"subgraph\""),
                json.contains("\"mappingFile\": \"./src/gravity.ts\""),
            ),
            (true, true, true, true, true, true)
        );
    }

    #[test]
    fn tells_the_user_to_generate_subgraph_yaml_from_a_template() {
        let dir = tempdir::TempDir::new("envio-subgraph-template").unwrap();
        let root = dir.path();
        fs::write(root.join("subgraph.template.yaml"), "specVersion: 0.0.2\n").unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = SystemConfig::parse_from_project_files(&project_paths)
            .unwrap_err()
            .to_string();
        assert_eq!(
            (
                err.contains("Found subgraph.template.yaml but no subgraph.yaml"),
                err.contains("graph build --network"),
            ),
            (true, true)
        );
    }
}
