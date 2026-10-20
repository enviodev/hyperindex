//! Subgraph mode: run an unmodified subgraph project on HyperIndex.
//!
//! The CLI detects `subgraph.yaml`, translates the manifest into an envio
//! config and the schema into an envio schema, and points the handler entry at
//! the subgraph runtime that ships inside the `envio` package.

pub mod abi;
pub mod assemblyscript;
pub mod codegen;
pub mod creates;
pub mod diff;
pub mod errors;
pub mod manifest;
pub mod mustache;
pub mod npm_fetch;
pub mod path_case;
pub mod render;
pub mod schema;
pub mod usage;
pub mod workspace;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

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
    /// The manifest's file name within `root`, which `graph codegen` is run on.
    pub manifest_file: String,
    /// How far, per chain, a block handler that reads header fields trails the
    /// head: the runtime refuses to serve a header from inside that distance.
    pub block_header_lag: BTreeMap<u64, u32>,
    /// Chains HyperSync doesn't serve. The runtime reads their block headers
    /// and receipts from RPC alone, without first asking a host that has no
    /// such chain.
    pub rpc_only_chains: Vec<u64>,
    /// Warnings the runtime logs at startup: what the translation left out
    /// and why.
    pub notices: Vec<String>,
    /// Set when envio wrote the manifest from the repo's template (§6d), so the
    /// runtime says so and the codegen script doesn't render it over again.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rendered_manifest: Option<RenderedManifest>,
    /// Files the manifest names, as written and where they are read from:
    /// another case of the same path, or an absolute path in the npm package
    /// envio fetched (§6d). graph-cli's copy of the manifest names them so.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub path_fixes: Vec<(String, String)>,
    /// The network networks.json was applied for when none was picked: the
    /// one the repo's own build passes `graph build --network` (§6d).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub build_network: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderedManifest {
    pub script: String,
    /// The scripts that one runs through `npm run`: the codegen script
    /// doesn't run any of them again either.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub inlined: Vec<String>,
    pub network: String,
    pub template: String,
    pub view: String,
    /// The codegen script's own steps envio ran to write the manifest, which
    /// the runtime's codegen then doesn't run again.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<String>,
    /// The commands envio ran of `script`, the one package.json script that
    /// writes the manifest (§6d).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub commands: Vec<String>,
}

pub const DEFAULT_MANIFEST: &str = "subgraph.yaml";

/// The directory a manifest's project runs from, and the manifest with its
/// paths relative to it.
///
/// graph-cli reads a manifest's paths relative to the manifest itself, and a
/// per-network manifest in a subfolder names its code `../src/…` (WOOFi's
/// `subgraphs/polygon.yaml`). The runtime loads, scans and resolves the
/// mappings and `generated/` from a single root, so the root is the closest
/// directory holding the manifest, its schema and every mapping, and each path
/// is rebased onto it. ABIs are read up front and don't widen the root (liquity
/// points at `../contracts/out`).
pub fn rebase_manifest(manifest_dir: &std::path::Path, yaml: &str) -> Result<(PathBuf, String)> {
    use crate::project_paths::path_utils::normalize_path;
    use serde_yaml::Value;

    let unchanged = || Ok((manifest_dir.to_path_buf(), yaml.to_string()));
    let Ok(mut manifest) = serde_yaml::from_str::<Value>(yaml) else {
        return unchanged();
    };
    let absolute_dir = normalize_path(
        std::env::current_dir()
            .unwrap_or_default()
            .join(manifest_dir),
    );
    let resolve = |path: &str| normalize_path(absolute_dir.join(path));

    let sources = |manifest: &Value| -> Vec<Value> {
        ["dataSources", "templates"]
            .iter()
            .filter_map(|key| manifest.get(*key).and_then(Value::as_sequence))
            .flatten()
            .cloned()
            .collect()
    };
    let mut run_files: Vec<PathBuf> = Vec::new();
    if let Some(schema) = manifest
        .get("schema")
        .and_then(|schema| schema.get("file"))
        .and_then(Value::as_str)
    {
        run_files.push(resolve(schema));
    }
    for source in sources(&manifest) {
        if let Some(file) = source
            .get("mapping")
            .and_then(|mapping| mapping.get("file"))
            .and_then(Value::as_str)
        {
            run_files.push(resolve(file));
        }
    }

    let mut root = absolute_dir.clone();
    for file in &run_files {
        let dir = file.parent().unwrap_or(file);
        while !dir.starts_with(&root) {
            match root.parent() {
                Some(parent) => root = parent.to_path_buf(),
                None => break,
            }
        }
    }
    if root == absolute_dir {
        return unchanged();
    }

    let rebase = |value: &mut Value| {
        if let Some(path) = value.as_str() {
            let relative = pathdiff::diff_paths(resolve(path), &root).unwrap_or_default();
            let relative = relative.display().to_string();
            *value = Value::String(if relative.starts_with("..") {
                relative
            } else {
                format!("./{relative}")
            });
        }
    };
    if let Some(file) = manifest
        .get_mut("schema")
        .and_then(|schema| schema.get_mut("file"))
    {
        rebase(file);
    }
    for key in ["dataSources", "templates"] {
        let Some(list) = manifest.get_mut(key).and_then(Value::as_sequence_mut) else {
            continue;
        };
        for source in list {
            let Some(mapping) = source.get_mut("mapping") else {
                continue;
            };
            if let Some(file) = mapping.get_mut("file") {
                rebase(file);
            }
            if let Some(abis) = mapping.get_mut("abis").and_then(Value::as_sequence_mut) {
                for abi in abis {
                    if let Some(file) = abi.get_mut("file") {
                        rebase(file);
                    }
                }
            }
        }
    }
    Ok((root, serde_yaml::to_string(&manifest)?))
}

/// `graph build --network <name>`: which entry of `networks.json` the manifest
/// is built for.
pub const NETWORK_ENV_VAR: &str = "ENVIO_SUBGRAPH_NETWORK";

/// `graph build --network-file <path>`: the networks file, project-relative,
/// when it isn't networks.json.
pub const NETWORK_FILE_ENV_VAR: &str = "ENVIO_SUBGRAPH_NETWORK_FILE";

/// The manifest `graph build --network <network>` writes from `networks.json`
/// (graph-cli `updateSubgraphNetwork`): every data source moves to the network
/// and takes its `source` fields from its entry there, and every template moves
/// to the network.
pub fn apply_network(manifest_yaml: &str, networks_json: &str, network: &str) -> Result<String> {
    use serde_yaml::Value;
    let networks: serde_json::Value = serde_json::from_str(networks_json)
        .map_err(|err| anyhow!("networks.json is not valid JSON: {err}"))?;
    let Some(entries) = networks.get(network).and_then(|value| value.as_object()) else {
        return Err(anyhow!(
            "{NETWORK_ENV_VAR} names the network '{network}', which networks.json has no entry \
             for. It has: {}.",
            networks
                .as_object()
                .map(|all| all.keys().cloned().collect::<Vec<_>>().join(", "))
                .unwrap_or_default()
        ));
    };
    let mut manifest: Value = serde_yaml::from_str(manifest_yaml)
        .map_err(|err| anyhow!("Failed to read the subgraph manifest: {err}"))?;
    let network_value = Value::String(network.to_string());

    if let Some(sources) = manifest
        .get_mut("dataSources")
        .and_then(Value::as_sequence_mut)
    {
        for source in sources {
            let name = source
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let entry = entries
                .get(&name)
                .and_then(|entry| entry.as_object())
                .ok_or_else(|| {
                    anyhow!(
                    "The data source '{name}' has no entry under '{network}' in networks.json, \
                     which `graph build --network {network}` requires too."
                )
                })?;
            let changed = source.get("network") != Some(&network_value)
                || entry.iter().any(|(key, value)| {
                    source.get("source").and_then(|fields| fields.get(key))
                        != serde_yaml::to_value(value).ok().as_ref()
                });
            if !changed {
                continue;
            }
            let mut fields = serde_yaml::Mapping::new();
            if let Some(abi) = source.get("source").and_then(|fields| fields.get("abi")) {
                fields.insert(Value::String("abi".to_string()), abi.clone());
            }
            for (key, value) in entry {
                fields.insert(Value::String(key.clone()), serde_yaml::to_value(value)?);
            }
            if let Some(map) = source.as_mapping_mut() {
                map.insert(Value::String("network".to_string()), network_value.clone());
                map.insert(Value::String("source".to_string()), Value::Mapping(fields));
            }
        }
    }
    if let Some(templates) = manifest
        .get_mut("templates")
        .and_then(Value::as_sequence_mut)
    {
        for template in templates.iter_mut().filter_map(Value::as_mapping_mut) {
            template.insert(Value::String("network".to_string()), network_value.clone());
        }
    }
    Ok(serde_yaml::to_string(&manifest)?)
}

/// An event handler whose event the data source's ABI doesn't declare, as
/// graph-cli's validation reports it ("Event with signature … not present in
/// ABI"), or `None`. envio's own check reported it as a translation gap.
pub fn undeclared_events(manifest_yaml: &str, files: &HashMap<String, String>) -> Option<String> {
    let mut discard = Report::new();
    let manifest = manifest::parse(manifest_yaml, &mut discard)?;
    let mut messages = Vec::new();
    for source in manifest.all_sources() {
        let Some((abi, path)) = source
            .abi
            .as_ref()
            .and_then(|abi| Some((abi, source.abis.get(abi)?)))
        else {
            continue;
        };
        let Some(abi_json) = files
            .get(path)
            .or_else(|| files.get(path.trim_start_matches("./")))
        else {
            continue;
        };
        for handler in &source.event_handlers {
            let Some((false, events)) = abi::declared_events(&handler.event, abi_json) else {
                continue;
            };
            let kind = if source.is_template {
                "template"
            } else {
                "data source"
            };
            messages.push(format!(
                "The {kind} \"{}\" handles the event {}, which its ABI \"{abi}\" ({path}) doesn't \
                 declare. The ABI's events: {}. graph-cli refuses the manifest the same way \
                 (\"Event with signature … not present in ABI\"): the manifest and the ABI are \
                 from different versions of the contract.",
                source.name,
                handler.event,
                if events.is_empty() {
                    "none".to_string()
                } else {
                    events.join(", ")
                }
            ));
        }
    }
    (!messages.is_empty()).then(|| messages.join("\n"))
}

/// The ABI files the manifest's data sources and templates decode with that
/// aren't among `files`, as one message naming each, or `None`. envio's own
/// check names only a "Virtual config file", once per run.
pub fn missing_abi_files(
    manifest_yaml: &str,
    files: &HashMap<String, String>,
    root: &std::path::Path,
) -> Option<String> {
    let mut discard = Report::new();
    let manifest = manifest::parse(manifest_yaml, &mut discard)?;
    let mut lines = Vec::new();
    for source in manifest.all_sources() {
        let Some(path) = source.abi.as_ref().and_then(|abi| source.abis.get(abi)) else {
            continue;
        };
        if files.contains_key(path) || files.contains_key(path.trim_start_matches("./")) {
            continue;
        }
        let line = format!("  {path}, the ABI of \"{}\"", source.name);
        if !lines.contains(&line) {
            lines.push(line);
        }
    }
    if lines.is_empty() {
        return None;
    }
    let mut hints: Vec<String> = Vec::new();
    for source in manifest.all_sources() {
        let Some(path) = source.abi.as_ref().and_then(|abi| source.abis.get(abi)) else {
            continue;
        };
        if files.contains_key(path) || files.contains_key(path.trim_start_matches("./")) {
            continue;
        }
        if let Some(hint) = abi_build_step(root, path) {
            if !hints.contains(&hint) {
                hints.push(hint);
            }
        }
    }
    let mut message = format!(
        "These ABI files the manifest names don't exist under {}:\n{}\n\
         The manifest's paths are resolved against its own directory, as graph-cli \
         resolves them. {}",
        root.canonicalize()
            .unwrap_or_else(|_| root.to_path_buf())
            .display(),
        lines.join("\n"),
        if hints.is_empty() {
            "If a build step writes them (forge build, a git submodule, a copy script), run it \
             first."
                .to_string()
        } else {
            "envio doesn't build contracts or run the repo's scripts for them; the step that \
             writes them is:"
                .to_string()
        }
    );
    for hint in &hints {
        message.push('\n');
        message.push_str(hint);
    }
    // A manifest written on macOS can name `WrappedPunks.json` for a file
    // committed as `wrappedpunks.json` (CryptoPunks); only a case-sensitive
    // filesystem tells them apart.
    for source in manifest.all_sources() {
        let Some(path) = source.abi.as_ref().and_then(|abi| source.abis.get(abi)) else {
            continue;
        };
        let wanted = root.join(path);
        let (Some(dir), Some(name)) = (wanted.parent(), wanted.file_name()) else {
            continue;
        };
        let name = name.to_string_lossy().to_lowercase();
        let mut found: Vec<String> = std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(|entry| entry.ok())
                    .map(|entry| entry.file_name().to_string_lossy().to_string())
                    .filter(|entry| entry.to_lowercase() == name && !wanted.ends_with(entry))
                    .collect()
            })
            .unwrap_or_default();
        found.sort();
        let hint = match found.as_slice() {
            [] => continue,
            [one] => format!("\n{path} differs only in case from {one}, which does exist."),
            several => format!(
                "\n{path} differs only in case from {}, which do exist: envio can't tell \
                 which one the manifest means.",
                several.join(", ")
            ),
        };
        if !message.contains(&hint) {
            message.push_str(&hint);
        }
    }
    Some(message)
}

/// The step that writes a missing ABI file, when the repo says: a
/// package.json script that writes its directory (kleros-v2's `sync-abis`),
/// a git submodule not checked out, the Foundry or Hardhat project whose
/// build output it is (liquity's `../contracts/out/`), or a package the
/// install didn't provide.
fn abi_build_step(root: &std::path::Path, path: &str) -> Option<String> {
    use crate::project_paths::path_utils::normalize_path;
    let relative = std::path::Path::new(path);
    // The first directory of the path that doesn't exist: what the step writes.
    let mut missing_dir: Option<PathBuf> = None;
    let mut so_far = PathBuf::new();
    for component in relative.parent()?.components() {
        so_far.push(component);
        if !matches!(
            component,
            std::path::Component::CurDir | std::path::Component::ParentDir
        ) && !root.join(&so_far).is_dir()
        {
            missing_dir = Some(so_far.clone());
            break;
        }
    }
    if let Some(dir) = &missing_dir {
        let name = dir.file_name()?.to_string_lossy().to_string();
        let shown = format!("{}/", dir.display());
        // kleros-v2's manifest is in subgraph/core, its scripts in subgraph/.
        let found = root
            .ancestors()
            .take(4)
            .find_map(|dir| render::scripts_mentioning(dir, &name).into_iter().next());
        if let Some((script, text)) = found {
            let run = if text.chars().count() <= 60 {
                format!(" ({text})")
            } else {
                String::new()
            };
            return Some(format!(
                "The package.json script \"{script}\"{run} writes {shown}: run it, then start \
                 envio again."
            ));
        }
    }
    let components: Vec<String> = relative
        .components()
        .map(|component| component.as_os_str().to_string_lossy().to_string())
        .collect();
    if let Some(index) = components.iter().position(|part| part == "node_modules") {
        let package = match components.get(index + 1) {
            Some(scope) if scope.starts_with('@') => {
                format!("{scope}/{}", components.get(index + 2)?)
            }
            Some(name) => name.clone(),
            None => return None,
        };
        return Some(format!(
            "{package} isn't installed: the ABI is part of that package, so install the \
             project's dependencies first."
        ));
    }
    for (index, part) in components.iter().enumerate() {
        let project: PathBuf = components[..index].iter().collect();
        let project_dir = normalize_path(root.join(&project));
        let shown = if project.as_os_str().is_empty() {
            ".".to_string()
        } else {
            project.display().to_string()
        };
        let is_submodule_dir = project_dir.is_dir()
            && std::fs::read_dir(&project_dir).is_ok_and(|mut entries| entries.next().is_none());
        if is_submodule_dir {
            return Some(format!(
                "{shown} is empty, a git submodule not checked out: `git submodule update \
                 --init --recursive`, then build it."
            ));
        }
        let (tool, writes) = if part == "out" && project_dir.join("foundry.toml").exists() {
            ("Foundry", "`forge build`")
        } else if part == "artifacts"
            && [
                "hardhat.config.ts",
                "hardhat.config.js",
                "hardhat.config.cjs",
            ]
            .iter()
            .any(|config| project_dir.join(config).exists())
        {
            ("Hardhat", "`npx hardhat compile`")
        } else {
            continue;
        };
        return Some(format!(
            "{shown} is a {tool} project, and {writes} there writes {shown}/{part}/: run it, \
             then start envio again."
        ));
    }
    None
}

/// Whether a data source of the manifest names no network: one left for/// Whether a data source of the manifest names no network: one left for
/// `graph build --network` to fill in from networks.json (Ekubo, iExec).
pub fn names_no_network(yaml: &str) -> bool {
    serde_yaml::from_str::<serde_yaml::Value>(yaml)
        .ok()
        .and_then(|manifest| {
            let sources = manifest.get("dataSources")?.as_sequence()?.clone();
            Some(
                sources
                    .iter()
                    .any(|source| source.get("network").and_then(|n| n.as_str()).is_none()),
            )
        })
        .unwrap_or(false)
}

/// Whether a YAML document is a subgraph manifest rather than an envio config.
pub fn is_manifest(yaml: &str) -> bool {
    serde_yaml::from_str::<serde_yaml::Value>(yaml)
        .ok()
        .and_then(|value| {
            let map = value.as_mapping()?;
            Some(map.contains_key("specVersion") && map.contains_key("dataSources"))
        })
        .unwrap_or(false)
}

