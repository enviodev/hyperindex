//! Subgraph mode: run an unmodified subgraph project on HyperIndex.
//!
//! The CLI detects `subgraph.yaml`, translates the manifest into an envio
//! config and the schema into an envio schema, and points the handler entry at
//! the subgraph runtime that ships inside the `envio` package.

pub mod abi;
pub mod assemblyscript;
pub mod codegen;
pub mod creates;
pub mod errors;
pub mod manifest;
pub mod schema;
pub mod usage;

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
    let mut message = format!(
        "These ABI files the manifest names don't exist under {}:\n{}\n\
         The manifest's paths are resolved against its own directory, as graph-cli \
         resolves them. If a build step writes them (forge build, a git submodule, a copy \
         script), run it first.",
        root.canonicalize()
            .unwrap_or_else(|_| root.to_path_buf())
            .display(),
        lines.join("\n")
    );
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
        let found = std::fs::read_dir(dir).ok().and_then(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.file_name().to_string_lossy().to_string())
                .find(|entry| entry.to_lowercase() == name && !wanted.ends_with(entry))
        });
        if let Some(found) = found {
            let hint = format!("\n{path} differs only in case from {found}, which does exist.");
            if !message.contains(&hint) {
                message.push_str(&hint);
            }
        }
    }
    Some(message)
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
            let is_yaml = name.ends_with(".yaml") || name.ends_with(".yml");
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

/// `envio codegen` and `envio start` build the generated code when it is
/// missing and graph-cli can't (Envio Cloud's builder has none, and leaves the
/// directory behind empty). `ENVIO_SUBGRAPH_CODEGEN=bundled` always writes it;
/// `graph-cli` is the one mode with nothing to fall back to, so it refuses.
pub fn check_generated_code(
    runtime: &SubgraphRuntimeConfig,
    manifest_file: &std::path::Path,
) -> Result<()> {
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
    let mode = codegen::CodegenMode::from_env();
    // Every generated tree has a schema.ts.
    let missing = !generated.join("schema.ts").is_file();
    if mode == codegen::CodegenMode::Bundled
        || (mode == codegen::CodegenMode::Auto && missing && !graph_cli_installed(root))
    {
        codegen::generate(manifest_file, &generated)?;
        return Ok(());
    }
    if !missing || graph_cli_installed(root) || mode != codegen::CodegenMode::GraphCli {
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

    // Held back until the manifest and schema have been checked too, so a
    // mistyped endpoint doesn't hide what else this subgraph needs changed.
    let (rpc, rpc_error) = match rpc_env.map(parse_rpc_env) {
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
        contracts.push(GlobalContract {
            name: contract_name(source),
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
        let config = contract_config(source, files, &usage, &mut report);
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
        assert_eq!(
            (with(&own).is_ok(), with(&"0x".repeat(1)).is_ok()),
            (true, false)
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

    // CryptoPunks names `./abis/WrappedPunks.json` and commits
    // `abis/wrappedpunks.json`; envio said only `Virtual config file
    // "./abis/WrappedPunks.json" was not provided`.
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
                 ./abis/Gravity.json differs only in case from gravity.json, which does exist.",
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
}
