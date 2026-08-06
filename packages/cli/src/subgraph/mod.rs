//! Subgraph mode: run an unmodified subgraph project on HyperIndex.
//!
//! The CLI detects `subgraph.yaml`, translates the manifest into an envio
//! config and the schema into an envio schema, and points the handler entry at
//! the subgraph runtime that ships inside the `envio` package.

pub mod errors;
pub mod manifest;
pub mod schema;

use std::collections::BTreeMap;

use anyhow::{anyhow, Result};
use serde::Serialize;

use crate::config_parsing::human_config::{
    evm::{
        AddressFormat, BlockField, Chain, ContractConfig, EventConfig, FieldSelection, HumanConfig,
        Rpc, RpcSelection, TransactionField,
    },
    BaseConfig, ChainContract, GlobalContract,
};
use crate::utils::normalized_list::NormalizedList;

use errors::Report;
use manifest::{DataSource, Manifest};
use schema::SchemaTranslation;

/// The env var carrying an RPC endpoint. subgraph.yaml has no place for
/// provider config — graph-node keeps it in its own config, not the project.
pub const RPC_ENV_VAR: &str = "ENVIO_SUBGRAPH_RPC";
pub const API_TOKEN_ENV_VAR: &str = "ENVIO_API_TOKEN";

/// The receipt scalars graph-ts exposes on `event.receipt`. All but
/// `contractAddress` are HyperSync-only fields.
const RECEIPT_TRANSACTION_FIELDS: &[TransactionField] = &[
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
    /// `ENVIO_SUBGRAPH_RPC` flattened to plain URLs, in order. The shim's call
    /// effects use them as a viem fallback transport; empty means the mapping's
    /// first contract call raises the missing-RPC error.
    pub rpc_urls: Vec<String>,
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
        serde_json::from_str::<RpcSelection>(trimmed).map_err(|err| {
            anyhow!(
                "Invalid {RPC_ENV_VAR}: {err}. It takes an RPC URL, or JSON matching envio's rpc \
                 config (a single entry or an array)."
            )
        })
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

pub fn missing_graph_cli_message() -> String {
    "Envio Subgraph needs the project's generated code, but \"generated/\" is\n\
     missing and @graphprotocol/graph-cli isn't installed.\n\
     Install dependencies and try again:\n  \
     pnpm install\n\
     Or generate manually:\n  \
     pnpm exec graph codegen"
        .to_string()
}

pub fn graph_codegen_failed_message() -> String {
    "Envio Subgraph ran `graph codegen` to build \"generated/\", but it failed —\n\
     the error above comes from The Graph's own codegen, so fix it there and\n\
     rerun. If `graph codegen` succeeds on its own but fails through envio,\n\
     please open an issue: https://github.com/enviodev/hyperindex/issues"
        .to_string()
}

fn field_selection_for(receipt: bool) -> FieldSelection {
    let mut transaction_fields = DEFAULT_TRANSACTION_FIELDS.to_vec();
    if receipt {
        for field in RECEIPT_TRANSACTION_FIELDS {
            if !transaction_fields.contains(field) {
                transaction_fields.push(field.clone());
            }
        }
    }
    FieldSelection {
        transaction_fields: Some(transaction_fields),
        block_fields: Some(DEFAULT_BLOCK_FIELDS.to_vec()),
    }
}

fn contract_config(source: &DataSource, report: &mut Report) -> ContractConfig {
    let events = source
        .event_handlers
        .iter()
        .filter(|handler| !handler.name.is_empty())
        .map(|handler| {
            if !handler.topics.is_empty() {
                // Dynamic-typed indexed params appear in topics as keccak
                // hashes, which can't be decoded back to the values envio
                // filters on. Reporting the whole filter is the honest
                // conservative move until the ABI says otherwise.
                report.unsupported(
                    "topic filters on dynamically-typed indexed parameters",
                    format!(
                        "data source \"{}\" → eventHandlers → \"{}\" → topic filters",
                        source.name, handler.handler
                    ),
                );
            }
            EventConfig {
                event: handler.name.clone(),
                name: None,
                field_selection: Some(field_selection_for(handler.receipt)),
            }
        })
        .collect();

    ContractConfig {
        abi_file_path: source
            .abi
            .as_ref()
            .and_then(|abi| source.abis.get(abi))
            .cloned(),
        // Every mapping is loaded by the subgraph runtime, not by envio's
        // per-contract handler resolution.
        handler: None,
        events,
    }
}

/// Builds the envio config a translated manifest indexes with.
pub fn translate(
    manifest_yaml: &str,
    schema_text: &str,
    project_name: &str,
    rpc_env: Option<&str>,
    root: &str,
) -> Result<Translation> {
    let mut report = Report::new();

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

    for source in manifest.data_sources.iter() {
        contracts.push(GlobalContract {
            name: source.name.clone(),
            config: contract_config(source, &mut report),
        });

        let Some(chain_id) = source.chain_id else {
            continue;
        };
        let start_block = source.start_block.unwrap_or(0);
        let chain = chains.entry(chain_id).or_insert_with(|| Chain {
            id: chain_id,
            skip: None,
            rpc: rpc.clone(),
            hypersync_config: None,
            max_reorg_depth: None,
            block_lag: None,
            start_block,
            end_block: None,
            contracts: Some(vec![]),
        });
        chain.start_block = chain.start_block.min(start_block);
        chain.end_block = match (chain.end_block, source.end_block) {
            // A chain stops only once every data source on it has.
            (Some(current), Some(next)) => Some(current.max(next)),
            _ => None,
        };
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
    for source in manifest.templates.iter() {
        contracts.push(GlobalContract {
            name: source.name.clone(),
            config: contract_config(source, &mut report),
        });
        let ids = match source.chain_id {
            Some(id) => vec![id],
            None => template_chain_ids.clone(),
        };
        for chain_id in ids {
            if let Some(chain) = chains.get_mut(&chain_id) {
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
    }

    report.into_result()?;

    if chains.is_empty() {
        return Err(anyhow!(
            "subgraph.yaml declares no indexable data source. Add at least one `dataSources` \
             entry with a `network` and a contract address."
        ));
    }

    let human_config = HumanConfig {
        base: BaseConfig {
            name: project_name.to_string(),
            description: None,
            schema: None,
            handlers: None,
            full_batch_size: None,
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
    };

    Ok(Translation {
        schema_text: schema.text.clone(),
        runtime: SubgraphRuntimeConfig {
            manifest,
            schema,
            root: root.to_string(),
            rpc_urls,
        },
        human_config,
    })
}

/// Only used to keep `Rpc` in scope for callers building an rpc selection.
pub type SubgraphRpc = Rpc;

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn builds_an_evm_config_from_a_manifest() {
        let translation = translate(MANIFEST, SCHEMA, "gravatar", None, ".").unwrap();
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
                6175244,
                2,
                vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()],
                "Wallet",
                Vec::<String>::new(),
            )
        );
    }

    #[test]
    fn selects_receipt_fields_only_where_declared() {
        let translation = translate(MANIFEST, SCHEMA, "gravatar", None, ".").unwrap();
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

    #[test]
    fn injects_the_rpc_env_var_into_every_chain() {
        let translation = translate(
            MANIFEST,
            SCHEMA,
            "gravatar",
            Some(r#"{"url":"https://rpc.example.test","for":"fallback"}"#),
            ".",
        )
        .unwrap();
        assert_eq!(
            translation.human_config.chains[0].rpc.clone(),
            Some(RpcSelection::Single(Rpc {
                url: "https://rpc.example.test".to_string(),
                source_for: Some(crate::config_parsing::human_config::evm::For::Fallback),
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
            "interface Named { id: ID! }\ntype Gravatar @entity { id: ID! }",
            "gravatar",
            None,
            ".",
        )
        .unwrap_err()
        .to_string();

        assert_eq!(
            (
                error.contains("doesn't support call handlers"),
                error.contains("doesn't support GraphQL interfaces"),
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
        fs::write(root.join("src/gravity.ts"), "export function handleNewGravatar() {}").unwrap();
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

        let project_paths =
            ParsedProjectPaths::new(root.to_str().unwrap(), "config.yaml").unwrap();
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
}