/// Subgraph manifests under `root`, project-relative: build scripts write them
/// under other names (Uniswap's `v3-subgraph.yaml`), and monorepos keep one per
/// package (`subgraphs/<name>/subgraph.yaml`).
pub fn find_manifests(root: &std::path::Path) -> Vec<String> {
    const MAX_DEPTH: usize = 3;
    const SKIPPED: &[&str] = &["node_modules", "build", "generated", "target"];
    let mut found = Vec::new();
    let mut pending = vec![(root.to_path_buf(), 0)];
    while let Some((dir, depth)) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut entries: Vec<_> = entries.filter_map(|entry| entry.ok()).collect();
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if path.is_dir() {
                if depth < MAX_DEPTH && !name.starts_with('.') && !SKIPPED.contains(&name.as_str())
                {
                    pending.push((path, depth + 1));
                }
                continue;
            }
            // `subgraph.template.yaml` is the input a render step writes the
            // manifest from, even when it holds no mustache tag yet.
            let is_yaml =
                (name.ends_with(".yaml") || name.ends_with(".yml")) && !name.contains(".template.");
            // A mustache template (`network: {{ network }}`) still parses, but
            // it is the input to the build that writes the manifest.
            let is_manifest_file = |text: String| !text.contains("{{") && is_manifest(&text);
            if is_yaml && std::fs::read_to_string(&path).is_ok_and(is_manifest_file) {
                if let Ok(relative) = path.strip_prefix(root) {
                    found.push(relative.display().to_string());
                }
            }
        }
    }
    found.sort();
    found
}

/// What to add to "config.yaml not found" so a subgraph project learns how to
/// run: name the manifests there are, or say where envio looks for one.
pub fn manifest_hint(manifests: &[String]) -> String {
    match manifests {
        [] => format!(
            "\nFor a subgraph, run envio in the directory holding {DEFAULT_MANIFEST}, or point \
             --config (or ENVIO_CONFIG) at the manifest:\n  envio start --config \
             path/to/subgraph.yaml"
        ),
        [only] => format!(
            "\nFound the subgraph manifest {only}. To index it, point --config (or ENVIO_CONFIG) \
             at it:\n  envio start --config {only}"
        ),
        [first, ..] => format!(
            "\nFound these subgraph manifests: {}. To index one, point --config (or \
             ENVIO_CONFIG) at it:\n  envio start --config {first}",
            manifests.join(", ")
        ),
    }
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
        // A mapping shipped in a dependency (@openzeppelin/subgraphs) imports the
        // generated code shipped beside it, not the tree `graph codegen` writes.
        let in_dependency = file.strip_prefix(root).is_ok_and(|relative| {
            relative
                .components()
                .any(|part| part.as_os_str() == "node_modules")
        });
        if in_dependency {
            continue;
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

/// Whether an `npm` executable is on `path`, the one the runtime fetches graph-cli with.
pub fn npm_on_path(path: Option<&std::ffi::OsStr>) -> bool {
    path.is_some_and(|path| std::env::split_paths(path).any(|dir| dir.join("npm").is_file()))
}

/// `envio codegen` and `envio start` build the generated code when it is
/// missing and graph-cli can't (Envio Cloud's builder has none, and leaves the
/// directory behind empty). `ENVIO_SUBGRAPH_CODEGEN=bundled` always writes it;
/// `graph-cli` mode falls back only to the graph-cli the runtime fetches with
/// npm when the project has none (`subgraph/toolchain.ts`); without npm it refuses.
pub fn check_generated_code(runtime: &SubgraphRuntimeConfig) -> Result<()> {
    // Absolute, so its ancestors are the directories above the project.
    let root = std::fs::canonicalize(&runtime.root)
        .unwrap_or_else(|_| std::path::PathBuf::from(&runtime.root));
    let root = root.as_path();
    let manifest_file = &root.join(&runtime.manifest_file);
    let mapping_files: Vec<String> = runtime
        .manifest
        .all_sources()
        .map(|source| source.mapping_file.clone())
        .collect();
    let generated = generated_dir(root, &mapping_files);
    let mode = codegen::CodegenMode::from_env();
    // Every generated tree has a schema.ts.
    let missing = !generated.join("schema.ts").is_file();
    if mode == codegen::CodegenMode::Bundled
        || (mode == codegen::CodegenMode::Auto && missing && !graph_cli_installed(root))
    {
        // In auto mode the runtime still has a graph-cli fetched with npm to
        // fall back on, and reports the bundled failure itself.
        return match codegen::generate(manifest_file, &generated) {
            Err(_)
                if mode == codegen::CodegenMode::Auto
                    && npm_on_path(std::env::var_os("PATH").as_deref()) =>
            {
                Ok(())
            }
            result => result.map(|_| ()),
        };
    }
    if !missing
        || graph_cli_installed(root)
        || mode != codegen::CodegenMode::GraphCli
        || npm_on_path(std::env::var_os("PATH").as_deref())
    {
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

/// The envio contract name for each data source and template name. graph-node
/// takes any string (Giveth's `WETH/GIV LP`, Sablier's `SablierV1.0.0`); envio
/// generates code from it, so anything but an identifier is spelled with `_`
/// instead, suffixed if that collides. A data source and a template sharing a
/// name share it here too, which is what folds them together.
fn contract_names(manifest: &Manifest) -> HashMap<String, String> {
    let is_identifier = |name: &str| {
        name.chars()
            .next()
            .is_some_and(|first| !first.is_ascii_digit())
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
    };
    let mut taken: HashSet<String> = manifest
        .all_sources()
        .filter(|source| is_identifier(&source.name))
        .map(|source| source.name.clone())
        .collect();
    let mut names = HashMap::new();
    for source in manifest.all_sources() {
        if names.contains_key(&source.name) {
            continue;
        }
        let name = if is_identifier(&source.name) {
            source.name.clone()
        } else {
            let mut base: String = source
                .name
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
                .collect();
            if !is_identifier(&base) {
                base = format!("_{base}");
            }
            let name = (1..)
                .map(|ordinal| match ordinal {
                    1 => base.clone(),
                    _ => format!("{base}_{ordinal}"),
                })
                .find(|name| !taken.contains(name))
                .unwrap_or(base);
            taken.insert(name.clone());
            name
        };
        names.insert(source.name.clone(), name);
    }
    names
}

/// Every call trigger is an envio event with this prefix: envio has no call
/// type, and a call is one more thing that happens at a position in a block.
/// The source that fetches traces produces these items, so nothing downstream of
/// the fetch (partitioning, ordering, the register pass, rollback) tells them
/// from a log. No log ever carries one's topic.
pub const CALL_EVENT_PREFIX: &str = "__envio_call_";

/// The call trigger for every call to the address when a `filter: call` block
/// handler asks for it.
pub const CALL_ANY_EVENT: &str = "__envio_call_any";

/// What a call item carries as its event params: the call's raw input and
/// output and who made it, decoded by the runtime from the function's ABI.
const CALL_EVENT_PARAMS: &str =
    "bytes callInput, bytes callOutput, address callFrom, uint256 callValue, uint256 callGasUsed";

/// graph-node reads the selector off the keccak of the signature as the
/// manifest spells it.
pub fn function_selector(function: &str) -> [u8; 4] {
    let hash = alloy_primitives::keccak256(function.as_bytes());
    [hash[0], hash[1], hash[2], hash[3]]
}

fn call_event_name(function: &str) -> String {
    let selector = function_selector(function);
    let name = function.split('(').next().unwrap_or_default().trim();
    format!(
        "{CALL_EVENT_PREFIX}{:02x}{:02x}{:02x}{:02x}_{name}",
        selector[0], selector[1], selector[2], selector[3]
    )
}

fn call_event_config(name: &str) -> EventConfig {
    EventConfig {
        event: format!("{name}({CALL_EVENT_PARAMS})"),
        name: None,
        // The source builds the block and transaction of a call itself.
        field_selection: Some(FieldSelection {
            transaction_fields: Some(vec![]),
            block_fields: Some(vec![]),
        }),
        topic0: None,
    }
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
    notices: &mut Vec<String>,
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

    // A log holds at most four topics, the first the event signature's hash,
    // so an event with more than three indexed parameters never decodes from
    // one and graph-node skips its handler for every log (data_source.rs,
    // "Skipping handler because the event parameters do not match").
    source.event_handlers.retain(|handler| {
        let indexed = abi::event_inputs(&handler.event, abi_json.as_deref())
            .iter()
            .filter(|input| input.indexed)
            .count();
        if indexed <= 3 {
            return true;
        }
        notices.push(format!(
            "Envio Subgraph: data source \"{source_name}\" → \"{}\" never runs: its event {} \
             declares {indexed} indexed parameters, more than the three a log has topics for, so \
             no log decodes as it. graph-node skips it for the same reason.",
            handler.handler, handler.event
        ));
        false
    });

    // An overloaded name needs a unique envio name as well as a spelled-out
    // signature: the generated routing keys off the name, and the runtime has
    // to register the handler under the same one.
    let mut resolved: Vec<(String, Option<String>, Option<String>)> = Vec::new();
    let mut ordinals: HashMap<String, usize> = HashMap::new();
    // graph-node runs every handler whose event matches a log, in manifest
    // order (`handlers_for_log`); envio runs every registration on an event,
    // so a second handler of the same event registers on the first's.
    let mut by_event: HashMap<(String, Option<String>), (String, usize)> = HashMap::new();
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
        handler.inputs = abi::event_inputs(&handler.event, abi_json.as_deref());
        if handler.topic0.is_some() {
            let location = format!(
                "data source \"{source_name}\" → eventHandlers → \"{}\" → topic0",
                handler.handler
            );
            if !abi::is_anonymous(&handler.event, abi_json.as_deref()) {
                report.unsupported(
                    "event handlers whose topic0 is not the event signature's hash on an event \
                     the ABI doesn't declare anonymous",
                    location,
                );
            } else if !handler.topics.is_empty() {
                report.unsupported(
                    "topic1-3 filters on an anonymous event matched on topic0",
                    location,
                );
            }
        }
        let key = (event.clone(), handler.topic0.clone());
        if let Some((name, _)) = by_event.get(&key) {
            handler.name = name.clone();
            continue;
        }
        let ordinal = ordinals.entry(base.clone()).or_insert(0);
        let unique = if *ordinal == 0 {
            base.clone()
        } else {
            format!("{base}_{ordinal}")
        };
        *ordinal += 1;
        handler.name = unique.clone();
        by_event.insert(key, (unique.clone(), resolved.len()));
        // The generated config needs the same unique name whenever one was
        // minted for an overload: the runtime registers under the name the
        // config carries.
        let renamed = unique != base;
        resolved.push((event, renamed.then_some(unique), handler.topic0.clone()));
    }

    let mut receipts = vec![false; resolved.len()];
    for handler in source.event_handlers.iter() {
        if handler.name.is_empty() {
            continue;
        }
        if let Some((_, index)) = by_event.values().find(|(name, _)| *name == handler.name) {
            receipts[*index] |= handler.receipt;
        }
        // The runtime turns each filter into a `where` on the indexed
        // parameter it narrows — except one hashed into its topic, whose
        // value envio can't match against.
        let indexed: Vec<_> = handler
            .inputs
            .iter()
            .filter(|input| input.indexed)
            .collect();
        for position in handler.topics.keys() {
            let location = format!(
                "data source \"{}\" → eventHandlers → \"{}\" → topic{position}",
                source.name, handler.handler
            );
            match indexed.get(position - 1) {
                None => report.unknown(
                    format!(
                        "which indexed parameter of \"{}\" topic{position} filters",
                        handler.event
                    ),
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
    }

    let mut events: Vec<EventConfig> = resolved
        .into_iter()
        .zip(receipts)
        .map(|((event, name, topic0), receipt)| EventConfig {
            event,
            name,
            field_selection: Some(field_selection_for(receipt, usage)),
            topic0,
        })
        .collect();

    // graph-node runs the first call handler whose selector matches.
    let mut selectors = HashSet::new();
    source
        .call_handlers
        .retain(|handler| selectors.insert(function_selector(&handler.function)));
    for handler in source.call_handlers.iter_mut() {
        match abi::function_params(&handler.function, abi_json.as_deref()) {
            Some((inputs, outputs)) => {
                handler.inputs = inputs;
                handler.outputs = outputs;
            }
            None => report.unknown(
                format!("a function \"{}\" in the ABI", handler.function),
                format!(
                    "data source \"{source_name}\" → callHandlers → \"{}\"",
                    handler.handler
                ),
            ),
        }
        handler.name = call_event_name(&handler.function);
        events.push(call_event_config(&handler.name));
    }
    for (ordinal, handler) in source
        .block_handlers
        .iter_mut()
        .filter(|handler| handler.filter == manifest::BlockFilter::Call)
        .enumerate()
    {
        handler.call_event = match ordinal {
            0 => CALL_ANY_EVENT.to_string(),
            n => format!("{CALL_ANY_EVENT}_{n}"),
        };
        events.push(call_event_config(&handler.call_event));
    }

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

/// The table that records which file data sources have run. Not a subgraph
/// entity: the user's schema never names it.
pub const FILE_DATA_SOURCE_ENTITY: &str = "EnvioFileDataSource";

/// `ENVIO_SUBGRAPH_RPC` is one setting for every chain, so it can't say which
/// chains HyperSync serves. On one it stays what the user wrote (a fallback by
/// default); on a chain HyperSync doesn't serve, a `fallback` entry would leave
/// the chain with no source at all, so it becomes the sync source.
fn rpc_for_chain(rpc: &RpcSelection, chain_id: u64) -> RpcSelection {
    use crate::config_parsing::human_config::evm::{For, Rpc};
    if crate::config_parsing::hypersync_endpoints::get_default_hypersync_endpoint(chain_id).is_ok()
    {
        return rpc.clone();
    }
    let sync = |entry: &Rpc| Rpc {
        source_for: match entry.source_for {
            Some(For::Fallback) => Some(For::Sync),
            ref other => other.clone(),
        },
        ..entry.clone()
    };
    match rpc {
        RpcSelection::Url(_) => rpc.clone(),
        RpcSelection::Single(entry) => RpcSelection::Single(sync(entry)),
        RpcSelection::List(entries) => RpcSelection::List(entries.iter().map(sync).collect()),
    }
}

/// How long the one `eth_chainId` request per endpoint may take.
const CHAIN_ID_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// The chain `ENVIO_SUBGRAPH_RPC` serves, for each manifest network no table
/// knows and each one whose table chain it doesn't serve, with a startup
/// notice for the latter. graph-node indexes a network on whatever chain the
/// providers configured for it serve; its docker-compose calls the one chain
/// `mainnet` whatever it is. An endpoint that doesn't answer leaves a known
/// name to its table.
fn networks_from_rpc(
    manifest_yaml: &str,
    rpc: &RpcSelection,
    notices: &mut Vec<String>,
) -> manifest::NetworksFromRpc {
    let networks = manifest::chain_networks(manifest_yaml);
    if networks.is_empty() {
        return manifest::NetworksFromRpc::new();
    }
    let answer = chain_id_served_by(rpc);
    // graph-node runs a subgraph on one network; a manifest naming several
    // keeps their table chains, and the one endpoint is refused over them.
    let single = networks.len() == 1;
    let mut resolved = manifest::NetworksFromRpc::new();
    for (network, known) in networks {
        match (known, &answer) {
            (None, answer) => {
                resolved.insert(network, answer.clone());
            }
            (Some(known), Ok(served)) if single && known != *served => {
                notices.push(format!(
                    "Envio Subgraph indexes the network \"{network}\" on chain {served}, the chain \
                     {RPC_ENV_VAR} serves, not chain {known}, which The Graph's networks registry \
                     (or Envio) calls \"{network}\": graph-node indexes a network on the chain its \
                     configured provider serves. If chain {known} is meant, point {RPC_ENV_VAR} at \
                     an endpoint of it."
                ));
                resolved.insert(network, Ok(*served));
            }
            _ => {}
        }
    }
    resolved
}

/// Asks each endpoint in turn which chain it serves; the first answer wins.
/// On a thread of its own, since translation also runs inside the CLI's async
/// runtime, where blocking on another one isn't allowed.
fn chain_id_served_by(rpc: &RpcSelection) -> Result<u64, String> {
    let endpoints: Vec<(String, BTreeMap<String, String>)> = match rpc {
        RpcSelection::Url(url) => vec![(url.clone(), BTreeMap::new())],
        RpcSelection::Single(entry) => {
            vec![(entry.url.clone(), entry.headers.clone().unwrap_or_default())]
        }
        RpcSelection::List(entries) => entries
            .iter()
            .map(|entry| (entry.url.clone(), entry.headers.clone().unwrap_or_default()))
            .collect(),
    };
    let asked = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|err| format!("couldn't start a runtime to ask {RPC_ENV_VAR}: {err}"))?;
        runtime.block_on(async {
            let mut failure = format!("found no endpoint in {RPC_ENV_VAR}");
            for (url, headers) in &endpoints {
                match eth_chain_id(url, headers).await {
                    Ok(chain_id) => return Ok(chain_id),
                    Err(err) => failure = unanswered(url, &err),
                }
            }
            Err(failure)
        })
    })
    .join();
    asked.unwrap_or_else(|_| Err(format!("failed asking {RPC_ENV_VAR} for its chain id")))
}

fn unanswered(url: &str, err: &anyhow::Error) -> String {
    let host = endpoint_host(url);
    format!("asked {host} (eth_chainId) which chain it serves and got no answer: {err:#}")
}

/// The endpoint without its path or query, where providers put API keys.
fn endpoint_host(url: &str) -> String {
    match reqwest::Url::parse(url) {
        Ok(parsed) => match (parsed.host_str(), parsed.port()) {
            (Some(host), Some(port)) => format!("{}://{host}:{port}", parsed.scheme()),
            (Some(host), None) => format!("{}://{host}", parsed.scheme()),
            _ => RPC_ENV_VAR.to_string(),
        },
        Err(_) => RPC_ENV_VAR.to_string(),
    }
}

async fn eth_chain_id(url: &str, headers: &BTreeMap<String, String>) -> Result<u64> {
    let client = reqwest::Client::builder()
        .timeout(CHAIN_ID_TIMEOUT)
        .build()?;
    let mut request = client.post(url).json(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "eth_chainId",
        "params": [],
    }));
    for (name, value) in headers {
        request = request.header(name, value);
    }
    // reqwest's errors name the URL, path and query included, where providers
    // put API keys; the host is named by the caller instead.
    let body: serde_json::Value = request
        .send()
        .await
        .map_err(reqwest::Error::without_url)?
        .json()
        .await
        .map_err(reqwest::Error::without_url)?;
    let result = body
        .get("result")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow!("{body}"))?;
    u64::from_str_radix(result.trim_start_matches("0x"), 16)
        .map_err(|_| anyhow!("\"{result}\" isn't a chain id"))
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

    let rpc_parsed = rpc_env.map(parse_rpc_env);
    let mut notices = Vec::new();
    let mut networks = match &rpc_parsed {
        Some(Ok(rpc)) => networks_from_rpc(manifest_yaml, rpc, &mut notices),
        _ => manifest::NetworksFromRpc::new(),
    };
    // With no endpoint to ask, a name that spells a known network another way
    // is read as that network, and startup says so.
    if rpc_parsed.is_none() {
        for network in manifest::unknown_networks(manifest_yaml) {
            if let Some((known, chain_id)) = manifest::network_spelled(&network) {
                notices.push(format!(
                    "Envio Subgraph reads the network \"{network}\" as \"{known}\" (chain \
                     {chain_id}). graph-node matches network names exactly; if \"{network}\" \
                     is another chain, set {RPC_ENV_VAR} to an endpoint of it."
                ));
                networks.insert(network, Ok(chain_id));
            }
        }
    }
    let Some(manifest) = manifest::parse_with_networks(manifest_yaml, &networks, &mut report)
    else {
        report.into_result()?;
        return Err(anyhow!("Failed to read subgraph.yaml"));
    };
    let mut schema = schema::translate(schema_text, &mut report);
    // A file data source runs once per (template, CID, context). The record that
    // it has lives in a table of its own, so a reorg rolls it back with the
    // entities the handler wrote, and a restart doesn't run it twice.
    if manifest
        .templates
        .iter()
        .any(|template| template.kind.is_file())
    {
        schema.text.push_str(&format!(
            "\n\ntype {FILE_DATA_SOURCE_ENTITY} {{\n  id: ID!\n}}"
        ));
        schema
            .entity_fields
            .insert(FILE_DATA_SOURCE_ENTITY.to_string(), vec!["id".to_string()]);
    }

    // Held back until the manifest and schema have been checked too, so a
    // mistyped endpoint doesn't hide what else this subgraph needs changed.
    let (rpc, rpc_error) = match rpc_parsed {
        Some(Ok(rpc)) => (Some(rpc), None),
        Some(Err(err)) => (None, Some(err)),
        None => (None, None),
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
    let contract_names = contract_names(&manifest);
    let contract_name = |source: &DataSource| contract_names[&source.name].clone();
    for source in manifest.data_sources.iter_mut() {
        // Refused by the manifest parser: a file data source belongs in `templates`.
        if source.kind.is_file() {
            continue;
        }
        contracts.push(GlobalContract {
            name: contract_name(source),
            config: contract_config(source, files, &usage, &mut notices, &mut report),
        });

        let Some(chain_id) = source.chain_id else {
            continue;
        };
        let start_block = source.start_block.unwrap_or(0);
        let is_first = !chains.contains_key(&chain_id);
        let chain = chains.entry(chain_id).or_insert_with(|| Chain {
            id: chain_id,
            skip: None,
            rpc: rpc.as_ref().map(|rpc| rpc_for_chain(rpc, chain_id)),
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
                name: contract_name(source),
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
    let mut template_chains: HashSet<u64> = HashSet::new();
    for source in manifest.templates.iter_mut() {
        // A file template has no contract, address or chain: the runtime runs
        // its handler when a mapping creates it (`runtime.ts`, file data sources).
        if source.kind.is_file() {
            continue;
        }
        let config = contract_config(source, files, &usage, &mut notices, &mut report);
        let ids = match source.chain_id {
            Some(id) => vec![id],
            None => template_chain_ids.clone(),
        };
        template_chains.extend(ids.iter().copied());

        // graph-node keeps `dataSources` and `templates` in separate namespaces,
        // so a name can appear in both — Balancer's FXPoolDeployer is a fixed
        // deployment and a template over the same mapping and ABI. envio has one
        // namespace, and one contract with a static address plus dynamically
        // registered ones is exactly what that describes, so the two are folded
        // together and only the events are unioned.
        match contracts
            .iter_mut()
            .find(|contract| contract.name == contract_name(source))
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
                let call_events: Vec<EventConfig> = config
                    .events
                    .iter()
                    .filter(|event| event.event.starts_with(CALL_EVENT_PREFIX))
                    .cloned()
                    .collect();
                for event in call_events {
                    if !existing
                        .config
                        .events
                        .iter()
                        .any(|known| known.event == event.event)
                    {
                        existing.config.events.push(event);
                    }
                }
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
                name: contract_name(source),
                config,
            }),
        }

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
                    name: contract_name(source),
                    address: NormalizedList::from(Vec::<String>::new()),
                    start_block: None,
                    config: None,
                });
            }
        }
    }

    // graph-node stops at its data sources' last endBlock only when nothing
    // else can produce a trigger, and an instance of a template has no end of
    // its own (core/src/subgraph/instance_manager.rs, `max_end_block`).
    for chain_id in &template_chains {
        if let Some(chain) = chains.get_mut(chain_id) {
            chain.end_block = None;
        }
    }

    match (rpc_error, report.into_result()) {
        (Some(rpc_error), Err(findings)) => return Err(anyhow!("{rpc_error}\n\n{findings}")),
        (Some(rpc_error), Ok(())) => return Err(rpc_error),
        (None, result) => result?,
    }

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
    // A `filter: call` handler is exempt: its block arrives whole with the call.
    let mut block_header_lag: BTreeMap<u64, u32> = BTreeMap::new();
    for source in manifest.all_sources() {
        let handlers: Vec<String> = source
            .block_handlers
            .iter()
            .filter(|handler| handler.filter != manifest::BlockFilter::Call)
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

    let rpc_only_chains: Vec<u64> = chains
        .keys()
        .copied()
        .filter(|id| {
            crate::config_parsing::hypersync_endpoints::get_default_hypersync_endpoint(*id).is_err()
        })
        .collect();

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
        .map(|source| {
            (
                source.name.clone(),
                contract_names[&source.name].capitalize(),
            )
        })
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
            manifest_file: DEFAULT_MANIFEST.to_string(),
            block_header_lag,
            rpc_only_chains,
            notices,
            rendered_manifest: None,
            path_fixes: Vec::new(),
            build_network: None,
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

    #[test]
    fn a_dependency_mapping_does_not_place_the_generated_code() {
        let dir = project(&[
            (
                "node_modules/@openzeppelin/subgraphs/src/datasources/voting.ts",
                "import { Vote } from \"../../generated/schema\";\n",
            ),
            (
                "node_modules/@openzeppelin/subgraphs/generated/schema.ts",
                "export class Vote {}\n",
            ),
            (
                "src/locking.ts",
                "import { Lock } from \"./types/schema\";\n",
            ),
        ]);
        let mapping_files = [
            "./node_modules/@openzeppelin/subgraphs/src/datasources/voting.ts".to_string(),
            "./src/locking.ts".to_string(),
        ];
        assert_eq!(
            pathdiff_relative(&generated_dir(dir.path(), &mapping_files), dir.path()),
            "src/types"
        );
    }

    #[test]
    fn npm_found_on_path_only_when_present() {
        let dir = TempDir::new("envio_subgraph_npm").unwrap();
        let path = std::env::join_paths([dir.path()]).unwrap();
        assert!(!npm_on_path(Some(&path)));
        assert!(!npm_on_path(None));
        std::fs::write(dir.path().join("npm"), "").unwrap();
        assert!(npm_on_path(Some(&path)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config_parsing::human_config::evm::{For, Rpc};
    use crate::config_parsing::system_config::SystemConfig;

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

    const SET_GRAVATAR_ABI: &str = r#"[
      {"type":"function","name":"setGravatar","stateMutability":"nonpayable",
       "inputs":[{"name":"name","type":"string"}],"outputs":[{"name":"ok","type":"bool"}]},
      {"type":"function","name":"updateGravatarName","stateMutability":"nonpayable",
       "inputs":[{"name":"name","type":"string"}],"outputs":[]}
    ]"#;

    #[test]
    fn translates_call_handlers_into_call_triggers() {
        let manifest = MANIFEST.replacen(
            "      eventHandlers:",
            "      callHandlers:\n        - function: setGravatar(string)\n          handler: \
             handleSetGravatar\n        - function: setGravatar(string)\n          handler: \
             handleShadowed\n      eventHandlers:",
            1,
        );
        let mut files = HashMap::new();
        files.insert(
            "./abis/Gravity.json".to_string(),
            SET_GRAVATAR_ABI.to_string(),
        );
        let translation = translate(
            &manifest,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &files,
            &ambiguous(),
        )
        .unwrap();
        let source = &translation.runtime.manifest.data_sources[0];
        // The first handler for a selector wins, as in graph-node.
        assert_eq!(
            source
                .call_handlers
                .iter()
                .map(|handler| (handler.handler.as_str(), handler.name.as_str()))
                .collect::<Vec<_>>(),
            vec![("handleSetGravatar", "__envio_call_9a6e09c9_setGravatar")]
        );
        assert_eq!(
            (
                source.call_handlers[0]
                    .inputs
                    .iter()
                    .map(|input| (input.name.as_str(), input.abi_type.as_str()))
                    .collect::<Vec<_>>(),
                source.call_handlers[0]
                    .outputs
                    .iter()
                    .map(|output| (output.name.as_str(), output.abi_type.as_str()))
                    .collect::<Vec<_>>(),
            ),
            (vec![("name", "string")], vec![("ok", "bool")])
        );
        let contract = &translation.human_config.contracts.as_ref().unwrap()[0];
        let call_events: Vec<_> = contract
            .config
            .events
            .iter()
            .filter(|event| event.event.starts_with(CALL_EVENT_PREFIX))
            .map(|event| event.event.as_str())
            .collect();
        assert_eq!(
            call_events,
            vec![
                "__envio_call_9a6e09c9_setGravatar(bytes callInput, bytes callOutput, address \
                 callFrom, uint256 callValue, uint256 callGasUsed)"
            ]
        );
    }

    #[test]
    fn gives_a_call_filtered_block_handler_its_call_trigger() {
        let manifest = MANIFEST.replacen(
            "      eventHandlers:",
            "      blockHandlers:\n        - handler: handleBlockCall\n          filter:\n            \
             kind: call\n      eventHandlers:",
            1,
        );
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
        let source = &translation.runtime.manifest.data_sources[0];
        let contract = &translation.human_config.contracts.as_ref().unwrap()[0];
        assert_eq!(
            (
                source.block_handlers[0].call_event.as_str(),
                contract
                    .config
                    .events
                    .iter()
                    .filter(|event| event.event.starts_with(CALL_ANY_EVENT))
                    .count(),
            ),
            ("__envio_call_any", 1)
        );
    }

    #[test]
    fn refuses_a_call_handler_whose_function_the_abi_lacks() {
        let manifest = MANIFEST.replacen(
            "      eventHandlers:",
            "      callHandlers:\n        - function: setGravatar(uint256)\n          handler: \
             handleSetGravatar\n      eventHandlers:",
            1,
        );
        let mut files = HashMap::new();
        files.insert(
            "./abis/Gravity.json".to_string(),
            SET_GRAVATAR_ABI.to_string(),
        );
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
        assert!(
            error.contains("setGravatar(uint256)") && error.contains("handleSetGravatar"),
            "{error}"
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
        let without_templates = MANIFEST.split("templates:").next().unwrap();
        let single = translate(
            without_templates,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();

        let bounded_source = without_templates.replace(
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

    // graph-node keeps indexing a template's instances after the data source
    // that created them ends (Uniswap v3: Factory with an endBlock, Pool
    // template). The runtime drops the data source's own events past its
    // endBlock, so the chain stays open.
    #[test]
    fn keeps_a_chain_with_a_template_open_past_data_source_end_blocks() {
        let bounded = MANIFEST.replace(
            "      startBlock: 6175244",
            "      startBlock: 6175244\n      endBlock: 6180000",
        );
        let with_template = translate(
            &bounded,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();

        assert_eq!(with_template.human_config.chains[0].end_block, None);
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
    fn a_data_source_name_that_is_not_an_identifier_is_made_one() {
        let manifest = MANIFEST.replace("name: Gravity", "name: Gravity-widget");
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
        let contracts = translation.human_config.contracts.unwrap();
        assert_eq!(
            (
                contracts[0].name.as_str(),
                translation
                    .runtime
                    .contract_accessors
                    .get("Gravity-widget")
                    .map(String::as_str),
            ),
            ("Gravity_widget", Some("Gravity_widget"))
        );
    }

    #[test]
    fn accepts_topic0_when_it_is_the_signatures_hash_and_refuses_it_otherwise() {
        let own =
            manifest::canonical_event_hash("NewGravatar(uint256,address,string,string)").unwrap();
        let with = |topic0: &str| {
            let manifest = MANIFEST.replacen(
                "          handler: handleNewGravatar",
                &format!("          topic0: \"{topic0}\"\n          handler: handleNewGravatar"),
                1,
            );
            translate(
                &manifest,
                SCHEMA,
                "gravatar",
                None,
                ".",
                &HashMap::new(),
                &ambiguous(),
            )
        };
        // Another word is only a selector on an anonymous event, which
        // NewGravatar isn't.
        let selector = format!("0x4bb278f3{}", "00".repeat(28));
        assert_eq!(
            (
                with(&own).is_ok(),
                with("0x").is_ok(),
                with(&selector).is_ok()
            ),
            (true, false, false)
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

    const FILE_TEMPLATE: &str = r#"
  - kind: file/ipfs
    name: Metadata
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Gravatar
      handler: handleMetadata
      file: ./src/metadata.ts
"#;

    // A file template has no chain, contract or events: the translation leaves it
    // out of the envio config, keeps it for the runtime, and adds the table that
    // records which files have run.
    #[test]
    fn keeps_a_file_template_out_of_the_envio_config() {
        let manifest = format!("{MANIFEST}{FILE_TEMPLATE}");
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
        let names: Vec<_> = contracts.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["Gravity", "Wallet"]);
        let file = translation
            .runtime
            .manifest
            .templates
            .iter()
            .find(|template| template.name == "Metadata")
            .unwrap();
        assert_eq!(
            (
                file.kind,
                file.entities.clone(),
                file.event_handlers
                    .iter()
                    .map(|handler| handler.handler.clone())
                    .collect::<Vec<_>>()
            ),
            (
                manifest::DataSourceKind::FileIpfs,
                vec!["Gravatar".to_string()],
                vec!["handleMetadata".to_string()]
            )
        );
        assert!(translation.schema_text.contains("type EnvioFileDataSource"));
        assert!(translation
            .runtime
            .entity_accessors
            .contains_key(FILE_DATA_SOURCE_ENTITY));
    }

    // Heesho/stickrnet-monorepo spells its file template's mapping kind as the
    // data source's own. graph-node's offchain `UnresolvedMapping` has no
    // `kind` and doesn't deny unknown fields, so it reads the same as any.
    #[test]
    fn reads_a_file_template_whose_mapping_kind_is_the_file_kind() {
        let manifest = format!(
            "{MANIFEST}{}",
            FILE_TEMPLATE.replace("kind: ethereum/events", "kind: file/ipfs")
        );
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
        let file = translation
            .runtime
            .manifest
            .templates
            .iter()
            .find(|template| template.name == "Metadata")
            .map(|template| template.kind);
        assert_eq!(file, Some(manifest::DataSourceKind::FileIpfs));
    }

    #[test]
    fn adds_no_file_table_without_a_file_template() {
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
        assert!(!translation.schema_text.contains("EnvioFileDataSource"));
    }

    #[test]
    fn refuses_a_file_data_source_outside_templates() {
        let manifest = MANIFEST.replace(
            "dataSources:\n",
            "dataSources:\n  - kind: file/ipfs\n    name: Static\n    mapping:\n      kind: ethereum/events\n      apiVersion: 0.0.7\n      language: wasm/assemblyscript\n      entities: []\n      handler: h\n      file: ./src/s.ts\n",
        );
        let err = translate(
            &manifest,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap_err();
        assert!(err
            .to_string()
            .contains("file data sources outside `templates`"));
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

        // An endpoint that answers doesn't fold the two networks into its one
        // chain: graph-node runs a subgraph on a single network, so the chain
        // an endpoint decides is that network's alone.
        let polygon = rpc_serving_chain(137);
        let message = translate(
            &two_chains,
            SCHEMA,
            "gravatar",
            Some(&polygon),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .err()
        .map(|err| format!("{err:#}"))
        .unwrap_or_default();
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

    // Filecoin (314) is a hosted-subgraph chain HyperSync doesn't serve: the one
    // ENVIO_SUBGRAPH_RPC the docs show says `fallback`, and on a chain with no
    // HyperSync that would leave it with no source.
    #[test]
    fn makes_the_rpc_the_sync_source_on_a_chain_hypersync_does_not_serve() {
        let yaml = MANIFEST
            .split("templates:")
            .next()
            .unwrap()
            .replace("network: mainnet", "network: filecoin");
        let translation = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            Some(r#"[{"url":"https://rpc.example.test","for":"fallback"}]"#),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap();
        assert_eq!(translation.human_config.chains[0].id, 314);
        let Some(RpcSelection::List(rpcs)) = translation.human_config.chains[0].rpc.clone() else {
            panic!("expected a list of rpcs");
        };
        assert_eq!(rpcs[0].source_for, Some(For::Sync));
    }

    // Without any RPC, the error names the env var instead of config.yaml.
    #[test]
    fn names_the_rpc_env_var_when_hypersync_does_not_serve_the_chain() {
        let yaml = MANIFEST
            .split("templates:")
            .next()
            .unwrap()
            .replace("network: mainnet", "network: filecoin");
        let files = HashMap::from([(
            "./abis/Gravity.json".to_string(),
            r#"[{"type":"event","name":"NewGravatar","anonymous":false,"inputs":[
              {"name":"id","type":"uint256","indexed":false},
              {"name":"owner","type":"address","indexed":false},
              {"name":"displayName","type":"string","indexed":false},
              {"name":"imageUrl","type":"string","indexed":false}]},
              {"type":"event","name":"UpdatedGravatar","anonymous":false,"inputs":[
              {"name":"id","type":"uint256","indexed":false},
              {"name":"owner","type":"address","indexed":false},
              {"name":"displayName","type":"string","indexed":false},
              {"name":"imageUrl","type":"string","indexed":false}]}]"#
                .to_string(),
        )]);
        let err = SystemConfig::parse_subgraph(
            &yaml,
            SCHEMA,
            "gravatar",
            &HashMap::new(),
            &files,
            ".",
            &ambiguous(),
        )
        .expect_err("expected a chain without HyperSync and without RPC to be refused");
        let message = format!("{err:#}");
        assert!(
            message.contains("HyperSync doesn't serve chain 314")
                && message.contains("ENVIO_SUBGRAPH_RPC=https://")
                && !message.contains("config.yaml")
                && !message.contains("hypersync_config"),
            "unexpected error: {message}"
        );

        // And with the endpoint set, it translates.
        let env = HashMap::from([(
            "ENVIO_SUBGRAPH_RPC".to_string(),
            "https://rpc.example.test".to_string(),
        )]);
        SystemConfig::parse_subgraph(&yaml, SCHEMA, "gravatar", &env, &files, ".", &ambiguous())
            .expect("filecoin over RPC");
    }

    /// An RPC endpoint on a thread of its own that answers every request with
    /// `chain_id`, as `eth_chainId` would.
    pub(super) fn rpc_serving_chain(chain_id: u64) -> String {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind a local port");
        let url = format!("http://{}", listener.local_addr().expect("a local address"));
        std::thread::spawn(move || {
            for mut stream in listener.incoming().flatten() {
                let mut request = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    let read = stream.read(&mut chunk).unwrap_or(0);
                    if read == 0 {
                        break;
                    }
                    request.extend_from_slice(&chunk[..read]);
                    let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") else {
                        continue;
                    };
                    let head = String::from_utf8_lossy(&request[..end]).to_lowercase();
                    let length = head
                        .lines()
                        .find_map(|line| line.strip_prefix("content-length:"))
                        .and_then(|value| value.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
                let body = format!(r#"{{"jsonrpc":"2.0","id":1,"result":"0x{chain_id:x}"}}"#);
                let _ = write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\
                     Connection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        url
    }

    // graph-node never looks a network name up: its operator binds the name to
    // providers (`[chains.<name>]` in graph-node's config.toml) and the chain is
    // whichever one they serve, so a self-hosted node can call a chain anything.
    // A name no table here knows is, the same way, the chain ENVIO_SUBGRAPH_RPC
    // serves.
    #[test]
    fn an_unknown_network_is_the_chain_its_rpc_serves() {
        let yaml = MANIFEST
            .split("templates:")
            .next()
            .unwrap()
            .replace("network: mainnet", "network: risechain");

        let unknown = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .err()
        .map(|err| format!("{err:#}"))
        .unwrap_or_default();
        assert!(
            unknown.contains("doesn't know the network \"risechain\"")
                && unknown.contains("ENVIO_SUBGRAPH_RPC=https://"),
            "unexpected error: {unknown}"
        );

        let rpc = rpc_serving_chain(11155931);
        let translation = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            Some(&rpc),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .expect("the network is the chain the RPC serves");
        let chain = &translation.human_config.chains[0];
        assert_eq!(
            (chain.id, chain.rpc.clone()),
            (11155931, Some(RpcSelection::Url(rpc)))
        );
    }

    // graph-node matches a network name exactly, against the names its operator
    // chose, and self-hosted nodes spell the registry's names their own way
    // (`hyperEVM`, `base_sepolia`, `baseSepolia`, `polygon_amoy`). With no RPC
    // to ask, such a name is read as the one it spells, and startup says so.
    #[test]
    fn reads_a_registry_name_spelled_another_way_as_that_network() {
        let read: Vec<(u64, usize)> = ["hyperEVM", "base_sepolia", "baseSepolia", "polygon_amoy"]
            .iter()
            .map(|written| {
                let yaml = MANIFEST
                    .split("templates:")
                    .next()
                    .unwrap()
                    .replace("network: mainnet", &format!("network: {written}"));
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
                (
                    translation.human_config.chains[0].id,
                    translation.runtime.notices.len(),
                )
            })
            .collect();
        assert_eq!(read, vec![(999, 1), (84532, 1), (84532, 1), (80002, 1)]);
    }

    // An endpoint that doesn't answer leaves the network unknown, and the error
    // says what was asked.
    #[test]
    fn an_unknown_network_names_the_rpc_that_did_not_answer() {
        let yaml = MANIFEST
            .split("templates:")
            .next()
            .unwrap()
            .replace("network: mainnet", "network: risechain");
        let closed = std::net::TcpListener::bind("127.0.0.1:0")
            .and_then(|listener| listener.local_addr())
            .expect("a local port");
        let message = translate(
            &yaml,
            SCHEMA,
            "gravatar",
            Some(&format!("http://{closed}/v2/sekret-api-key")),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .err()
        .map(|err| format!("{err:#}"))
        .unwrap_or_default();
        // The path is where providers put API keys, so it stays out of the error.
        assert!(
            message.contains("doesn't know the network \"risechain\"")
                && message.contains(&format!(
                    "asked http://{closed} (eth_chainId) which chain it serves and got no answer"
                ))
                && !message.contains("sekret-api-key"),
            "unexpected error: {message}"
        );
    }

    // A non-anonymous event with four indexed parameters needs five topics, and
    // a log holds at most four, so no log decodes as it: graph-node skips the
    // handler for every log with its topic0 (chain/ethereum/src/data_source.rs,
    // "Skipping handler because the event parameters do not match the event
    // signature"). Agentic-Trust-Layer/agent-indexer declares ERC-6909's
    // Transfer that way, and envio's log decoder refused to start over it.
    #[test]
    fn drops_a_handler_for_an_event_no_log_can_carry() {
        let manifest = MANIFEST
            .split("templates:")
            .next()
            .unwrap()
            .replace(
                "        - event: NewGravatar(uint256,address,string,string)\n          handler: handleNewGravatar",
                "        - event: Transfer(indexed address,indexed address,indexed address,indexed uint256,uint256)\n          handler: handleTransfer\n        - event: NewGravatar(uint256,address,string,string)\n          handler: handleNewGravatar",
            );
        let files = HashMap::from([(
            "./abis/Gravity.json".to_string(),
            r#"[{"type":"event","name":"Transfer","anonymous":false,"inputs":[
              {"name":"caller","type":"address","indexed":true},
              {"name":"from","type":"address","indexed":true},
              {"name":"to","type":"address","indexed":true},
              {"name":"id","type":"uint256","indexed":true},
              {"name":"amount","type":"uint256","indexed":false}]},
              {"type":"event","name":"NewGravatar","anonymous":false,"inputs":[
              {"name":"id","type":"uint256","indexed":false},
              {"name":"owner","type":"address","indexed":false},
              {"name":"displayName","type":"string","indexed":false},
              {"name":"imageUrl","type":"string","indexed":false}]},
              {"type":"event","name":"UpdatedGravatar","anonymous":false,"inputs":[
              {"name":"id","type":"uint256","indexed":false},
              {"name":"owner","type":"address","indexed":false},
              {"name":"displayName","type":"string","indexed":false},
              {"name":"imageUrl","type":"string","indexed":false}]}]"#
                .to_string(),
        )]);
        let translation = translate(
            &manifest,
            SCHEMA,
            "gravatar",
            None,
            ".",
            &files,
            &ambiguous(),
        )
        .unwrap();
        let events: Vec<String> = translation.human_config.contracts.as_ref().unwrap()[0]
            .config
            .events
            .iter()
            .map(|event| {
                event
                    .event
                    .split('(')
                    .next()
                    .unwrap_or_default()
                    .to_string()
            })
            .collect();
        let handlers: Vec<String> = translation.runtime.manifest.data_sources[0]
            .event_handlers
            .iter()
            .map(|handler| handler.handler.clone())
            .collect();
        assert_eq!(
            (events, handlers, translation.runtime.notices.len()),
            (
                vec!["NewGravatar".to_string(), "UpdatedGravatar".to_string()],
                vec![
                    "handleNewGravatar".to_string(),
                    "handleUpdatedGravatar".to_string()
                ],
                1
            )
        );
        assert!(
            translation.runtime.notices[0].contains("handleTransfer"),
            "{}",
            translation.runtime.notices[0]
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
            "      entityHandlers:\n        - handler: handleEntity\n      file: ./src/gravity.ts",
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
                error.contains("doesn't know the manifest field \"entityHandlers\""),
                error.contains("doesn't know the type NotAType"),
            ),
            (true, true)
        );
    }

    // CryptoPunks learned of its RPC value on one run and of its schema on the
    // next.
    #[test]
    fn reports_a_bad_rpc_value_with_the_other_findings() {
        let error = translate(
            MANIFEST,
            "type Gravatar @entity { id: ID! bad: NotAType! }",
            "gravatar",
            Some("[1, 2]"),
            ".",
            &HashMap::new(),
            &ambiguous(),
        )
        .unwrap_err()
        .to_string();

        assert_eq!(
            (
                error.contains("Invalid ENVIO_SUBGRAPH_RPC"),
                error.contains("doesn't know the type NotAType"),
            ),
            (true, true),
            "{error}"
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

    /// A Gravity project on disk on `network`, with `.env` holding `env`.
    fn gravity_project(network: &str, env: &str) -> tempdir::TempDir {
        let dir = tempdir::TempDir::new("envio-subgraph").unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("abis")).unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(root.join("abis/Gravity.json"), GRAVITY_ABI).unwrap();
        fs::write(
            root.join("src/gravity.ts"),
            "export function handleNewGravatar() {}",
        )
        .unwrap();
        fs::write(
            root.join("schema.graphql"),
            "type Gravatar @entity {\n  id: Bytes!\n}\n",
        )
        .unwrap();
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("network: mainnet", &format!("network: {network}")),
        )
        .unwrap();
        fs::write(root.join(".env"), env).unwrap();
        dir
    }

    // graph-node indexes a network on whatever chain the providers configured
    // for it serve; its docker-compose names the one chain `mainnet` whatever it
    // is, so a local subgraph says `network: mainnet` for an anvil node (31337),
    // and Hedera's graph-node says it for Hedera (295). When ENVIO_SUBGRAPH_RPC
    // serves another chain than the registry's for the name, that chain is
    // indexed, and startup says so.
    #[test]
    fn indexes_the_chain_the_rpc_serves_when_the_registry_names_another() {
        let parse = |network: &str, chain_id: u64| {
            let rpc = super::tests::rpc_serving_chain(chain_id);
            let project = gravity_project(network, &format!("ENVIO_SUBGRAPH_RPC={rpc}\n"));
            let project_paths =
                ParsedProjectPaths::new(project.path().to_str().unwrap(), "config.yaml").unwrap();
            let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
            let chains: Vec<u64> = config.get_chains().iter().map(|chain| chain.id).collect();
            let notices = config
                .subgraph
                .map(|subgraph| subgraph.notices)
                .unwrap_or_default();
            (chains, notices.len())
        };
        assert_eq!(
            (parse("mainnet", 31337), parse("sepolia", 11155111)),
            ((vec![31337], 1), (vec![11155111], 0))
        );
    }

    const GRAVITY_ABI: &str = r#"[{"type":"event","name":"NewGravatar","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]"#;

    const GRAVITY_MANIFEST: &str = r#"
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
"#;

    fn parse_in_memory(schema: &str) -> anyhow::Result<SystemConfig> {
        let files = std::collections::HashMap::from([(
            "./abis/Gravity.json".to_string(),
            GRAVITY_ABI.to_string(),
        )]);
        SystemConfig::parse_subgraph(
            GRAVITY_MANIFEST,
            schema,
            "gravatar",
            &std::collections::HashMap::new(),
            &files,
            ".",
            &[],
        )
    }

    // CryptoPunks: `Ask.nft: NFT` (one implementor) and `Ask.created: Event`
    // (nine) were refused one after the other by envio's own schema checks.
    #[test]
    fn indexes_fields_typed_as_an_interface() {
        let config = parse_in_memory(
            r#"
interface NFT {
  id: ID!
}
interface Event {
  id: ID!
  nft: NFT
}
type Punk implements NFT @entity {
  id: ID!
  events: [Event!]! @derivedFrom(field: "nft")
}
type Ask @entity {
  id: ID!
  nft: NFT
  created: Event
}
type Sale implements Event @entity {
  id: ID!
  nft: NFT
  asks: [Ask!]! @derivedFrom(field: "created")
}
type Transfer implements Event @entity {
  id: ID!
  nft: NFT
}
"#,
        )
        .unwrap();
        let ask = config.schema.entities.get("Ask").unwrap();
        let mut columns: Vec<String> = ask
            .get_fields()
            .iter()
            .filter_map(|field| {
                field
                    .get_postgres_field(&config.schema, ask)
                    .unwrap()
                    .map(|pg| pg.field_name.clone())
            })
            .collect();
        columns.sort();
        assert_eq!(columns, vec!["created_id", "id", "nft"]);
    }

    // Giveth names a data source `WETH/GIV LP`, Sablier `SablierV1.0.0`: any
    // string to graph-node, an invalid contract name to envio.
    #[test]
    fn names_a_contract_after_a_data_source_whatever_it_is_called() {
        let manifest = format!(
            "{GRAVITY_MANIFEST}{}",
            GRAVITY_MANIFEST
                .split("dataSources:")
                .nth(1)
                .unwrap()
                .replacen("    name: Gravity\n", "    name: WETH_GIV_LP\n", 1)
        )
        .replacen("    name: Gravity\n", "    name: WETH/GIV LP\n", 1);
        let files = std::collections::HashMap::from([(
            "./abis/Gravity.json".to_string(),
            GRAVITY_ABI.to_string(),
        )]);
        let config = SystemConfig::parse_subgraph(
            &manifest,
            "type Gravatar @entity {\n  id: ID!\n}\n",
            "gravatar",
            &std::collections::HashMap::new(),
            &files,
            ".",
            &[],
        )
        .unwrap();
        let mut contracts: Vec<String> = config.contracts.keys().cloned().collect();
        contracts.sort();

        assert_eq!(
            (contracts, config.subgraph.unwrap().contract_accessors),
            (
                vec!["WETH_GIV_LP".to_string(), "WETH_GIV_LP_2".to_string()],
                std::collections::BTreeMap::from([
                    ("WETH/GIV LP".to_string(), "WETH_GIV_LP_2".to_string()),
                    ("WETH_GIV_LP".to_string(), "WETH_GIV_LP".to_string()),
                ])
            )
        );
    }

    // ENS app queries through a Graph endpoint took 1.3-5.7 s: `Domain.parent_id`
    // and `Registration.domain_id` lookups scanned the whole table.
    #[test]
    fn indexes_every_relation_column() {
        let config = parse_in_memory(
            r#"
interface Event {
  id: ID!
}
type Domain @entity {
  id: ID!
  parent: Domain
  name: String
  latest: Event
  subdomains: [Domain!]! @derivedFrom(field: "parent")
}
type Registration @entity {
  id: ID!
  domain: Domain!
  cost: BigInt
}
type Transfer implements Event @entity {
  id: ID!
}
type Renewal implements Event @entity {
  id: ID!
}
"#,
        )
        .unwrap();
        let mut indexed: Vec<String> = config
            .schema
            .entities
            .values()
            .flat_map(|entity| {
                entity
                    .get_fields()
                    .into_iter()
                    .filter_map(|field| field.get_postgres_field(&config.schema, entity).unwrap())
                    .filter(|pg| pg.is_index)
                    .map(|pg| format!("{}.{}", entity.name, pg.field_name))
                    .collect::<Vec<_>>()
            })
            .collect();
        indexed.sort();
        assert_eq!(
            indexed,
            vec!["Domain.latest_id", "Domain.parent", "Registration.domain"]
        );
    }

    /// The Gravity project laid out in `dir`, its manifest named `manifest`.
    fn write_gravity(dir: &std::path::Path, manifest: &str) {
        fs::create_dir_all(dir.join("abis")).unwrap();
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("abis/Gravity.json"), GRAVITY_ABI).unwrap();
        fs::write(
            dir.join("src/gravity.ts"),
            "export function handleNewGravatar() {}",
        )
        .unwrap();
        fs::write(
            dir.join("schema.graphql"),
            "type Gravatar @entity {\n  id: Bytes!\n  owner: Bytes!\n}\n",
        )
        .unwrap();
        fs::write(dir.join(manifest), GRAVITY_MANIFEST).unwrap();
    }

    // VeltrixaLabs' manifest says `network: 66665` (a chain id). graph-node
    // reads the manifest with serde_yaml, which reads a plain scalar into a
    // String field as written: the network "66665". envio refused the number
    // ("doesn't know the value of network, which has to be a string").
    #[test]
    fn reads_a_number_where_the_manifest_has_a_string_as_graph_node_does() {
        let dir = tempdir::TempDir::new("envio-subgraph-numeric-network").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("network: mainnet", "network: 66665"),
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err.lines().next().unwrap_or_default(),
            "Envio Subgraph doesn't know the network \"66665\"."
        );
    }

    // burngraph's manifest handles `AnonymousDeposit(indexed
    // address,uint256,string,string)`, and its VoteOption ABI declares that
    // event as ReceivedDeposit: graph-cli refuses it ("Event with signature …
    // not present in ABI"). envio reported a translation gap of its own
    // ("envio can't index the result … Event AnonymousDeposit not found in ABI
    // file", "please open an issue").
    #[test]
    fn says_which_event_the_abi_does_not_declare() {
        let dir = tempdir::TempDir::new("envio-subgraph-undeclared-event").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("NewGravatar(uint256)", "AnonymousGravatar(uint256)"),
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err,
            "The data source \"Gravity\" handles the event AnonymousGravatar(uint256), which its \
             ABI \"Gravity\" (./abis/Gravity.json) doesn't declare. The ABI's events: \
             NewGravatar(uint256). graph-cli refuses the manifest the same way (\"Event with \
             signature … not present in ABI\"): the manifest and the ABI are from different \
             versions of the contract."
        );
    }

    // Uniswap v3's build writes `v3-subgraph.yaml`; `--config` naming it was
    // parsed as an envio config ("missing field `chains`").
    #[test]
    fn indexes_the_manifest_config_names() {
        let dir = tempdir::TempDir::new("envio-subgraph-named").unwrap();
        let root = dir.path();
        write_gravity(root, "v3-subgraph.yaml");

        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "v3-subgraph.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let subgraph = config.subgraph.unwrap();

        assert_eq!(
            (
                subgraph.manifest_file.as_str(),
                std::path::Path::new(&subgraph.root) == root,
                config.contracts.contains_key("Gravity"),
            ),
            ("v3-subgraph.yaml", true, true)
        );
    }

    // A monorepo keeps one subgraph per package; its paths are relative to its
    // own manifest, as graph-cli reads them.
    #[test]
    fn resolves_a_manifest_against_its_own_directory() {
        let dir = tempdir::TempDir::new("envio-subgraph-monorepo").unwrap();
        let root = dir.path();
        write_gravity(&root.join("subgraphs/gravity"), "subgraph.yaml");

        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "subgraphs/gravity/subgraph.yaml")
                .unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let subgraph = config.subgraph.unwrap();

        assert_eq!(
            (
                std::path::Path::new(&subgraph.root) == root.join("subgraphs/gravity"),
                config.schema.entities.contains_key("Gravatar"),
            ),
            (true, true)
        );
    }

    // WOOFi keeps one manifest per chain in `subgraphs/`, naming its code
    // `../src/…`. Rooted at `subgraphs/`, the mappings were outside the root
    // the runtime loads them from and the usage scan never saw them.
    #[test]
    fn roots_a_subfolder_manifest_where_its_code_is() {
        let dir = tempdir::TempDir::new("envio-subgraph-subfolder").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        fs::create_dir_all(root.join("subgraphs")).unwrap();
        fs::write(
            root.join("subgraphs/polygon.yaml"),
            GRAVITY_MANIFEST
                .replace("./schema.graphql", "../schema.graphql")
                .replace("./abis/", "../abis/")
                .replace("./src/", "../src/"),
        )
        .unwrap();

        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "subgraphs/polygon.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let subgraph = config.subgraph.unwrap();

        assert_eq!(
            (
                std::path::Path::new(&subgraph.root) == root,
                subgraph.manifest_file.as_str(),
                subgraph.manifest.data_sources[0].mapping_file.as_str(),
            ),
            (true, "subgraphs/polygon.yaml", "./src/gravity.ts")
        );
    }

    // Without graph-cli, codegen writes generated/ from the manifest --config
    // names; it read `subgraph.yaml` beside the project instead, which a
    // per-network layout (`subgraph-<network>.yaml`, `subgraphs/<network>.yaml`)
    // doesn't have.
    #[tokio::test]
    async fn writes_the_generated_code_of_the_manifest_config_names() {
        let dir = tempdir::TempDir::new("envio-subgraph-codegen-config").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        fs::create_dir_all(root.join("subgraphs")).unwrap();
        fs::write(
            root.join("subgraphs/polygon.yaml"),
            GRAVITY_MANIFEST
                .replace("./schema.graphql", "../schema.graphql")
                .replace("./abis/", "../abis/")
                .replace("./src/", "../src/"),
        )
        .unwrap();

        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "subgraphs/polygon.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let result = crate::commands::codegen::run_codegen(&config)
            .await
            .map_err(|err| format!("{err:#}"));

        assert_eq!(
            (result, root.join("generated/Gravity/Gravity.ts").is_file()),
            (Ok(()), true)
        );
    }

    // Ekubo's manifest names no network; `graph build --network <name>` fills
    // each data source in from networks.json.
    #[test]
    fn builds_the_manifest_for_the_network_networks_json_names() {
        let dir = tempdir::TempDir::new("envio-subgraph-network").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("    network: mainnet\n", ""),
        )
        .unwrap();
        fs::write(
            root.join("networks.json"),
            r#"{
  "mainnet": {"Gravity": {"address": "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC", "startBlock": 6175244}},
  "arbitrum-one": {"Gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 416469410}}
}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let unset = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        assert!(
            unset.ends_with(
                "This project keeps per-network addresses in networks.json (mainnet, \
                 arbitrum-one). Pick one, as `graph build --network` does:\n  \
                 ENVIO_SUBGRAPH_NETWORK=mainnet"
            ),
            "{unset}"
        );

        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=arbitrum-one\n").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let chain = config.get_chains().into_iter().next().unwrap();
        let contract = &chain.contracts[0];

        assert_eq!(
            (chain.id, chain.start_block, contract.addresses.clone(),),
            (
                42161,
                crate::config_parsing::human_config::StartBlock::Number(416469410),
                vec!["0x00000000000014aA86C5d3c41765bb24e11bd701".to_string()],
            )
        );
    }

    // zkBob keeps a networks file per deployment: `graph build --network
    // sepolia --network-file ./networks-bob-sepolia.json`, and one for usdc.
    // `ENVIO_SUBGRAPH_NETWORK_FILE` is `--network-file`; a network the
    // scripts pair with a single file takes that file.
    #[test]
    fn builds_the_manifest_from_the_network_file_picked() {
        let dir = tempdir::TempDir::new("envio-subgraph-network-file").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        for (file, address) in [
            (
                "networks-bob-sepolia.json",
                "0x00000000000014aA86C5d3c41765bb24e11bd701",
            ),
            (
                "networks-usdc-sepolia.json",
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC",
            ),
            (
                "networks-bob-base.json",
                "0x1111111111111111111111111111111111111111",
            ),
        ] {
            let network = if file.contains("sepolia") {
                "sepolia"
            } else {
                "base"
            };
            fs::write(
                root.join(file),
                format!(
                    r#"{{"{network}": {{"Gravity": {{"address": "{address}", "startBlock": 1}}}}}}"#
                ),
            )
            .unwrap();
        }
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "build-sepolia-bob": "graph build --network sepolia --network-file ./networks-bob-sepolia.json",
  "build-sepolia-usdc": "graph build --network sepolia --network-file ./networks-usdc-sepolia.json",
  "build-base-bob": "graph build --network base --network-file ./networks-bob-base.json"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=base\n").unwrap();
        let inferred = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        fs::write(
            root.join(".env"),
            "ENVIO_SUBGRAPH_NETWORK=sepolia\nENVIO_SUBGRAPH_NETWORK_FILE=./networks-usdc-sepolia.json\n",
        )
        .unwrap();
        let named = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (chain_of(&inferred).1, chain_of(&named).1),
            (
                vec!["0x1111111111111111111111111111111111111111".to_string()],
                vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()]
            )
        );
    }

    // iExec's PoCo subgraph names no network, and its build passes graph-cli
    // one: `graph build --network ${NETWORK_NAME:-arbitrum-sepolia}`.
    #[test]
    fn builds_the_manifest_for_the_network_the_repo_build_passes() {
        let dir = tempdir::TempDir::new("envio-subgraph-network-default").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("    network: mainnet\n", ""),
        )
        .unwrap();
        fs::write(
            root.join("networks.json"),
            r#"{
  "mainnet": {"Gravity": {"address": "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC", "startBlock": 6175244}},
  "arbitrum-one": {"Gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 416469410}}
}"#,
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "build": "dotenv -e .env -- sh -c 'npm run codegen && graph build --network ${NETWORK_NAME:-arbitrum-one}'",
  "deploy": "graph deploy poco --network ${NETWORK_NAME:-arbitrum-one} --version-label dev",
  "deploy-studio": "graph deploy --studio poco --network ${SUBGRAPH_NETWORK_NAME}"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        // Two defaults that disagree are no default at all.
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "build:mainnet": "graph build --network mainnet",
  "build:arbitrum": "graph build --network arbitrum-one"
}}"#,
        )
        .unwrap();
        let ambiguous = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            (
                config.get_chains().into_iter().next().unwrap().id,
                ambiguous.ends_with(
                    "Pick one, as `graph build --network` does:\n  ENVIO_SUBGRAPH_NETWORK=mainnet"
                ),
            ),
            (42161, true)
        );
    }

    // CryptoPunks names `./abis/WrappedPunks.json` and `./src/marketplaces/…`
    // and commits `abis/wrappedpunks.json` and `src/Marketplaces/`: it builds
    // on macOS, where it was written, and was refused here as a missing ABI.
    #[test]
    fn reads_the_files_a_manifest_names_in_another_case() {
        let dir = tempdir::TempDir::new("envio-subgraph-case").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("./src/gravity.ts", "./src/marketplaces/gravity.ts"),
        )
        .unwrap();
        fs::create_dir_all(root.join("src/Marketplaces")).unwrap();
        fs::rename(
            root.join("src/gravity.ts"),
            root.join("src/Marketplaces/gravity.ts"),
        )
        .unwrap();
        fs::rename(
            root.join("abis/Gravity.json"),
            root.join("abis/gravity.json"),
        )
        .unwrap();

        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let subgraph = SystemConfig::parse_from_project_files(&project_paths)
            .unwrap()
            .subgraph
            .unwrap();

        assert_eq!(
            (
                subgraph.manifest.data_sources[0].mapping_file.as_str(),
                subgraph.path_fixes,
            ),
            (
                "./src/Marketplaces/gravity.ts",
                vec![
                    (
                        "./src/marketplaces/gravity.ts".to_string(),
                        "./src/Marketplaces/gravity.ts".to_string()
                    ),
                    (
                        "./abis/Gravity.json".to_string(),
                        "./abis/gravity.json".to_string()
                    ),
                ]
            )
        );
    }

    // liquity's bold names `../contracts/out/BoldToken.sol/BoldToken.json`,
    // what `forge build` writes in the Foundry project beside it; kleros-v2's
    // `../abis/<network>/` is written by its `sync-abis` script. The error
    // said only "if a build step writes them, run it first". envio builds
    // neither: it names the step.
    #[test]
    fn names_the_build_step_that_writes_a_missing_abi() {
        let dir = tempdir::TempDir::new("envio-subgraph-abi-build").unwrap();
        let root = dir.path();
        let subgraph = root.join("subgraph");
        write_gravity(&subgraph, "subgraph.yaml");
        fs::write(
            subgraph.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace(
                "./abis/Gravity.json",
                "../contracts/out/Gravity.sol/Gravity.json",
            ),
        )
        .unwrap();
        fs::create_dir_all(root.join("contracts")).unwrap();
        fs::write(root.join("contracts/foundry.toml"), "[profile.default]\n").unwrap();
        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "subgraph/subgraph.yaml").unwrap();
        let forge = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        fs::write(
            subgraph.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("./abis/Gravity.json", "../abis/mainnet/Gravity.json"),
        )
        .unwrap();
        // As in kleros-v2, the scripts are the parent package's.
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/sync-abis.sh"),
            "jq .abi \"$DEPLOYMENTS/$1/$name.json\" > \"abis/$1/$name.json\"\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"sync-abis": "./scripts/sync-abis.sh", "codegen": "graph codegen"}}"#,
        )
        .unwrap();
        let script = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            (
                forge.lines().last().unwrap_or_default(),
                script.lines().last().unwrap_or_default()
            ),
            (
                "../contracts is a Foundry project, and `forge build` there writes \
                 ../contracts/out/: run it, then start envio again.",
                "The package.json script \"sync-abis\" (./scripts/sync-abis.sh) writes ../abis/: \
                 run it, then start envio again."
            )
        );
    }

    // sushiswap's legacy exchange subgraph decodes with
    // `../../node_modules/@sushiswap/core/build/abi/UniswapV2Factory.json`, a
    // file of a package its install provides — and the install fails on
    // graph-cli 0.21's vanished gluegun fork. The ABI comes from that package
    // at the version the repo declares, fetched into envio's cache (here
    // already there, so no network).
    #[test]
    fn reads_an_abi_from_the_package_a_failed_install_left_out() {
        let dir = tempdir::TempDir::new("envio-subgraph-abi-package").unwrap();
        let root = dir.path();
        let package = root.join("subgraphs/exchange");
        write_gravity(&package, "subgraph.yaml");
        fs::write(
            package.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace(
                "./abis/Gravity.json",
                "../../node_modules/@sushiswap/core/build/abi/Gravity.json",
            ),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"workspaces": ["subgraphs/*"], "devDependencies": {"@sushiswap/core": "^1.4.2"}}"#,
        )
        .unwrap();
        let cache = root.join("cache");
        let fetched = cache.join("abi-packages/@sushiswap+core@^1.4.2");
        fs::create_dir_all(fetched.join("node_modules/@sushiswap/core/build/abi")).unwrap();
        fs::write(
            fetched.join("node_modules/@sushiswap/core/build/abi/Gravity.json"),
            GRAVITY_ABI,
        )
        .unwrap();
        fs::write(fetched.join(".envio-installed"), "@sushiswap/core@^1.4.2").unwrap();
        fs::write(
            package.join(".env"),
            format!("ENVIO_SUBGRAPH_CACHE_DIR={}\n", cache.display()),
        )
        .unwrap();
        let project_paths =
            ParsedProjectPaths::new(package.to_str().unwrap(), "config.yaml").unwrap();
        let subgraph = SystemConfig::parse_from_project_files(&project_paths)
            .unwrap()
            .subgraph
            .unwrap();

        assert_eq!(
            subgraph
                .path_fixes
                .iter()
                .map(|(written, found)| (written.as_str(), found.ends_with("abi/Gravity.json")))
                .collect::<Vec<_>>(),
            vec![(
                "../../node_modules/@sushiswap/core/build/abi/Gravity.json",
                true
            )]
        );
    }

    // A file under node_modules the install did provide is read where it is:
    // mento's manifest names mappings shipped in @openzeppelin/subgraphs, and
    // the copy in envio's cache (here already there, so no network) may be
    // another version.
    #[test]
    fn reads_a_node_modules_file_the_install_provided_in_place() {
        let dir = tempdir::TempDir::new("envio-subgraph-abi-installed").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace(
                "./abis/Gravity.json",
                "./node_modules/@acme/abis/Gravity.json",
            ),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"devDependencies": {"@acme/abis": "1.0.0"}}"#,
        )
        .unwrap();
        fs::create_dir_all(root.join("node_modules/@acme/abis")).unwrap();
        fs::write(
            root.join("node_modules/@acme/abis/Gravity.json"),
            GRAVITY_ABI,
        )
        .unwrap();
        let cache = root.join("cache");
        let fetched = cache.join("abi-packages/@acme+abis@1.0.0");
        fs::create_dir_all(fetched.join("node_modules/@acme/abis")).unwrap();
        fs::write(
            fetched.join("node_modules/@acme/abis/Gravity.json"),
            GRAVITY_ABI,
        )
        .unwrap();
        fs::write(fetched.join(".envio-installed"), "@acme/abis@1.0.0").unwrap();
        fs::write(
            root.join(".env"),
            format!("ENVIO_SUBGRAPH_CACHE_DIR={}\n", cache.display()),
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let subgraph = SystemConfig::parse_from_project_files(&project_paths)
            .unwrap()
            .subgraph
            .unwrap();

        assert_eq!(subgraph.path_fixes, Vec::<(String, String)>::new());
    }

    // An ABI under node_modules can be a workspace package's own file
    // (kleros-v2 reads `node_modules/@kleros/kleros-v2-contracts/…`, linked
    // from contracts/): with nothing installed it is read from the
    // workspace, never fetched from the registry, whose copy is another
    // version.
    #[test]
    fn reads_an_abi_from_the_workspace_package_node_modules_would_link() {
        let dir = tempdir::TempDir::new("envio-subgraph-abi-workspace").unwrap();
        let root = dir.path();
        let subgraph = root.join("subgraph");
        write_gravity(&subgraph, "subgraph.yaml");
        fs::write(
            subgraph.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace(
                "./abis/Gravity.json",
                "../node_modules/@acme/contracts/abi/Gravity.json",
            ),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"workspaces": ["contracts", "subgraph"]}"#,
        )
        .unwrap();
        fs::create_dir_all(root.join("contracts/abi")).unwrap();
        fs::write(
            root.join("contracts/package.json"),
            r#"{"name": "@acme/contracts"}"#,
        )
        .unwrap();
        fs::write(root.join("contracts/abi/Gravity.json"), GRAVITY_ABI).unwrap();
        fs::write(subgraph.join("package.json"), r#"{"name": "subgraph"}"#).unwrap();
        let project_paths =
            ParsedProjectPaths::new(subgraph.to_str().unwrap(), "config.yaml").unwrap();
        let subgraph_config = SystemConfig::parse_from_project_files(&project_paths)
            .unwrap()
            .subgraph
            .unwrap();

        assert_eq!(
            subgraph_config.path_fixes,
            vec![(
                "../node_modules/@acme/contracts/abi/Gravity.json".to_string(),
                root.join("contracts/abi/Gravity.json")
                    .display()
                    .to_string()
            )]
        );
    }

    // inverse-governance's manifest names `mainnet.schema.graphql`, which
    // OpenZeppelin's graph-compiler writes (`"prepare:subgraph":
    // "graph-compiler --config config/mainnet.json … --export-schema
    // --export-subgraph"`). inverse-governance's subgraph.yaml is a copy of
    // what it writes to generated/, so its paths are `../src/…`, and the
    // error was "Failed to read …"; it names the script, and the manifest the
    // repo's own build uses.
    #[test]
    fn names_the_script_that_writes_a_missing_schema() {
        let dir = tempdir::TempDir::new("envio-subgraph-schema-build").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST
                .replace("./schema.graphql", "mainnet.schema.graphql")
                .replace("./abis/", "../abis/")
                .replace("./src/", "../src/"),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "prepublish": "rimraf artifacts build cache generated",
  "prepare": "mkdir -p generated artifacts && npm run prepare:subgraph",
  "prepare:subgraph": "graph-compiler --config config/mainnet.json --include src/datasources --export-schema --export-subgraph",
  "build:codegen": "graph codegen generated/mainnet.subgraph.yaml",
  "codegen": "graph codegen"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err,
            "The schema mainnet.schema.graphql the manifest names doesn't exist. The \
             package.json script \"prepare:subgraph\" looks like it writes it: graph-compiler \
             --config config/mainnet.json --include src/datasources --export-schema \
             --export-subgraph. Run it, then start envio with --config \
             generated/mainnet.subgraph.yaml, the manifest the script \"build:codegen\" \
             builds."
        );
    }

    // Two files that differ from the name only in case: neither is read, and
    // the error names one.
    #[test]
    fn names_a_missing_abi_file_and_a_case_only_match() {
        let dir = tempdir::TempDir::new("envio-subgraph-abi").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::rename(
            root.join("abis/Gravity.json"),
            root.join("abis/gravity.json"),
        )
        .unwrap();
        fs::write(root.join("abis/GRAVITY.json"), GRAVITY_ABI).unwrap();

        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err,
            format!(
                "These ABI files the manifest names don't exist under {}:\n  \
                 ./abis/Gravity.json, the ABI of \"Gravity\"\n\
                 The manifest's paths are resolved against its own directory, as graph-cli \
                 resolves them. If a build step writes them (forge build, a git submodule, a \
                 copy script), run it first.\n\
                 ./abis/Gravity.json differs only in case from GRAVITY.json, gravity.json, \
                 which do exist: envio can't tell which one the manifest means.",
                root.display()
            )
        );
    }

    // The error used to talk only about config.yaml.
    #[test]
    fn names_the_manifests_there_are_when_config_yaml_is_missing() {
        let dir = tempdir::TempDir::new("envio-subgraph-missing").unwrap();
        let root = dir.path();
        write_gravity(root, "v3-subgraph.yaml");
        fs::write(
            root.join("v3-subgraph.template.yaml"),
            // Uniswap's template parses as YAML; it is not a manifest to run.
            "specVersion: 0.0.4\ndataSources:\n  - network: {{ network }}\n",
        )
        .unwrap();

        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert!(
            err.contains(
                "Found the subgraph manifest v3-subgraph.yaml. To index it, point --config (or \
                 ENVIO_CONFIG) at it:\n  envio start --config v3-subgraph.yaml"
            ),
            "{err}"
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

    // kleros/pgtcr renders its manifest with `node render-templates.js
    // <network>`, a repo file no package.json script runs: envio runs no such
    // file, and said only "run the package prepare script".
    #[test]
    fn names_the_repo_file_that_reads_the_template() {
        let dir = tempdir::TempDir::new("envio-subgraph-template-file").unwrap();
        let root = dir.path();
        fs::write(root.join("subgraph.template.yaml"), "specVersion: 0.0.2\n").unwrap();
        fs::write(
            root.join("render-templates.js"),
            "const template = fs.readFileSync('subgraph.template.yaml').toString();\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"codegen": "graph codegen", "build": "graph build"}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = SystemConfig::parse_from_project_files(&project_paths)
            .unwrap_err()
            .to_string();

        assert_eq!(
            err,
            "Found subgraph.template.yaml but no subgraph.yaml.\nThe repo's render-templates.js \
             reads subgraph.template.yaml, so it likely writes the manifest; no package.json \
             script runs it, so envio doesn't either. Run it for your network, then start envio \
             again."
        );
    }

    fn gravity_template() -> String {
        GRAVITY_MANIFEST
            .replace("network: mainnet", "network: {{network}}")
            .replace(
                "\"0x2E645469f354BB4F5c8a05B3b30A929361cf77eC\"",
                "\"{{gravity.address}}\"",
            )
            .replace("startBlock: 6175244", "startBlock: {{gravity.startBlock}}")
    }

    fn chain_of(config: &SystemConfig) -> (u64, Vec<String>) {
        let chain = config.get_chains().into_iter().next().unwrap();
        (chain.id, chain.contracts[0].addresses.clone())
    }

    // zora-creator's `codegen` runs `yarn gen-yaml-config`, which writes
    // subgraph.yaml with `cat … > subgraph.yaml && yaml2json
    // config/${NETWORK:-…}.yaml | mustache - subgraph.template.yaml >>
    // subgraph.yaml`, and src/constants/chainid.ts the same way. With no
    // subgraph.yaml committed, envio stopped at "Found subgraph.template.yaml
    // but no subgraph.yaml".
    #[test]
    fn renders_the_manifest_a_mustache_script_writes() {
        let dir = tempdir::TempDir::new("envio-subgraph-render").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::write(
            root.join("template_warning.md"),
            "# GENERATED, DO NOT EDIT\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/mainnet.yaml"),
            "network: mainnet\nchainid: \"1\"\ngravity:\n  address: \"0x2E645469f354BB4F5c8a05B3b30A929361cf77eC\"\n  startBlock: 6175244\n",
        )
        .unwrap();
        fs::write(
            root.join("config/arbitrum-one.yaml"),
            "network: arbitrum-one\nchainid: \"42161\"\ngravity:\n  address: \"0x00000000000014aA86C5d3c41765bb24e11bd701\"\n  startBlock: 416469410\n",
        )
        .unwrap();
        fs::write(
            root.join("src/chainid.ts.template"),
            "export const chainid = {{chainid}};\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "codegen": "yarn gen-yaml-config && graph codegen",
  "gen-yaml-config": "cat template_warning.md > subgraph.yaml && yaml2json config/${NETWORK:-mainnet}.yaml | mustache - subgraph.template.yaml >> subgraph.yaml && yaml2json config/${NETWORK:-mainnet}.yaml | mustache - src/chainid.ts.template > src/chainid.ts"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();

        // The script's own default network, as `yarn codegen` renders it.
        let default = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let rendered = default.subgraph.clone().unwrap().rendered_manifest.unwrap();

        // The file envio wrote is rendered again for the network picked.
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=arbitrum-one\n").unwrap();
        let picked = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&default),
                (
                    rendered.script.as_str(),
                    rendered.network.as_str(),
                    rendered.view.as_str()
                ),
                chain_of(&picked),
                fs::read_to_string(root.join("subgraph.yaml"))
                    .unwrap()
                    .starts_with("# GENERATED, DO NOT EDIT\n\nspecVersion: 0.0.5\n"),
                fs::read_to_string(root.join("src/chainid.ts")).unwrap(),
            ),
            (
                (
                    1,
                    vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()]
                ),
                ("gen-yaml-config", "mainnet", "config/mainnet.yaml"),
                (
                    42161,
                    vec!["0x00000000000014aA86C5d3c41765bb24e11bd701".to_string()]
                ),
                true,
                "export const chainid = 42161;\n".to_string(),
            )
        );
    }

    // sushiswap's legacy subgraphs: `"prepare:matic": "mustache
    // ../../config/matic.json template.yaml > subgraph.yaml"`, one script per
    // network, in each workspace package.
    #[test]
    fn renders_the_manifest_of_the_per_network_script_picked() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-literal").unwrap();
        let root = dir.path();
        let package = root.join("subgraphs/exchange");
        write_gravity(&package, "template.yaml");
        fs::write(package.join("template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/mainnet.json"),
            r#"{"network": "mainnet", "gravity": {"address": "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC", "startBlock": 6175244}}"#,
        )
        .unwrap();
        fs::write(
            root.join("config/matic.json"),
            r#"{"network": "matic", "gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 1000}}"#,
        )
        .unwrap();
        fs::write(
            package.join("package.json"),
            r#"{"scripts": {
  "codegen": "graph codegen subgraph.yaml",
  "prepare:mainnet": "mustache ../../config/mainnet.json template.yaml > subgraph.yaml",
  "prepare:matic": "mustache ../../config/matic.json template.yaml > subgraph.yaml"
}}"#,
        )
        .unwrap();
        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "subgraphs/exchange/subgraph.yaml")
                .unwrap();

        let unset = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=bsc\n").unwrap();
        let unknown = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=matic\n").unwrap();
        let picked = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (unset, unknown, chain_of(&picked)),
            (
                "There is no subgraph.yaml here: the package.json scripts prepare:mainnet, \
                 prepare:matic render it from template.yaml for one network at a time (mainnet, \
                 matic). Pick the network, as the script's argument does:\n  \
                 ENVIO_SUBGRAPH_NETWORK=mainnet"
                    .to_string(),
                "ENVIO_SUBGRAPH_NETWORK names the network 'bsc', but the package.json scripts \
                 that render subgraph.yaml (prepare:mainnet, prepare:matic) render it for: \
                 mainnet, matic."
                    .to_string(),
                (
                    137,
                    vec!["0x00000000000014aA86C5d3c41765bb24e11bd701".to_string()]
                ),
            )
        );
    }

    // matic's root subgraph: `"prepare:mainnet": "mustache config/mainnet.json
    // subgraph.template.yaml > subgraph.yaml && mustache config/mainnet.json
    // src/network.template.ts > src/network.ts"`. With subgraph.yaml in place
    // (committed, or written by hand) and src/network.ts gitignored, the
    // mapping failed to load `./network`. The script renders exactly that
    // manifest for mainnet, so mainnet's src/network.ts is written; the
    // manifest itself is left alone.
    #[test]
    fn writes_the_companion_files_of_the_render_that_made_the_manifest() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-companion").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::write(
            root.join("src/network.template.ts"),
            "export const NETWORK = \"{{network}}\";\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        for (network, address) in [
            ("mainnet", "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"),
            ("goerli", "0x00000000000014aA86C5d3c41765bb24e11bd701"),
        ] {
            fs::write(
                root.join(format!("config/{network}.json")),
                format!(
                    r#"{{"network": "{network}", "gravity": {{"address": "{address}", "startBlock": 6175244}}}}"#
                ),
            )
            .unwrap();
        }
        let scripts: Vec<String> = ["mainnet", "goerli"]
            .iter()
            .map(|network| {
                format!(
                    "\"prepare:{network}\": \"mustache config/{network}.json subgraph.template.yaml > \
                     subgraph.yaml && mustache config/{network}.json src/network.template.ts > \
                     src/network.ts\""
                )
            })
            .collect();
        fs::write(
            root.join("package.json"),
            format!("{{\"scripts\": {{{}}}}}", scripts.join(", ")),
        )
        .unwrap();
        fs::write(root.join("subgraph.yaml"), GRAVITY_MANIFEST).unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&config).0,
                fs::read_to_string(root.join("src/network.ts")).ok(),
                fs::read_to_string(root.join("subgraph.yaml")).unwrap() == GRAVITY_MANIFEST,
            ),
            (
                1,
                Some("export const NETWORK = \"mainnet\";\n".to_string()),
                true
            )
        );
    }

    // moonwell renders in a Makefile target, not a package.json script:
    // `generate-config:` runs `YARN_SILENT=1 yarn mustache
    // config/$(network).subgraph.json subgraph.mustache > subgraph.yaml && cp
    // config/$(network).config.ts config/config.ts`, given `make
    // generate-config network=base`.
    #[test]
    fn renders_the_manifest_a_makefile_target_writes() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-make").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.mustache");
        fs::write(root.join("subgraph.mustache"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/base.subgraph.json"),
            r#"{"network": "base", "gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 1}}"#,
        )
        .unwrap();
        fs::write(
            root.join("config/base.config.ts"),
            "export const NETWORK = \"base\";\n",
        )
        .unwrap();
        fs::write(root.join("package.json"), r#"{"scripts": {}}"#).unwrap();
        fs::write(
            root.join("Makefile"),
            "graph_access_token ?= $(GRAPH_ACCESS_TOKEN)\n\nclean:\n\trm -rf subgraph.yaml generated/\n\n\
             generate-config:\n\tYARN_SILENT=1 yarn mustache config/$(network).subgraph.json \
             subgraph.mustache > subgraph.yaml && \\\n\tcp config/$(network).config.ts \
             config/config.ts\n\ncodegen:\n\tyarn graph codegen\n",
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let rendered = config.subgraph.clone().unwrap().rendered_manifest.unwrap();

        assert_eq!(
            (
                chain_of(&config).0,
                rendered.script,
                fs::read_to_string(root.join("config/config.ts")).ok(),
            ),
            (
                8453,
                "make generate-config".to_string(),
                Some("export const NETWORK = \"base\";\n".to_string())
            )
        );
    }

    // A workspace root's scripts render into a package: `"prepare:matic":
    // "mustache config/matic.json subgraphs/exchange/template.yaml >
    // subgraphs/exchange/subgraph.yaml"` (pangolin's root `template` script
    // writes src/<subgraph>/ the same way, through a node script). Only the
    // manifest's own package.json was read.
    #[test]
    fn renders_the_manifest_a_parent_package_script_writes() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-parent").unwrap();
        let root = dir.path();
        let package = root.join("subgraphs/exchange");
        write_gravity(&package, "template.yaml");
        fs::write(package.join("template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/matic.json"),
            r#"{"network": "matic", "gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 1}}"#,
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"workspaces": ["subgraphs/*"], "scripts": {"prepare:matic": "mustache config/matic.json subgraphs/exchange/template.yaml > subgraphs/exchange/subgraph.yaml"}}"#,
        )
        .unwrap();
        fs::write(package.join("package.json"), r#"{"name": "exchange"}"#).unwrap();
        let project_paths =
            ParsedProjectPaths::new(package.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(chain_of(&config).0, 137);
    }

    // sushiswap's legacy monorepo: the root's `"prepare:mainnet": "yarn
    // workspaces run prepare:mainnet"` runs every package's own
    // `prepare:mainnet`, which renders subgraphs/exchange/subgraph.yaml there
    // and packages/constants/index.ts (the `const` package the mappings
    // import) in its own directory.
    #[test]
    fn renders_through_a_workspace_wide_script() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-fanout").unwrap();
        let root = dir.path();
        let exchange = root.join("subgraphs/exchange");
        write_gravity(&exchange, "template.yaml");
        fs::write(exchange.join("template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::create_dir_all(root.join("packages/constants")).unwrap();
        for (network, address) in [
            ("mainnet", "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"),
            ("matic", "0x00000000000014aA86C5d3c41765bb24e11bd701"),
        ] {
            fs::write(
                root.join(format!("config/{network}.json")),
                format!(
                    r#"{{"network": "{network}", "gravity": {{"address": "{address}", "startBlock": 1}}}}"#
                ),
            )
            .unwrap();
        }
        let per_network = |output: &str, template: &str| -> String {
            ["mainnet", "matic"]
                .iter()
                .map(|network| {
                    format!(
                        "\"prepare:{network}\": \"mustache ../../config/{network}.json {template} > {output}\""
                    )
                })
                .collect::<Vec<_>>()
                .join(", ")
        };
        fs::write(
            root.join("package.json"),
            r#"{"private": true, "workspaces": ["packages/*", "subgraphs/*"], "scripts": {
  "prepare:mainnet": "yarn workspaces run prepare:mainnet",
  "prepare:matic": "yarn workspaces run prepare:matic"
}}"#,
        )
        .unwrap();
        fs::write(
            exchange.join("package.json"),
            format!(
                "{{\"name\": \"exchange\", \"scripts\": {{{}}}}}",
                per_network("subgraph.yaml", "template.yaml")
            ),
        )
        .unwrap();
        fs::write(
            root.join("packages/constants/package.json"),
            format!(
                "{{\"name\": \"const\", \"main\": \"index.ts\", \"scripts\": {{{}}}}}",
                per_network("index.ts", "index.template.ts")
            ),
        )
        .unwrap();
        fs::write(
            root.join("packages/constants/index.template.ts"),
            "export const NETWORK = \"{{network}}\";\n",
        )
        .unwrap();
        fs::write(exchange.join(".env"), "ENVIO_SUBGRAPH_NETWORK=matic\n").unwrap();
        let project_paths =
            ParsedProjectPaths::new(exchange.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&config).0,
                fs::read_to_string(root.join("packages/constants/index.ts")).ok(),
            ),
            (137, Some("export const NETWORK = \"matic\";\n".to_string()))
        );
    }

    // defi.money: `"codegen:arb": "cat ./subgraph/arbitrum/prod.yaml >
    // subgraph.yaml && graph codegen"`, one per network. The scripts call it
    // `arb`, its directory `arbitrum`, the manifest `arbitrum-one`: the
    // network a user names is matched against what each manifest indexes too.
    #[test]
    fn picks_the_copied_manifest_by_the_network_it_indexes() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-cat").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        for (folder, network) in [("optimism", "optimism"), ("arbitrum", "arbitrum-one")] {
            fs::create_dir_all(root.join(format!("subgraph/{folder}"))).unwrap();
            fs::write(
                root.join(format!("subgraph/{folder}/prod.yaml")),
                GRAVITY_MANIFEST.replace("network: mainnet", &format!("network: {network}")),
            )
            .unwrap();
        }
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "codegen:op": "cat ./subgraph/optimism/prod.yaml > subgraph.yaml && graph codegen",
  "codegen:arb": "cat ./subgraph/arbitrum/prod.yaml > subgraph.yaml && graph codegen",
  "codegen": "graph codegen"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=arbitrum-one\n").unwrap();
        let by_manifest = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=op\n").unwrap();
        let by_script = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (chain_of(&by_manifest).0, chain_of(&by_script).0),
            (42161, 10)
        );
    }

    // FilOzone's filecoin-pay subgraph: `"generate:yaml": "mustache
    // ./config/${NETWORK:-calibration}.json ./templates/subgraph.template.yaml
    // > subgraph.yaml"` and `"generate:schema": "cp
    // ./schemas/schema.${VERSION:-v1}.graphql schema.graphql"`, which its
    // `precodegen` hook runs together. The schema the manifest names is
    // written by a script of standard tools too, so it is repeated.
    #[test]
    fn writes_a_missing_manifest_input_a_standard_script_writes() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-inputs").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        fs::create_dir_all(root.join("templates")).unwrap();
        fs::create_dir_all(root.join("schemas")).unwrap();
        fs::rename(
            root.join("schema.graphql"),
            root.join("schemas/schema.v1.graphql"),
        )
        .unwrap();
        fs::write(
            root.join("templates/subgraph.template.yaml"),
            gravity_template(),
        )
        .unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/calibration.json"),
            r#"{"network": "mainnet", "gravity": {"address": "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC", "startBlock": 1}}"#,
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "precodegen": "rm -rf ./generated && pnpm generate:schema && pnpm generate:yaml",
  "codegen": "graph codegen",
  "generate:yaml": "mustache ./config/${NETWORK:-calibration}.json ./templates/subgraph.template.yaml > subgraph.yaml",
  "generate:schema": "cp ./schemas/schema.${VERSION:-v1}.graphql schema.graphql"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (chain_of(&config).0, root.join("schema.graphql").exists()),
            (1, true)
        );
    }

    // dolomite splits the render in two scripts per network:
    // `mustache-template:<net>` writes subgraph.yaml, `mustache-constants:<net>`
    // writes src/mappings/generated/constants.ts. The manifest there (here
    // reformatted, as another renderer leaves it) is one network's render, so
    // that network's constants are written.
    #[test]
    fn writes_the_sibling_companions_of_a_manifest_another_renderer_wrote() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-sibling-companion").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("src/templates")).unwrap();
        fs::write(
            root.join("src/templates/constants.template.ts"),
            "export const NETWORK = \"{{network}}\";\n",
        )
        .unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        for (network, address) in [
            ("mainnet", "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"),
            ("base", "0x00000000000014aA86C5d3c41765bb24e11bd701"),
        ] {
            fs::write(
                root.join(format!("config/{network}.json")),
                format!(
                    r#"{{"network": "{network}", "gravity": {{"address": "{address}", "startBlock": 6175244}}}}"#
                ),
            )
            .unwrap();
        }
        let scripts: Vec<String> = ["mainnet", "base"]
            .iter()
            .flat_map(|network| {
                [
                    format!(
                        "\"mustache-template:{network}\": \"mustache config/{network}.json \
                         subgraph.template.yaml > subgraph.yaml\""
                    ),
                    format!(
                        "\"mustache-constants:{network}\": \"mkdir -p src/mappings/generated && \
                         mustache config/{network}.json src/templates/constants.template.ts > \
                         src/mappings/generated/constants.ts\""
                    ),
                    format!(
                        "\"prepare:{network}\": \"yarn mustache-template:{network} && yarn \
                         mustache-constants:{network}\""
                    ),
                ]
            })
            .collect();
        fs::write(
            root.join("package.json"),
            format!("{{\"scripts\": {{{}}}}}", scripts.join(", ")),
        )
        .unwrap();
        fs::write(
            root.join("subgraph.yaml"),
            GRAVITY_MANIFEST.replace("dataSources:\n", "dataSources:\n\n"),
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&config).0,
                fs::read_to_string(root.join("src/mappings/generated/constants.ts")).ok(),
            ),
            (1, Some("export const NETWORK = \"mainnet\";\n".to_string()))
        );
    }

    // A committed subgraph.yaml is the user's: a render script beside it
    // (GoodCollective's `prepare`) doesn't overwrite it.
    #[test]
    fn leaves_a_committed_manifest_beside_its_render_script_alone() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-committed").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/matic.json"),
            r#"{"network": "matic", "gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 1}}"#,
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"prepare": "mustache config/${0}.json subgraph.template.yaml > subgraph.yaml"}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&config).0,
                fs::read_to_string(root.join("subgraph.yaml")).unwrap() == GRAVITY_MANIFEST,
            ),
            (1, true)
        );
    }

    // cope-market's `"codegen": "node scripts/build-manifest.mjs
    // ${NETWORK:-arc-testnet} && graph codegen"` writes subgraph.yaml in the
    // step envio's codegen runs before `graph codegen` anyway (§6a); the
    // missing manifest stopped envio before it got there.
    #[test]
    fn runs_the_codegen_steps_that_write_the_manifest() {
        let dir = tempdir::TempDir::new("envio-subgraph-codegen-prelude").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(
            root.join("subgraph.template.yaml"),
            GRAVITY_MANIFEST.replace("network: mainnet", "network: NETWORK"),
        )
        .unwrap();
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/build-manifest.sh"),
            "sed \"s/network: NETWORK/network: $1/\" subgraph.template.yaml > subgraph.yaml\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"codegen": "sh scripts/build-manifest.sh ${NETWORK:-mainnet} && graph codegen"}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();

        let default = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=arbitrum-one\n").unwrap();
        let picked = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let rendered = picked.subgraph.clone().unwrap().rendered_manifest.unwrap();

        assert_eq!(
            (
                chain_of(&default).0,
                chain_of(&picked).0,
                rendered.script,
                rendered.steps
            ),
            (
                1,
                42161,
                "codegen".to_string(),
                vec!["sh scripts/build-manifest.sh ${NETWORK:-mainnet}".to_string()]
            )
        );
    }

    // Seamless' leverage-tokens subgraph: `"generate-manifest-base": "mustache
    // ./networks.json ./templates/8453/subgraph.template.yaml > ./subgraph.yaml"`
    // and `"generate-addresses-base": "mustache ./networks.json
    // ./templates/8453/addresses.template.ts > ./src/constants/addresses.ts"`,
    // the same per network. One view for every network, so the networks are
    // the scripts' names; and the network's other render script writes what
    // the mappings import beside the manifest.
    #[test]
    fn names_networks_after_their_scripts_and_runs_their_sibling_renders() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-siblings").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        for (chain, network) in [("8453", "base"), ("1", "ethereum")] {
            fs::create_dir_all(root.join(format!("templates/{chain}"))).unwrap();
            fs::write(
                root.join(format!("templates/{chain}/subgraph.template.yaml")),
                gravity_template()
                    .replace(
                        "{{network}}",
                        network.replace("ethereum", "mainnet").as_str(),
                    )
                    .replace("{{gravity.", &format!("{{{{{network}.")),
            )
            .unwrap();
            fs::write(
                root.join(format!("templates/{chain}/addresses.template.ts")),
                format!("export const GRAVITY = \"{{{{{network}.address}}}}\";\n"),
            )
            .unwrap();
        }
        fs::write(
            root.join("networks.json"),
            r#"{"base": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 1},
"ethereum": {"address": "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC", "startBlock": 6175244}}"#,
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "generate-manifest-base": "mustache ./networks.json ./templates/8453/subgraph.template.yaml > ./subgraph.yaml",
  "generate-manifest-ethereum": "mustache ./networks.json ./templates/1/subgraph.template.yaml > ./subgraph.yaml",
  "generate-addresses-base": "mustache ./networks.json ./templates/8453/addresses.template.ts > ./src/constants/addresses.ts",
  "generate-addresses-ethereum": "mustache ./networks.json ./templates/1/addresses.template.ts > ./src/constants/addresses.ts",
  "codegen": "rm -rf ./generated && graph codegen"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let unset = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=base\n").unwrap();
        let picked = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                unset.contains("(base, ethereum)"),
                chain_of(&picked).0,
                fs::read_to_string(root.join("src/constants/addresses.ts")).ok(),
            ),
            (
                true,
                8453,
                Some(
                    "export const GRAVITY = \"0x00000000000014aA86C5d3c41765bb24e11bd701\";\n"
                        .to_string()
                ),
            )
        );
    }

    // FilOzone's dealbot commits its manifest but not its ABIs: `"codegen":
    // "pnpm run sync-abis && graph codegen"`, and `sync-abis` writes abis/
    // from the installed @filoz/synapse-core. envio runs those steps at
    // codegen anyway (§6a), but the translation needs the ABIs before that,
    // and stopped at "These ABI files the manifest names don't exist". A
    // codegen step that writes the manifest itself doesn't run for them: the
    // manifest there is the user's.
    #[test]
    fn runs_the_codegen_steps_that_write_the_missing_abis() {
        let project = |codegen: &str| {
            let dir = tempdir::TempDir::new("envio-subgraph-codegen-abis").unwrap();
            write_gravity(dir.path(), "subgraph.yaml");
            fs::remove_file(dir.path().join("abis/Gravity.json")).unwrap();
            fs::create_dir_all(dir.path().join("scripts")).unwrap();
            fs::write(
                dir.path().join("scripts/sync-abis.sh"),
                format!("mkdir -p abis && printf '%s' '{GRAVITY_ABI}' > abis/Gravity.json\n"),
            )
            .unwrap();
            fs::write(
                dir.path().join("package.json"),
                format!(
                    r#"{{"scripts": {{"sync-abis": "sh scripts/sync-abis.sh", "codegen": "{codegen}"}}}}"#
                ),
            )
            .unwrap();
            dir
        };
        let outcome = |dir: &tempdir::TempDir| {
            let project_paths =
                ParsedProjectPaths::new(dir.path().to_str().unwrap(), "config.yaml").unwrap();
            match SystemConfig::parse_from_project_files(&project_paths) {
                Ok(config) => format!("{}", chain_of(&config).0),
                Err(err) => format!("{err:#}")
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_string(),
            }
        };
        let dealbot = project("npm run sync-abis && graph codegen");
        let rewrites_manifest = project(
            "sh scripts/sync-abis.sh && cp subgraph.yaml subgraph.yaml.bak && graph codegen",
        );

        assert_eq!(
            (
                outcome(&dealbot),
                outcome(&rewrites_manifest),
                rewrites_manifest.path().join("subgraph.yaml.bak").exists()
            ),
            (
                "1".to_string(),
                format!(
                    "These ABI files the manifest names don't exist under {}:",
                    rewrites_manifest.path().canonicalize().unwrap().display()
                ),
                false
            )
        );
    }

    // balancer-v2's `"codegen": "npm run generate-manifests && graph codegen
    // subgraph.mainnet.yaml --output-dir src/types/"`: the steps before
    // `graph codegen` write subgraph.<network>.yaml, and the codegen step
    // names which one it builds. envio looked only for subgraph.yaml.
    #[test]
    fn runs_the_manifest_the_codegen_step_names() {
        let dir = tempdir::TempDir::new("envio-subgraph-codegen-names").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/generate-manifests.sh"),
            "cp subgraph.template.yaml subgraph.mainnet.yaml\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "generate-manifests": "sh scripts/generate-manifests.sh",
  "codegen": "npm run generate-manifests && graph codegen subgraph.mainnet.yaml --output-dir src/types/"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (chain_of(&config).0, config.subgraph.unwrap().manifest_file,),
            (1, "subgraph.mainnet.yaml".to_string())
        );
    }

    // beefy's `"codegen": "rm -Rf generated && graph codegen"`: a step before
    // `graph codegen` that can't write a manifest isn't the manifest's
    // writer. envio ran it and blamed it; the error is about the script that
    // does write the manifest (`configure`, ./bin/prepare.sh), which envio
    // runs as the one that does, and which wants its chain as an argument.
    #[test]
    fn passes_over_codegen_steps_that_write_no_manifest() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir::TempDir::new("envio-subgraph-codegen-noop").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::write(
            root.join("bin/prepare.sh"),
            "#!/bin/sh\n[ -n \"$1\" ] || { echo \"Usage: $0 <chain>\"; exit 1; }\njq -r . config/$1.json | sed -f - subgraph.template.yaml > subgraph.yaml\n",
        )
        .unwrap();
        fs::set_permissions(
            root.join("bin/prepare.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"codegen": "rm -Rf generated && graph codegen", "configure": "./bin/prepare.sh"}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err.lines().collect::<Vec<_>>(),
            vec![
                "There is no subgraph.yaml here, and the package.json script \"configure\" writes \
                 it: envio ran `./bin/prepare.sh` from it, and it exited with 1 — the error above \
                 is the script's own.",
            ]
        );
    }

    // Only the codegen script's own steps run, as §6a runs them: a script that
    // writes the manifest anywhere else in package.json — lifecycle hooks
    // included — is named, never run.
    #[test]
    fn runs_no_script_but_the_codegen_scripts_steps() {
        let dir = tempdir::TempDir::new("envio-subgraph-codegen-only").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/write.sh"),
            "touch \"ran-$1\" && cp subgraph.template.yaml subgraph.yaml\n",
        )
        .unwrap();
        let scripts = [
            "preinstall",
            "install",
            "postinstall",
            "prepare",
            "build",
            "manifest",
        ];
        let entries: Vec<String> = scripts
            .iter()
            .map(|name| format!("\"{name}\": \"sh scripts/write.sh {name}\""))
            .collect();
        fs::write(
            root.join("package.json"),
            format!(
                "{{\"scripts\": {{{}, \"codegen\": \"graph codegen\"}}}}",
                entries.join(", ")
            ),
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        let ran: Vec<&str> = scripts
            .iter()
            .copied()
            .filter(|name| root.join(format!("ran-{name}")).exists())
            .collect();

        let named: Vec<&str> = err
            .lines()
            .filter_map(|line| line.strip_prefix("  \""))
            .filter_map(|line| line.split('"').next())
            .collect();

        assert_eq!(
            (ran, root.join("subgraph.yaml").exists(), named),
            (Vec::<&str>::new(), false, scripts.to_vec())
        );
    }

    fn ran_markers(root: &std::path::Path) -> Vec<String> {
        let mut ran: Vec<String> = fs::read_dir(root)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter_map(|name| name.strip_prefix("ran-").map(str::to_string))
            .collect();
        ran.sort();
        ran
    }

    // Venus writes its manifest with `"prepare:bsc": "NETWORK=bsc yarn
    // ts-node config/index.ts"`, one script per network, and Polymarket with
    // `ts-node ./templatify.ts`: the repo's own code, which envio can't
    // repeat itself. The one script that writes the manifest for the network
    // picked runs as it is, up to graph-cli. Nothing else runs: not another
    // network's, not a deploy script, not a step after `graph codegen`, and
    // with no network picked, none of the per-network ones.
    #[test]
    fn runs_the_one_script_that_writes_the_manifest() {
        let dir = tempdir::TempDir::new("envio-subgraph-writer-script").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(
            root.join("subgraph.template.yaml"),
            GRAVITY_MANIFEST.replace("network: mainnet", "network: NETWORK"),
        )
        .unwrap();
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/write.sh"),
            "touch \"ran-$1\"\nsed \"s/network: NETWORK/network: $1/\" subgraph.template.yaml > subgraph.yaml\n",
        )
        .unwrap();
        fs::write(root.join("scripts/mark.sh"), "touch \"ran-$1\"\n").unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "prepare:mainnet": "sh scripts/write.sh mainnet && graph codegen",
  "prepare:arbitrum-one": "sh scripts/write.sh arbitrum-one && yarn codegen && sh scripts/mark.sh after-codegen",
  "deploy:arbitrum-one": "sh scripts/write.sh deploy && sh scripts/mark.sh deployed",
  "codegen": "graph codegen",
  "test": "sh scripts/mark.sh test"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();

        let unset = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        let ran_unset = ran_markers(root);
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=arbitrum-one\n").unwrap();
        let picked = SystemConfig::parse_from_project_files(&project_paths).unwrap();
        let rendered = picked.subgraph.clone().unwrap().rendered_manifest.unwrap();

        assert_eq!(
            (
                unset.contains("ENVIO_SUBGRAPH_NETWORK"),
                ran_unset,
                chain_of(&picked).0,
                ran_markers(root),
                rendered.script,
                rendered.commands,
            ),
            (
                true,
                Vec::<String>::new(),
                42161,
                vec!["arbitrum-one".to_string()],
                "prepare:arbitrum-one".to_string(),
                vec!["sh scripts/write.sh arbitrum-one".to_string()],
            )
        );
    }

    // Of the scripts that build for the network picked, the one that writes
    // the manifest runs:
    // - The Graph's network subgraph: `prepare:mainnet` runs
    //   `prep:addresses:mainnet` (which writes only addresses.ts, and the
    //   generatedAddresses.json input) before rendering the manifest itself;
    // - Reserve's `parse:fork` passes `--output subgraph.fork.yaml`;
    // - FilOzone's `generate:yaml:mainnet` runs a file that writes
    //   subgraph.yaml, `generate:constants:mainnet` one that doesn't.
    #[test]
    fn runs_the_script_that_writes_the_manifest_of_those_for_the_network() {
        let project = |files: &[(&str, &str)]| {
            let dir = tempdir::TempDir::new("envio-subgraph-writer-pick").unwrap();
            write_gravity(dir.path(), "subgraph.template.yaml");
            fs::write(
                dir.path().join("subgraph.template.yaml"),
                GRAVITY_MANIFEST.replace("network: mainnet", "network: NETWORK"),
            )
            .unwrap();
            for (file, text) in files {
                let path = dir.path().join(file);
                fs::create_dir_all(path.parent().unwrap()).unwrap();
                fs::write(path, text).unwrap();
            }
            fs::write(dir.path().join(".env"), "ENVIO_SUBGRAPH_NETWORK=mainnet\n").unwrap();
            dir
        };
        let picked = |dir: &tempdir::TempDir| {
            let project_paths =
                ParsedProjectPaths::new(dir.path().to_str().unwrap(), "config.yaml").unwrap();
            match SystemConfig::parse_from_project_files(&project_paths) {
                Ok(config) => config.subgraph.unwrap().rendered_manifest.unwrap().script,
                Err(err) => format!("{err:#}"),
            }
        };
        let network = project(&[
            (
                "config/addresses.sh",
                "echo \"s/network: NETWORK/network: $1/\" > config/generatedAddresses.sed\n",
            ),
            (
                "config/addresses.template.ts",
                "export const NETWORK = \"X\";\n",
            ),
            (
                "package.json",
                r#"{"scripts": {
  "prep:addresses:mainnet": "sh config/addresses.sh mainnet && sed s/X/mainnet/ ./config/addresses.template.ts > ./config/addresses.ts",
  "prep:addresses:arbitrum": "sh config/addresses.sh arbitrum-one && sed s/X/arbitrum/ ./config/addresses.template.ts > ./config/addresses.ts",
  "prepare:mainnet": "yarn prep:addresses:mainnet && sed -f ./config/generatedAddresses.sed subgraph.template.yaml > subgraph.yaml && graph codegen",
  "prepare:arbitrum": "yarn prep:addresses:arbitrum && sed -f ./config/generatedAddresses.sed subgraph.template.yaml > subgraph.yaml && graph codegen"
}}"#,
            ),
        ]);
        let reserve = project(&[
            (
                "scripts/parse.sh",
                "out=subgraph.yaml; [ \"$2\" = --output ] && out=$3\nsed \"s/network: NETWORK/network: $1/\" subgraph.template.yaml > $out\n",
            ),
            (
                "package.json",
                r#"{"scripts": {
  "parse:fork": "sh scripts/parse.sh mainnet --output subgraph.fork.yaml",
  "parse:mainnet": "sh scripts/parse.sh mainnet",
  "parse:base": "sh scripts/parse.sh base"
}}"#,
            ),
        ]);
        let filoz = project(&[
            (
                "scripts/gen-config.sh",
                "sed \"s/network: NETWORK/network: $1/\" subgraph.template.yaml > subgraph.yaml\n",
            ),
            (
                "scripts/gen-constants.sh",
                "sed s/X/$1/ src/constants.template.ts > src/constants.ts\n",
            ),
            (
                "src/constants.template.ts",
                "export const NETWORK = \"X\";\n",
            ),
            (
                "package.json",
                r#"{"scripts": {
  "generate:constants:mainnet": "sh scripts/gen-constants.sh mainnet",
  "generate:constants:calibration": "sh scripts/gen-constants.sh calibration",
  "generate:yaml:mainnet": "sh scripts/gen-config.sh mainnet",
  "generate:yaml:calibration": "sh scripts/gen-config.sh calibration"
}}"#,
            ),
        ]);

        assert_eq!(
            (picked(&network), picked(&reserve), picked(&filoz)),
            (
                "prepare:mainnet".to_string(),
                "parse:mainnet".to_string(),
                "generate:yaml:mainnet".to_string()
            )
        );
    }

    // beefy's `"configure": "./bin/prepare.sh"` takes its chain as its first
    // argument (`CHAIN=$1`; its README: `yarn configure <chain>`), and NFTX's
    // `ts-node ./script/build` its network (`const network =
    // process.argv[2]`). envio ran them without one, and they exited on their
    // usage message. The network picked is passed as that argument, as `npm
    // run <script> -- <network>` passes it; a script whose first argument is
    // something else (an output path) isn't given it.
    #[test]
    fn passes_the_network_to_a_script_that_takes_it_as_its_first_argument() {
        use std::os::unix::fs::PermissionsExt;
        let project = |script: &str, body: &str| {
            let dir = tempdir::TempDir::new("envio-subgraph-writer-argument").unwrap();
            write_gravity(dir.path(), "subgraph.template.yaml");
            fs::write(
                dir.path().join("subgraph.template.yaml"),
                GRAVITY_MANIFEST.replace("network: mainnet", "network: NETWORK"),
            )
            .unwrap();
            fs::create_dir_all(dir.path().join("bin")).unwrap();
            fs::write(dir.path().join("bin/prepare.sh"), body).unwrap();
            fs::set_permissions(
                dir.path().join("bin/prepare.sh"),
                fs::Permissions::from_mode(0o755),
            )
            .unwrap();
            fs::write(
                dir.path().join("package.json"),
                format!(
                    r#"{{"scripts": {{"configure": "{script}", "codegen": "graph codegen"}}}}"#
                ),
            )
            .unwrap();
            fs::write(dir.path().join(".env"), "ENVIO_SUBGRAPH_NETWORK=base\n").unwrap();
            dir
        };
        let outcome = |dir: &tempdir::TempDir| {
            let project_paths =
                ParsedProjectPaths::new(dir.path().to_str().unwrap(), "config.yaml").unwrap();
            match SystemConfig::parse_from_project_files(&project_paths) {
                Ok(config) => format!(
                    "{} {:?}",
                    chain_of(&config).0,
                    config.subgraph.unwrap().rendered_manifest.unwrap().commands
                ),
                Err(err) => format!("{err:#}")
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .to_string(),
            }
        };
        let chain = project(
            "./bin/prepare.sh",
            "#!/bin/sh\nCHAIN=$1\n[ -n \"$CHAIN\" ] || { echo \"Usage: $0 <chain>\"; exit 1; }\nsed \"s/network: NETWORK/network: $CHAIN/\" subgraph.template.yaml > subgraph.yaml\n",
        );
        let output_path = project(
            "./bin/prepare.sh",
            "#!/bin/sh\nOUT=${1:-subgraph.yaml}\nsed \"s/network: NETWORK/network: mainnet/\" subgraph.template.yaml > $OUT\n",
        );
        // Decentraland's buildData.ts: `if (process.argv[i] === '--network')`.
        let option = project(
            "./bin/prepare.sh",
            "#!/bin/sh\n[ \"$1\" = '--network' ] || { echo \"Supply a valid network using --network\"; exit 1; }\nsed \"s/network: NETWORK/network: $2/\" subgraph.template.yaml > subgraph.yaml\n",
        );
        // UMA has both `"build-manifest": "scripts/build-manifest.sh"` and
        // `"prepare:polygon": "scripts/build-manifest.sh polygon && …"`: given
        // the network, the first runs what the second does.
        let both = project(
            "./bin/prepare.sh",
            "#!/bin/sh\nCHAIN=$1\nsed \"s/network: NETWORK/network: $CHAIN/\" subgraph.template.yaml > subgraph.yaml\n",
        );
        fs::write(
            both.path().join("package.json"),
            r#"{"scripts": {"build-manifest": "./bin/prepare.sh", "prepare:base": "./bin/prepare.sh base && yarn codegen", "prepare:mainnet": "./bin/prepare.sh mainnet && yarn codegen", "codegen": "graph codegen"}}"#,
        )
        .unwrap();

        // Polymarket's `"prepare:mainnet": "NETWORK_NAME=mainnet ts-node
        // ./templatify.ts"` names its network itself: it isn't given another.
        let named = project(
            "./bin/prepare.sh",
            "#!/bin/sh\nCHAIN=$1\nsed \"s/network: NETWORK/network: $CHAIN/\" subgraph.template.yaml > subgraph.yaml\n",
        );
        fs::write(
            named.path().join("package.json"),
            r#"{"scripts": {"prepare:mainnet": "NETWORK_NAME=mainnet ./bin/prepare.sh"}}"#,
        )
        .unwrap();

        assert_eq!(
            (
                outcome(&chain),
                outcome(&output_path),
                outcome(&option),
                outcome(&both),
                outcome(&named)
            ),
            (
                "8453 [\"./bin/prepare.sh base\"]".to_string(),
                "There is no subgraph.yaml here.".to_string(),
                "8453 [\"./bin/prepare.sh --network base\"]".to_string(),
                "8453 [\"./bin/prepare.sh base\"]".to_string(),
                "There is no subgraph.yaml here.".to_string(),
            )
        );
    }

    // sushiswap's v3 subgraph: `"generate": "mustache ../../config/$NETWORK.js
    // template.yaml > subgraph.yaml && mustache ../../config/$NETWORK.js
    // src/constants/index.template.ts > src/constants/index.ts && graph
    // codegen"`. The view is a JavaScript module, which the mustache CLI
    // runs; envio's own render can't, and refused ("the view … is a JavaScript
    // module"). It is the one script that writes the manifest, so it runs.
    #[test]
    fn runs_a_mustache_script_whose_view_is_a_javascript_module() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir::TempDir::new("envio-subgraph-js-view").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/base.js"),
            "module.exports = { network: 'base', gravity: { address: '0x00000000000014aA86C5d3c41765bb24e11bd701', startBlock: 1 } };\n",
        )
        .unwrap();
        // The mustache CLI the install links: it requires a .js view.
        fs::create_dir_all(root.join("node_modules/.bin")).unwrap();
        fs::write(
            root.join("node_modules/.bin/mustache"),
            "#!/usr/bin/env node\nconst fs = require('fs'), path = require('path');\nconst view = require(path.resolve(process.argv[2]));\nlet text = fs.readFileSync(process.argv[3], 'utf8');\ntext = text.replace(/\\{\\{([\\w.]+)\\}\\}/g, (_, key) => key.split('.').reduce((value, part) => value[part], view));\nprocess.stdout.write(text);\n",
        )
        .unwrap();
        fs::set_permissions(
            root.join("node_modules/.bin/mustache"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"generate": "mustache config/$NETWORK.js subgraph.template.yaml > subgraph.yaml && graph codegen"}}"#,
        )
        .unwrap();
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=base\n").unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&config),
                config.subgraph.unwrap().rendered_manifest.unwrap().commands
            ),
            (
                (
                    8453,
                    vec!["0x00000000000014aA86C5d3c41765bb24e11bd701".to_string()]
                ),
                vec![
                    "mustache config/$NETWORK.js subgraph.template.yaml > subgraph.yaml"
                        .to_string()
                ]
            )
        );
    }

    // beefy's `"postinstall": "yarn run --silent configure linea && …"`: a
    // package manager passes the words after the script's name on to it, so
    // `configure` (`./bin/prepare.sh`) runs as `./bin/prepare.sh linea`.
    // envio read `--silent` as the script's name, and dropped the arguments of
    // a script it read through.
    #[test]
    fn passes_a_script_call_s_arguments_to_the_script() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempdir::TempDir::new("envio-subgraph-writer-call-args").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(
            root.join("subgraph.template.yaml"),
            GRAVITY_MANIFEST.replace("network: mainnet", "network: NETWORK"),
        )
        .unwrap();
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::write(
            root.join("bin/prepare.sh"),
            "#!/bin/sh\n[ -n \"$1\" ] || { echo \"Usage: $0 <chain>\"; exit 1; }\nsed \"s/network: NETWORK/network: $1/\" subgraph.template.yaml > subgraph.yaml\n",
        )
        .unwrap();
        fs::set_permissions(
            root.join("bin/prepare.sh"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"configure": "./bin/prepare.sh", "prepare:base": "yarn run --silent configure base && yarn codegen", "codegen": "graph codegen"}}"#,
        )
        .unwrap();
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=base\n").unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                chain_of(&config).0,
                config.subgraph.unwrap().rendered_manifest.unwrap().commands
            ),
            (8453, vec!["./bin/prepare.sh base".to_string()])
        );
    }

    // envio runs each of a script's `&&` commands in a shell of its own, so
    // `export NETWORK=… && node build.js` and `cd subgraph && …` would lose
    // what the shell they ran in carries to the next command.
    #[test]
    fn carries_a_scripts_cd_and_export_to_its_next_commands() {
        let dir = tempdir::TempDir::new("envio-subgraph-writer-export").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(
            root.join("subgraph.template.yaml"),
            GRAVITY_MANIFEST.replace("network: mainnet", "network: NETWORK"),
        )
        .unwrap();
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/write.sh"),
            "[ -n \"$CHAIN\" ] || exit 1\nsed \"s/network: NETWORK/network: $CHAIN/\" ../subgraph.template.yaml > ../subgraph.yaml\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"build-manifest": "export CHAIN=base && cd scripts && sh write.sh"}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let config = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(chain_of(&config).0, 8453);
    }

    // A script that fails leaves no manifest behind: the shell had already
    // created the file its `>` names.
    #[test]
    fn a_writer_script_that_fails_leaves_no_manifest() {
        let dir = tempdir::TempDir::new("envio-subgraph-writer-fails").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::create_dir_all(root.join("scripts")).unwrap();
        fs::write(
            root.join("scripts/render.js"),
            "process.exit(require('fs').existsSync('subgraph.template.yaml') ? 3 : 0)\n",
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"build-manifest": "node scripts/render.js > subgraph.yaml"}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            (
                err.lines().next().unwrap_or_default().to_string(),
                root.join("subgraph.yaml").exists()
            ),
            (
                "There is no subgraph.yaml here, and the package.json script \"build-manifest\" \
                 writes it: envio ran `node scripts/render.js > subgraph.yaml` from it, and it \
                 exited with 3 — the error above is the script's own."
                    .to_string(),
                false
            )
        );
    }

    // `--config subgraph.template.yaml` names the template, not the manifest
    // (the corpus's first runs did): envio parsed it and refused
    // `startBlock: {{startBlock}}` as "has to be a number", or, where the
    // template isn't YAML until rendered, as an invalid envio config.
    #[test]
    fn renders_the_template_config_names_or_says_it_is_one() {
        let dir = tempdir::TempDir::new("envio-subgraph-template-config").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.template.yaml");
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::write(
            root.join("config/matic.json"),
            r#"{"network": "matic", "gravity": {"address": "0x00000000000014aA86C5d3c41765bb24e11bd701", "startBlock": 1}}"#,
        )
        .unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"prepare:matic": "mustache config/matic.json subgraph.template.yaml > subgraph.yaml"}}"#,
        )
        .unwrap();
        let template_config =
            ParsedProjectPaths::new(root.to_str().unwrap(), "subgraph.template.yaml").unwrap();
        let rendered = SystemConfig::parse_from_project_files(&template_config).unwrap();

        fs::write(
            root.join("package.json"),
            r#"{"scripts": {"build": "cross-env ts-node ./script/build"}}"#,
        )
        .unwrap();
        // Uniswap's build script renders the template; envio only reads it.
        fs::create_dir_all(root.join("script")).unwrap();
        fs::write(
            root.join("script/build.ts"),
            "const template = fs.readFileSync('subgraph.template.yaml')\n",
        )
        .unwrap();
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&template_config).unwrap_err()
        );

        assert_eq!(
            (
                chain_of(&rendered).0,
                err.lines().take(3).collect::<Vec<_>>()
            ),
            (
                137,
                vec![
                    "subgraph.template.yaml is a mustache template, not a manifest: graph-cli \
                     can't read it either until a script renders it.",
                    "The project writes its manifest with a package.json script, and envio \
                     can't repeat it:",
                    "  \"build\": cross-env ts-node ./script/build",
                ]
            )
        );
    }

    // Aave's protocol-subgraphs: one script per deployment binds the
    // variables (`"deploy:hosted:mainnet-v3": "VERSION=v3 BLOCKCHAIN=v3
    // NETWORK=mainnet env-cmd npm run prepare:subgraph && …"`), and
    // `prepare:subgraph` renders with them and copies the schema in
    // (`npm run generate:schema`: `cp ./schemas/${VERSION}.schema.graphql
    // schema.graphql`).
    #[test]
    fn renders_through_the_scripts_a_deployment_script_runs() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-inline").unwrap();
        let root = dir.path();
        write_gravity(root, "subgraph.yaml");
        fs::remove_file(root.join("subgraph.yaml")).unwrap();
        fs::create_dir_all(root.join("templates")).unwrap();
        fs::create_dir_all(root.join("schemas")).unwrap();
        fs::create_dir_all(root.join("config")).unwrap();
        fs::rename(
            root.join("schema.graphql"),
            root.join("schemas/v3.schema.graphql"),
        )
        .unwrap();
        fs::write(
            root.join("templates/v3.subgraph.template.yaml"),
            gravity_template(),
        )
        .unwrap();
        for (name, network, address) in [
            (
                "mainnet-v3",
                "mainnet",
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC",
            ),
            (
                "arbitrum-v3",
                "arbitrum-one",
                "0x00000000000014aA86C5d3c41765bb24e11bd701",
            ),
        ] {
            fs::write(
                root.join(format!("config/{name}.json")),
                format!(
                    r#"{{"network": "{network}", "gravity": {{"address": "{address}", "startBlock": 1}}}}"#
                ),
            )
            .unwrap();
        }
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "generate:schema": "cp ./schemas/${VERSION}.schema.graphql  schema.graphql",
  "prepare:subgraph": "mustache ./config/${NETWORK}-${VERSION}.json ./templates/${BLOCKCHAIN}.subgraph.template.yaml > subgraph.yaml && rm -rf generated && npm run generate:schema && npm run subgraph:codegen && npm run subgraph:build",
  "subgraph:codegen": "graph codegen --output-dir ./generated",
  "subgraph:build": "graph build",
  "subgraph:deploy": "graph deploy $SLUG",
  "deploy:hosted:mainnet-v3": "VERSION=v3 BLOCKCHAIN=v3 NETWORK=mainnet env-cmd npm run prepare:subgraph && SLUG=protocol-v3 env-cmd npm run subgraph:deploy",
  "deploy:hosted:arbitrum-v3": "VERSION=v3 BLOCKCHAIN=v3 NETWORK=arbitrum env-cmd npm run prepare:subgraph && SLUG=protocol-v3-arbitrum env-cmd npm run subgraph:deploy"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let unset = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );
        fs::write(root.join(".env"), "ENVIO_SUBGRAPH_NETWORK=arbitrum-v3\n").unwrap();
        let picked = SystemConfig::parse_from_project_files(&project_paths).unwrap();

        assert_eq!(
            (
                unset.contains("(mainnet-v3, arbitrum-v3)"),
                chain_of(&picked),
                root.join("schema.graphql").exists(),
            ),
            (
                true,
                (
                    42161,
                    vec!["0x00000000000014aA86C5d3c41765bb24e11bd701".to_string()]
                ),
                true,
            )
        );
    }

    // NFTX v3's public repo has `"manifest:mainnet": "cross-env mustache
    // config/mainnet/config.json subgraph.template.yaml > subgraph.yaml"`, and
    // gitignores the template: a ts-node script writes it.
    #[test]
    fn says_when_the_template_a_render_script_reads_is_not_in_the_repo() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-absent").unwrap();
        let root = dir.path();
        fs::create_dir_all(root.join("config/mainnet")).unwrap();
        fs::write(root.join("config/mainnet/config.json"), "{}").unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "manifest:mainnet": "cross-env mustache config/mainnet/config.json subgraph.template.yaml > subgraph.yaml",
  "prepare-build": "cross-env ts-node ./script/build"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err.lines().take(3).collect::<Vec<_>>(),
            vec![
                "There is no subgraph.yaml here.",
                "The project writes its manifest with a package.json script, and envio can't \
                 repeat it:",
                "  \"manifest:mainnet\": cross-env mustache config/mainnet/config.json \
                 subgraph.template.yaml > subgraph.yaml (subgraph.template.yaml isn't in the \
                 repo: another step writes it)",
            ]
        );
    }

    // gnosis' hg-subgraph renders its manifest with `node
    // ops/render-subgraph-conf.js <network>`, which reads truffle artifacts and
    // asks an RPC for start blocks: not something envio repeats, so the error
    // names the script — and not `publish-graph:gnosis`, which only runs it.
    // envio would run it as the one script that writes the manifest, but the
    // file it runs isn't there.
    #[test]
    fn names_the_render_script_envio_does_not_run() {
        let dir = tempdir::TempDir::new("envio-subgraph-render-node").unwrap();
        let root = dir.path();
        fs::write(root.join("subgraph.template.yaml"), gravity_template()).unwrap();
        fs::write(
            root.join("package.json"),
            r#"{"scripts": {
  "prepare": "husky install",
  "render-subgraph-config:gnosis": "node ops/render-subgraph-conf.js gnosis",
  "codegen": "graph codegen",
  "publish-graph:gnosis": "npm run render-subgraph-config:gnosis && graph deploy gnosis/conditional-tokens-gc"
}}"#,
        )
        .unwrap();
        let project_paths = ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
        let err = format!(
            "{:#}",
            SystemConfig::parse_from_project_files(&project_paths).unwrap_err()
        );

        assert_eq!(
            err,
            "There is no subgraph.yaml here.\n\
             The project writes its manifest with a package.json script, and envio can't \
             repeat it:\n  \"render-subgraph-config:gnosis\": node ops/render-subgraph-conf.js \
             gnosis\n\
             envio renders a manifest itself when every step of the script is a standard \
             tool over files in the repo (`mustache <config> <template> > subgraph.yaml`, \
             `yaml2json`, `cat`), so that the network you pick is its only input.\n\
             envio runs the one script that writes the manifest itself, but never one that \
             deploys, publishes or runs docker or git, nor one that reads a file the repo \
             doesn't have. Run the script for your network, then start envio again."
        );
    }
}
