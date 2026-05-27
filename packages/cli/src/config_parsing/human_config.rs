use crate::utils::normalized_list::{NormalizedList, SingleOrList};
use schemars::{json_schema, JsonSchema, Schema, SchemaGenerator};
use serde::{Deserialize, Serialize};
use std::{borrow::Cow, fmt::Display};

impl<T: Clone + JsonSchema> JsonSchema for SingleOrList<T> {
    fn schema_name() -> Cow<'static, str> {
        "SingleOrList".into()
    }

    fn json_schema(gen: &mut SchemaGenerator) -> Schema {
        let t_schema = T::json_schema(gen);
        json_schema!({
          "anyOf": [
            t_schema,
            {
              "type": "array",
              "items": t_schema
            }
          ]
        })
    }

    fn inline_schema() -> bool {
        true
    }
}

pub type Addresses = NormalizedList<String>;

impl JsonSchema for Addresses {
    fn schema_name() -> Cow<'static, str> {
        "Addresses".into()
    }

    fn json_schema(gen: &mut SchemaGenerator) -> Schema {
        let t_schema = json_schema!({
          "anyOf": [
            String::json_schema(gen),
            usize::json_schema(gen),
          ]
        });
        json_schema!({
          "anyOf": [
            t_schema,
            {
              "type": "array",
              "items": t_schema
            }
          ]
        })
    }

    fn _schemars_private_is_option() -> bool {
        true
    }
}

type ChainId = u64;

/// Base configuration fields shared across all ecosystems
#[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
pub struct BaseConfig {
    #[schemars(description = "Name of the project")]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Description of the project")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Custom path to schema.graphql file")]
    pub schema: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Optional relative path to handlers directory for auto-loading. Defaults \
                   to 'src/handlers' if not specified."
    )]
    pub handlers: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Target number of events to be processed per batch. Set it to smaller number if you have many Effect API calls which are slow to resolve and can't be batched. (Default: 5000)"
    )]
    pub full_batch_size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "Configuration for the storage backends the indexer writes to. Defaults to \
                       `postgres: true` when omitted. ClickHouse requires Postgres to be enabled \
                       (it is not supported as a single storage yet), and at least one backend \
                       must be enabled."
    )]
    pub storage: Option<StorageConfig>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
#[serde(deny_unknown_fields)]
pub struct StorageConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub postgres: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub clickhouse: Option<bool>,
}

// Hand-rolled JsonSchema so the generated YAML/JSON schema encodes the same
// constraints Storage::resolve enforces at codegen time: ClickHouse requires
// Postgres, and at least one backend must be enabled. Without this, an IDE
// validating against the schema would accept configs the CLI later rejects.
impl JsonSchema for StorageConfig {
    fn schema_name() -> Cow<'static, str> {
        "StorageConfig".into()
    }

    fn json_schema(_gen: &mut SchemaGenerator) -> Schema {
        json_schema!({
            "type": "object",
            "properties": {
                "postgres": {
                    "description": "Whether to use Postgres as a storage backend (default: true).",
                    "type": ["boolean", "null"]
                },
                "clickhouse": {
                    "description": "Whether to additionally sync the indexed data to ClickHouse. \
                                    Requires Postgres to be enabled (default: false).",
                    "type": ["boolean", "null"]
                }
            },
            "additionalProperties": false,
            // Storage::resolve rejects two shapes:
            //   1. `postgres: false` (with any clickhouse value) — either
            //      fails as "ClickHouse not supported as a single storage
            //      yet" or resolves to all-backends-disabled.
            //   2. `clickhouse: true` without an explicit `postgres: true` —
            //      the user must opt in to Postgres alongside ClickHouse.
            "allOf": [
                {
                    "not": {
                        "properties": {
                            "postgres": { "const": false }
                        },
                        "required": ["postgres"]
                    }
                },
                {
                    "if": {
                        "properties": {
                            "clickhouse": { "const": true }
                        },
                        "required": ["clickhouse"]
                    },
                    "then": {
                        "properties": {
                            "postgres": { "const": true }
                        },
                        "required": ["postgres"]
                    }
                }
            ]
        })
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct GlobalContract<T> {
    #[schemars(description = "A unique project-wide name for this contract (no spaces)")]
    pub name: String,
    #[serde(flatten)]
    pub config: T,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ChainContract<T> {
    #[schemars(
        description = "A unique project-wide name for this contract if events and handler are \
                       defined OR a reference to the name of contract defined globally at the top \
                       level"
    )]
    pub name: String,
    #[schemars(
        description = "A single address or a list of addresses to be indexed. This can be left as \
                       null in the case where this contracts addresses will be registered \
                       dynamically."
    )]
    pub address: Addresses,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(
        description = "The block at which the indexer should start ingesting data for this \
                       specific contract. If not specified, uses the chain start_block. Can be \
                       greater than the chain start_block for more specific indexing."
    )]
    pub start_block: Option<u64>,
    #[serde(flatten)]
    //If this is "None" it should be expected that
    //there is a global config for the contract
    pub config: Option<T>,
}

#[derive(Deserialize)]
pub struct ConfigDiscriminant {
    pub ecosystem: Option<String>,
}

/// `serde_yaml::to_string` emits hex strings unquoted. yaml-language-server
/// and Prettier then resolve the unquoted scalar as a YAML 1.1 hex integer
/// and round-trip through f64 on save — silently truncating the address.
/// Subsequent runs query HyperSync for a contract that doesn't exist and
/// every event is dropped.
///
/// Must only run on the init write path — `Display` feeds the persisted
/// `config_hash` and quoting there would force a spurious re-migration
/// on every existing user.
pub fn quote_known_addresses(yaml: String, addresses: impl IntoIterator<Item = String>) -> String {
    let mut unique: Vec<String> = addresses.into_iter().collect();
    unique.sort();
    unique.dedup();

    let mut out = yaml;
    for addr in &unique {
        out = replace_address_at_scalar_boundary(&out, addr);
    }
    out
}

fn replace_address_at_scalar_boundary(yaml: &str, addr: &str) -> String {
    let bytes = yaml.as_bytes();
    let quoted = format!("\"{addr}\"");
    let mut result = String::with_capacity(yaml.len());
    let mut last = 0;
    while let Some(rel) = yaml[last..].find(addr) {
        let start = last + rel;
        let end = start + addr.len();
        let before_ok = start == 0 || matches!(bytes[start - 1], b' ' | b'\t');
        let after_ok =
            end == bytes.len() || matches!(bytes[end], b'\n' | b'\r' | b' ' | b'\t' | b'#');
        if before_ok && after_ok {
            result.push_str(&yaml[last..start]);
            result.push_str(&quoted);
        } else {
            result.push_str(&yaml[last..end]);
        }
        last = end;
    }
    result.push_str(&yaml[last..]);
    result
}

#[derive(Debug)]
pub enum HumanConfig {
    Evm(evm::HumanConfig),
    Fuel(fuel::HumanConfig),
    Svm(svm::HumanConfig),
}

impl HumanConfig {
    pub fn get_base_config(&self) -> &BaseConfig {
        match &self {
            HumanConfig::Evm(human_config) => &human_config.base,
            HumanConfig::Fuel(human_config) => &human_config.base,
            HumanConfig::Svm(human_config) => &human_config.base,
        }
    }
}

impl Display for HumanConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                HumanConfig::Evm(config) => config.to_string(),
                HumanConfig::Fuel(config) => config.to_string(),
                HumanConfig::Svm(config) => config.to_string(),
            }
        )
    }
}

pub mod evm {
    use super::{ChainContract, ChainId, GlobalContract};
    use crate::config_parsing::human_config::BaseConfig;
    use schemars::JsonSchema;
    use serde::{Deserialize, Serialize};
    use std::fmt::Display;
    use strum::Display;
    use subenum::subenum;

    #[derive(Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
    #[schemars(
        title = "Envio Config Schema",
        description = "Schema for a YAML config for an envio indexer"
    )]
    #[serde(deny_unknown_fields)]
    pub struct HumanConfig {
        #[serde(flatten)]
        pub base: BaseConfig,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Ecosystem of the project.")]
        pub ecosystem: Option<EcosystemTag>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Global contract definitions that must contain all definitions except \
                           addresses. You can share a single handler/abi/event definitions for \
                           contracts across multiple chains."
        )]
        pub contracts: Option<Vec<GlobalContract<ContractConfig>>>,
        #[schemars(
            description = "Configuration of the blockchain chains that the project is deployed on."
        )]
        pub chains: Vec<Chain>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "A flag to indicate if the indexer should rollback to the last known \
                           valid block on a reorg. This currently incurs a performance hit on \
                           historical sync and is recommended to turn this off while developing \
                           (default: true)"
        )]
        pub rollback_on_reorg: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "A flag to indicate if the indexer should save the full history of \
                           events. This is useful for debugging but will increase the size of the \
                           database (default: false)"
        )]
        pub save_full_history: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Select the block and transaction fields to include in all events \
                           globally"
        )]
        pub field_selection: Option<FieldSelection>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "If true, the indexer will store the raw event data in the database. \
                           This is useful for debugging, but will increase the size of the \
                           database and the amount of time it takes to process events (default: \
                           false)"
        )]
        pub raw_events: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Address format for Ethereum addresses: 'checksum' or \
                                  'lowercase' (default: checksum)")]
        pub address_format: Option<AddressFormat>,
    }

    #[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
    #[serde(rename_all = "lowercase")]
    pub enum AddressFormat {
        Checksum,
        Lowercase,
    }

    impl Display for HumanConfig {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(
                f,
                "# yaml-language-server: $schema=./node_modules/envio/evm.schema.json\n{}",
                serde_yaml::to_string(self).expect("Failed to serialize config")
            )
        }
    }

    #[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct FieldSelection {
        #[schemars(
            description = "The transaction fields to include in the event, or in all events if \
                           applied globally"
        )]
        pub transaction_fields: Option<Vec<TransactionField>>,
        #[schemars(
            description = "The block fields to include in the event, or in all events if applied \
                           globally"
        )]
        pub block_fields: Option<Vec<BlockField>>,
    }

    #[subenum(RpcTransactionField)]
    #[derive(
        Debug,
        Serialize,
        Deserialize,
        PartialEq,
        Eq,
        Hash,
        Clone,
        Display,
        JsonSchema,
        strum::EnumIter,
    )]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    #[strum(serialize_all = "camelCase")]
    pub enum TransactionField {
        #[subenum(RpcTransactionField)]
        TransactionIndex,
        #[subenum(RpcTransactionField)]
        Hash,
        #[subenum(RpcTransactionField)]
        From,
        #[subenum(RpcTransactionField)]
        To,
        Gas,
        #[subenum(RpcTransactionField)]
        GasPrice,
        #[subenum(RpcTransactionField)]
        MaxPriorityFeePerGas,
        #[subenum(RpcTransactionField)]
        MaxFeePerGas,
        CumulativeGasUsed,
        EffectiveGasPrice,
        GasUsed,
        #[subenum(RpcTransactionField)]
        Input,
        Nonce,
        #[subenum(RpcTransactionField)]
        Value,
        V,
        R,
        S,
        #[subenum(RpcTransactionField)]
        ContractAddress,
        LogsBloom,
        Root,
        Status,
        YParity,
        AccessList,
        MaxFeePerBlobGas,
        BlobVersionedHashes,
        Type,
        L1Fee,
        L1GasPrice,
        L1GasUsed,
        L1FeeScalar,
        GasUsedForL1,
        AuthorizationList,
        // We want to encourage the use of context.chain.id instead
        // ChainId,
        //These values are available by default on the block
        //so no need to allow users to configure these values
        // BlockHash,
        // BlockNumber,
    }

    #[subenum(RpcBlockField)]
    #[derive(
        Debug,
        Serialize,
        Deserialize,
        PartialEq,
        Eq,
        Hash,
        Clone,
        Display,
        JsonSchema,
        strum::EnumIter,
    )]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    #[strum(serialize_all = "camelCase")]
    pub enum BlockField {
        #[subenum(RpcBlockField)]
        ParentHash,
        #[subenum(RpcBlockField)]
        Nonce,
        Sha3Uncles,
        LogsBloom,
        TransactionsRoot,
        #[subenum(RpcBlockField)]
        StateRoot,
        ReceiptsRoot,
        #[subenum(RpcBlockField)]
        Miner,
        #[subenum(RpcBlockField)]
        Difficulty,
        TotalDifficulty,
        #[subenum(RpcBlockField)]
        ExtraData,
        Size,
        #[subenum(RpcBlockField)]
        GasLimit,
        #[subenum(RpcBlockField)]
        GasUsed,
        Uncles,
        #[subenum(RpcBlockField)]
        BaseFeePerGas,
        BlobGasUsed,
        ExcessBlobGas,
        ParentBeaconBlockRoot,
        WithdrawalsRoot,
        // Withdrawals, //TODO: allow this field to be selectable (contains an array of rescript record type)
        L1BlockNumber,
        SendCount,
        SendRoot,
        MixHash,
    }

    // Workaround for https://github.com/serde-rs/serde/issues/2231
    #[derive(Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
    #[serde(rename_all = "lowercase", deny_unknown_fields)]
    pub enum EcosystemTag {
        Evm,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct HypersyncConfig {
        #[serde(alias = "endpoint_url")] // TODO: Remove the alias in v3
        #[schemars(
            description = "URL of the HyperSync endpoint (default: The most performant HyperSync \
                           endpoint for the network)"
        )]
        pub url: String,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(rename_all = "lowercase")]
    pub enum For {
        #[schemars(
            description = "Use RPC as the main data-source for both historical sync and real-time \
                           chain indexing."
        )]
        Sync,
        #[schemars(
            description = "Use RPC as a backup for the main data-source. Currently, it acts as a \
                           fallback when real-time indexing stalls, with potential for more cases \
                           in the future."
        )]
        Fallback,
        #[schemars(
            description = "Use RPC for real-time indexing only. HyperSync will be used for \
                           historical sync, then automatically switch to this RPC once synced \
                           for lower latency."
        )]
        Realtime,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Rpc {
        #[schemars(description = "The RPC endpoint URL.")]
        pub url: String,
        #[schemars(
            description = "Determines if this RPC is for historical sync, real-time chain \
                           indexing, or as a fallback. If not specified, defaults to \"fallback\" \
                           when HyperSync is available for the chain, or \"sync\" otherwise."
        )]
        #[serde(rename = "for", skip_serializing_if = "Option::is_none")]
        pub source_for: Option<For>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional WebSocket endpoint URL (wss:// or ws://) for real-time block \
                           header notifications via eth_subscribe(\"newHeads\"). Provides lower \
                           latency than HTTP polling for detecting new blocks."
        )]
        pub ws: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The starting interval in range of blocks per query")]
        pub initial_block_interval: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "After an RPC error, how much to scale back the number of blocks \
                           requested at once"
        )]
        pub backoff_multiplicative: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Without RPC errors or timeouts, how much to increase the number of \
                           blocks requested by for the next batch"
        )]
        pub acceleration_additive: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Do not further increase the block interval past this limit")]
        pub interval_ceiling: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "After an error, how long to wait before retrying")]
        pub backoff_millis: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "If a fallback RPC is provided, the amount of time in ms to wait before \
                           kicking off the next provider"
        )]
        pub fallback_stall_timeout: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "How long to wait before cancelling an RPC request")]
        pub query_timeout_millis: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "How frequently (in milliseconds) to check for new blocks in realtime. \
                           Default is 1000ms. Note: Setting this higher than block time does not \
                           reduce RPC usage as every block is still fetched to check for reorgs."
        )]
        pub polling_interval: Option<u32>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(untagged)]
    pub enum RpcSelection {
        Url(String),
        Single(Rpc),
        List(Vec<Rpc>),
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Chain {
        #[schemars(description = "The public blockchain chain ID.")]
        pub id: ChainId,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Excludes the chain from indexing and migrations. \
                           Code generation is unaffected. \
                           For testing, prefer using a test framework instead.")]
        pub skip: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "RPC configuration for your indexer. If not specified \
                                  otherwise, for chains supported by HyperSync, RPC serves as \
                                  a fallback for added reliability. For others, it acts as the \
                                  primary data-source. HyperSync offers significant performance \
                                  improvements, up to a 1000x faster than traditional RPC.")]
        pub rpc: Option<RpcSelection>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Optional HyperSync Config for additional fine-tuning")]
        pub hypersync_config: Option<HypersyncConfig>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The number of blocks from the head that the indexer should account for \
                           in case of reorgs."
        )]
        pub max_reorg_depth: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The number of blocks behind the chain head that the indexer should lag. \
                           Useful for avoiding reorg issues by indexing slightly behind the tip."
        )]
        pub block_lag: Option<u32>,
        #[schemars(description = "The block at which the indexer should start ingesting data")]
        pub start_block: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The block at which the indexer should terminate.")]
        pub end_block: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "All the contracts that should be indexed on the given chain")]
        pub contracts: Option<Vec<ChainContract<ContractConfig>>>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct ContractConfig {
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Relative path (from config) to a json abi. If this is used then each \
                           configured event should simply be referenced by its name"
        )]
        pub abi_file_path: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional relative path to a file where handlers are registered for the \
                           given contract. If not provided, handlers can be auto-loaded from src \
                           directory."
        )]
        pub handler: Option<String>,
        #[schemars(description = "A list of events that should be indexed on this contract")]
        pub events: Vec<EventConfig>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct EventConfig {
        #[schemars(description = "The human readable signature of an event 'eg. \
                                  Transfer(address indexed from, address indexed to, uint256 \
                                  value)' OR a reference to the name of an event in a json ABI \
                                  file defined in your contract config. A provided signature \
                                  will take precedence over what is defined in the json ABI")]
        pub event: String,
        #[schemars(
            description = "Name of the event in the HyperIndex generated code. When ommitted, the \
                           event field will be used. Should be unique per contract"
        )]
        #[serde(skip_serializing_if = "Option::is_none")]
        pub name: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Select the block and transaction fields to include in the specific \
                           event"
        )]
        pub field_selection: Option<FieldSelection>,
    }
}

pub mod fuel {
    use std::fmt::Display;

    use crate::config_parsing::human_config::BaseConfig;

    use super::{ChainContract, ChainId, GlobalContract};
    use schemars::JsonSchema;
    use serde::{Deserialize, Serialize};
    use strum::Display;

    #[derive(Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
    #[schemars(
        title = "Envio Config Schema",
        description = "Schema for a YAML config for an envio indexer"
    )]
    #[serde(deny_unknown_fields)]
    pub struct HumanConfig {
        #[serde(flatten)]
        pub base: BaseConfig,
        #[schemars(description = "Ecosystem of the project.")]
        pub ecosystem: EcosystemTag,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Global contract definitions that must contain all definitions except \
                           addresses. You can share a single handler/abi/event definitions for \
                           contracts across multiple chains."
        )]
        pub contracts: Option<Vec<GlobalContract<ContractConfig>>>,
        #[schemars(
            description = "Configuration of the blockchain chains that the project is deployed on."
        )]
        pub chains: Vec<Chain>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "If true, the indexer will store the raw event data in the database. \
                           This is useful for debugging, but will increase the size of the \
                           database and the amount of time it takes to process events (default: \
                           false)"
        )]
        pub raw_events: Option<bool>,
    }

    impl Display for HumanConfig {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(
                f,
                "# yaml-language-server: $schema=./node_modules/envio/fuel.schema.json\n{}",
                serde_yaml::to_string(self).expect("Failed to serialize config")
            )
        }
    }

    // Workaround for https://github.com/serde-rs/serde/issues/2231
    #[derive(Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
    #[serde(rename_all = "lowercase", deny_unknown_fields)]
    pub enum EcosystemTag {
        Fuel,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct HyperfuelConfig {
        #[schemars(
            description = "URL of the HyperFuel endpoint (default: The most stable HyperFuel \
                           endpoint for the network)"
        )]
        pub url: String,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Chain {
        #[schemars(description = "Public chain id")]
        pub id: ChainId,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Excludes the chain from indexing and migrations. \
                           Code generation is unaffected. \
                           For testing, prefer using a test framework instead.")]
        pub skip: Option<bool>,
        #[schemars(description = "The block at which the indexer should start ingesting data")]
        pub start_block: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The block at which the indexer should terminate.")]
        pub end_block: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Optional HyperFuel Config for additional fine-tuning")]
        pub hyperfuel_config: Option<HyperfuelConfig>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The number of blocks from the head that the indexer should account for \
                           in case of reorgs."
        )]
        pub max_reorg_depth: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The number of blocks behind the chain head that the indexer should lag. \
                           Useful for avoiding reorg issues by indexing slightly behind the tip."
        )]
        pub block_lag: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "All the contracts that should be indexed on the given chain")]
        pub contracts: Option<Vec<ChainContract<ContractConfig>>>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct ContractConfig {
        #[schemars(description = "Relative path (from config) to a json abi.")]
        pub abi_file_path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional relative path to a file where handlers are registered for the \
                           given contract. If not provided, handlers can be auto-loaded from src \
                           directory."
        )]
        pub handler: Option<String>,
        #[schemars(description = "A list of events that should be indexed on this contract")]
        pub events: Vec<EventConfig>,
    }

    #[derive(Debug, Serialize, Clone, Deserialize, PartialEq, JsonSchema, Display)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    pub enum EventType {
        LogData,
        Mint,
        Burn,
        Transfer,
        Call,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    pub struct EventConfig {
        #[schemars(description = "Name of the event in the HyperIndex generated code")]
        pub name: String,
        #[serde(rename = "type")]
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Explicitly set the event type you want to index. It's derived from the \
                           event name and fallbacks to LogData."
        )]
        pub type_: Option<EventType>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "An identifier of a logged type from ABI. Used for indexing LogData \
                           receipts. The option can be omitted when the event name matches the \
                           logged struct/enum name."
        )]
        pub log_id: Option<String>,
    }
}

pub mod svm {
    use std::fmt::Display;

    use super::BaseConfig;
    use schemars::JsonSchema;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct HypersyncConfig {
        #[schemars(
            description = "URL of the HyperSync endpoint (default: the public Solana HyperSync \
                           endpoint at https://solana.hypersync.xyz)"
        )]
        pub url: String,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Chain {
        // #[schemars(
        //     description = "The cluster's genesis hash used to identify the Svm blockchain."
        // )]
        // pub id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Excludes the chain from indexing and migrations. \
                           Code generation is unaffected. \
                           For testing, prefer using a test framework instead.")]
        pub skip: Option<bool>,
        #[schemars(
            description = "RPC endpoint URL for connecting to the Svm cluster to fetch blockchain data."
        )]
        pub rpc: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional HyperSync Config for fetching historical instructions."
        )]
        pub hypersync_config: Option<HypersyncConfig>,
        #[schemars(
            description = "The slot number at which the indexer should start ingesting data"
        )]
        pub start_block: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The slot number at which the indexer should terminate.")]
        pub end_block: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The number of blocks behind the chain head that the indexer should lag. \
                           Useful for avoiding reorg issues by indexing slightly behind the tip."
        )]
        pub block_lag: Option<u32>,
        #[serde(
            rename = "programs_experimental",
            skip_serializing_if = "Option::is_none"
        )]
        #[schemars(description = "Solana programs to index on this chain.")]
        pub programs: Option<Vec<Program>>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Program {
        #[schemars(
            description = "A unique project-wide name for this program (used in generated code)."
        )]
        pub name: String,
        #[schemars(description = "Base58-encoded program id (32 bytes).")]
        pub program_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional relative path to a file where handlers are registered for \
                           the given program. If not provided, handlers can be auto-loaded from \
                           the src directory."
        )]
        pub handler: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional path (relative to config.yaml) to an Anchor IDL JSON \
                           file. When present, codegen parses the IDL and derives \
                           `accounts`/`args` for every named instruction. Mutually \
                           exclusive with per-instruction `accounts`/`args` overrides."
        )]
        pub idl: Option<String>,
        #[schemars(description = "A list of instructions that should be indexed on this program.")]
        pub instructions: Vec<Instruction>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Instruction {
        #[schemars(
            description = "Name of the instruction in the HyperIndex generated code. Should be \
                           unique per program."
        )]
        pub name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Hex-encoded instruction-data prefix used as the discriminator \
                           (\"0x\" optional). Must be 1, 2, 4, or 8 bytes after decoding. \
                           An 8-byte value matches the standard Anchor discriminator."
        )]
        pub discriminator: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Filter on inner-vs-outer instructions. None / absent matches both."
        )]
        pub is_inner: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional positional account filters. Two shapes are accepted: a flat \
                           list of `{position, values}` entries (AND across positions, OR within \
                           `values`); or `{any_of: [[...]] }`, a list of AND-groups that are \
                           OR-ed together. Positions must be in 0..=5; positions 6..=9 are \
                           reserved for a future extension."
        )]
        pub account_filters: Option<AccountFilters>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Select which additional data to fetch for each matched instruction. \
                           Each key accepts `true` (include all fields) or a list of field \
                           names (per-field selection, not yet supported). When absent, only \
                           the instruction itself is included."
        )]
        pub field_selection: Option<SvmFieldSelection>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional positional account names. The Nth entry names \
                           account slot N on the dispatched instruction; surfaces as \
                           `event.instruction.decoded.accounts.<name>`. Accounts beyond \
                           the named list become `extra_accounts`."
        )]
        pub accounts: Option<Vec<String>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Optional Borsh argument schema. Each entry names one arg and \
                           gives its type; the decoder walks the instruction data after \
                           the discriminator in declared order. Mutually exclusive with \
                           the program-level `idl` field."
        )]
        pub args: Option<Vec<ArgDef>>,
    }

    /// One named argument of an instruction. Mirrors
    /// `hypersync_client_solana::decode::NamedField`.
    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct ArgDef {
        #[schemars(description = "Field name as it appears on the decoded args object.")]
        pub name: String,
        #[serde(rename = "type")]
        #[schemars(description = "Borsh type of this field.")]
        pub ty: ArgType,
    }

    /// User-facing Borsh type grammar. Mirrors
    /// `hypersync_client_solana::decode::FieldType`. The YAML accepts either:
    /// - A bare string for primitives (`"u64"`, `"pubkey"`, `"bool"`, ...).
    /// - A tagged object for composites (`{ vec: u8 }`, `{ option: pubkey }`,
    ///   `{ array: [u8, 32] }`, `{ defined: "DataV2" }`).
    /// - An object with `kind: struct` or `kind: enum` for nominal types
    ///   declared inline on this field. Most users will use `defined` and
    ///   declare the nominal types under the program's `types:` block (Anchor
    ///   IDL shape) once that lands; for now inline `struct` / `enum` is the
    ///   only way to express nominal shapes ad-hoc.
    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(untagged)]
    pub enum ArgType {
        Primitive(ArgPrimitive),
        Composite(ArgComposite),
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(rename_all = "lowercase")]
    pub enum ArgPrimitive {
        Bool,
        U8,
        U16,
        U32,
        U64,
        U128,
        I8,
        I16,
        I32,
        I64,
        I128,
        F32,
        F64,
        String,
        Bytes,
        Pubkey,
        #[serde(rename = "publicKey")]
        PublicKey,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub enum ArgComposite {
        #[serde(rename = "option")]
        Option(Box<ArgType>),
        #[serde(rename = "vec")]
        Vec(Box<ArgType>),
        /// `[ <element type>, <length> ]` — same shape Anchor IDLs use.
        #[serde(rename = "array")]
        Array(Box<ArgType>, usize),
        /// Reference to a nominal type defined in the program-level
        /// `defined_types` registry (populated from an Anchor IDL `types:`
        /// block or the bundled-Metaplex registry).
        #[serde(rename = "defined")]
        Defined(String),
        /// Inline-or-registry struct. Used as a nominal type definition in
        /// the `defined_types` registry; rarely seen at the field level.
        #[serde(rename = "struct")]
        Struct(Vec<ArgDef>),
        /// Inline-or-registry enum. Same role as `Struct`: a nominal type
        /// definition in the `defined_types` registry.
        #[serde(rename = "enum")]
        Enum(Vec<ArgEnumVariant>),
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct ArgEnumVariant {
        pub name: String,
        /// `None` for unit variants; `Some([])` for struct variants with no
        /// fields. The Borsh wire format is identical in both cases (the
        /// 1-byte tag), but the distinction is preserved for round-tripping.
        #[serde(skip_serializing_if = "Option::is_none")]
        pub fields: Option<Vec<ArgDef>>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct AccountFilter {
        #[schemars(description = "Account position within the instruction (0..=5).")]
        pub position: u8,
        #[schemars(description = "Allowed base58 pubkeys for this account position.")]
        pub values: Vec<String>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct AnyOfAccountFilters {
        #[schemars(
            description = "A non-empty list of AND-groups. Each group is itself a non-empty list \
                           of `{position, values}` entries that must all match the same \
                           instruction. An instruction matches `any_of` when any one group \
                           matches."
        )]
        pub any_of: Vec<Vec<AccountFilter>>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(untagged)]
    pub enum AccountFilters {
        Flat(Vec<AccountFilter>),
        AnyOf(AnyOfAccountFilters),
    }

    impl AccountFilters {
        pub fn groups(&self) -> Vec<&[AccountFilter]> {
            match self {
                AccountFilters::Flat(entries) => vec![entries.as_slice()],
                AccountFilters::AnyOf(any_of) => {
                    any_of.any_of.iter().map(|g| g.as_slice()).collect()
                }
            }
        }
    }

    /// Value for a field-selection entry. `true` includes all fields;
    /// a list of field names enables per-field selection (not yet supported).
    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(untagged)]
    pub enum FieldSelectionValue {
        All(bool),
        Fields(Vec<String>),
    }

    impl FieldSelectionValue {
        pub fn is_enabled(&self) -> bool {
            match self {
                FieldSelectionValue::All(b) => *b,
                FieldSelectionValue::Fields(f) => !f.is_empty(),
            }
        }

        pub fn is_per_field(&self) -> bool {
            matches!(self, FieldSelectionValue::Fields(_))
        }
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct SvmFieldSelection {
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Include the parent transaction for each matched instruction. \
                           Use `true` to include all fields."
        )]
        pub transaction_fields: Option<FieldSelectionValue>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Include program logs scoped to each matched instruction. \
                           Use `true` to include all fields."
        )]
        pub log_fields: Option<FieldSelectionValue>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Include SPL Token / Token-2022 balance snapshots for the \
                           parent transaction. Implies transaction_fields: true. \
                           Use `true` to include all fields."
        )]
        pub token_balance_fields: Option<FieldSelectionValue>,
    }

    #[derive(Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
    #[schemars(
        title = "Envio Svm Config Schema",
        description = "Schema for a YAML config for an envio Svm indexer"
    )]
    #[serde(deny_unknown_fields)]
    pub struct HumanConfig {
        #[serde(flatten)]
        pub base: BaseConfig,
        #[schemars(description = "Ecosystem of the project.")]
        pub ecosystem: EcosystemTag,
        #[schemars(
            description = "Configuration of the blockchain chains that the project is deployed on."
        )]
        pub chains: Vec<Chain>,
    }

    impl Display for HumanConfig {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(
                f,
                "# yaml-language-server: $schema=./node_modules/envio/svm.schema.json\n{}",
                serde_yaml::to_string(self).expect("Failed to serialize config")
            )
        }
    }

    // Workaround for https://github.com/serde-rs/serde/issues/2231
    #[derive(Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
    #[serde(rename_all = "lowercase", deny_unknown_fields)]
    pub enum EcosystemTag {
        Svm,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        evm::{Chain, ContractConfig, HumanConfig},
        ChainContract,
    };
    use crate::{
        config_parsing::human_config::{fuel, BaseConfig},
        utils::normalized_list::NormalizedList,
    };
    use pretty_assertions::assert_eq;
    use schemars::{schema_for, Schema};
    use std::path::PathBuf;

    #[test]
    fn test_evm_config_schema() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../envio/evm.schema.json");
        let npm_schema: Schema =
            serde_json::from_str(&std::fs::read_to_string(config_path).unwrap()).unwrap();

        let actual_schema = schema_for!(HumanConfig);

        assert_eq!(
            npm_schema, actual_schema,
            "Please run 'make update-generated-docs'"
        );
    }

    #[test]
    fn test_fuel_config_schema() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../envio/fuel.schema.json");
        let npm_schema: Schema =
            serde_json::from_str(&std::fs::read_to_string(config_path).unwrap()).unwrap();

        let actual_schema = schema_for!(fuel::HumanConfig);

        assert_eq!(
            npm_schema, actual_schema,
            "Please run 'make update-generated-docs'"
        );
    }

    #[test]
    fn test_svm_config_schema() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../envio/svm.schema.json");
        let npm_schema: Schema =
            serde_json::from_str(&std::fs::read_to_string(config_path).unwrap()).unwrap();

        let actual_schema = schema_for!(super::svm::HumanConfig);

        assert_eq!(
            npm_schema, actual_schema,
            "Please run 'make update-generated-docs'"
        );
    }

    #[test]
    fn test_flatten_deserialize_local_contract() {
        let yaml = r#"
name: Contract1
handler: ./src/EventHandler.js
address: ["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"]
events: []
    "#;

        let deserialized: ChainContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = ChainContract {
            name: "Contract1".to_string(),
            address: NormalizedList::from(vec![
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()
            ]),
            start_block: None,
            config: Some(ContractConfig {
                abi_file_path: None,
                handler: Some("./src/EventHandler.js".to_string()),
                events: vec![],
            }),
        };

        assert_eq!(expected, deserialized);
    }

    #[test]
    fn test_flatten_deserialize_local_contract_with_no_address() {
        let yaml = r#"
name: Contract1
handler: ./src/EventHandler.js
events: []
    "#;

        let deserialized: ChainContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = ChainContract {
            name: "Contract1".to_string(),
            address: vec![].into(),
            start_block: None,
            config: Some(ContractConfig {
                abi_file_path: None,
                handler: Some("./src/EventHandler.js".to_string()),
                events: vec![],
            }),
        };

        assert_eq!(expected, deserialized);
    }

    #[test]
    fn test_flatten_deserialize_local_contract_with_single_address() {
        let yaml = r#"
name: Contract1
handler: ./src/EventHandler.js
address: "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"
events: []
    "#;

        let deserialized: ChainContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = ChainContract {
            name: "Contract1".to_string(),
            address: vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()].into(),
            start_block: None,
            config: Some(ContractConfig {
                abi_file_path: None,
                handler: Some("./src/EventHandler.js".to_string()),
                events: vec![],
            }),
        };

        assert_eq!(expected, deserialized);
    }

    #[test]
    fn test_flatten_deserialize_global_contract() {
        let yaml = r#"
name: Contract1
address: ["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"]
    "#;

        let deserialized: ChainContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = ChainContract {
            name: "Contract1".to_string(),
            address: NormalizedList::from(vec![
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()
            ]),
            start_block: None,
            config: None,
        };

        assert_eq!(expected, deserialized);
    }

    #[test]
    fn deserialize_address() {
        let no_address = r#"null"#;
        let deserialized: NormalizedList<String> = serde_json::from_str(no_address).unwrap();
        assert_eq!(deserialized, NormalizedList::from(vec![]));

        let single_address = r#""0x123""#;
        let deserialized: NormalizedList<String> = serde_json::from_str(single_address).unwrap();
        assert_eq!(
            deserialized,
            NormalizedList::from(vec!["0x123".to_string()])
        );

        let multi_address = r#"["0x123", "0x456"]"#;
        let deserialized: NormalizedList<String> = serde_json::from_str(multi_address).unwrap();
        assert_eq!(
            deserialized,
            NormalizedList::from(vec!["0x123".to_string(), "0x456".to_string()])
        );
    }

    #[test]
    fn quote_known_addresses_quotes_each_occurrence() {
        let a = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string();
        let b = "0x4537e328Bf7e4eFA29D05CAeA260D7fE26af9D74".to_string();
        let yaml = format!("address:\n- {a}\nsingle: {b}\n");
        let out = super::quote_known_addresses(yaml, [a.clone(), b.clone()]);
        assert_eq!(out, format!("address:\n- \"{a}\"\nsingle: \"{b}\"\n"));
    }

    #[test]
    fn quote_known_addresses_dedups_repeats() {
        let a = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string();
        let yaml = format!("address: {a}\n");
        let out = super::quote_known_addresses(yaml, [a.clone(), a.clone()]);
        assert_eq!(out, format!("address: \"{a}\"\n"));
    }

    #[test]
    fn quote_known_addresses_is_idempotent() {
        let a = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string();
        let yaml = format!("address: {a}\n");
        let once = super::quote_known_addresses(yaml, [a.clone()]);
        let twice = super::quote_known_addresses(once.clone(), [a.clone()]);
        assert_eq!(once, twice);
    }

    #[test]
    fn quote_known_addresses_skips_substring_matches() {
        let a = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string();
        let yaml = format!("description: see {a}-deployed\naddress: {a}\n");
        let out = super::quote_known_addresses(yaml, [a.clone()]);
        assert_eq!(
            out,
            format!("description: see {a}-deployed\naddress: \"{a}\"\n")
        );
    }

    // Display feeds PersistedState::config_hash; any drift from raw
    // serde_yaml output flips the hash for every existing user on
    // upgrade and triggers a spurious re-migration.
    #[test]
    fn evm_human_config_display_does_not_alter_serde_yaml_output() {
        let yaml = "name: t\nschema: ./s.graphql\ncontracts:\n  - name: C\n    handler: ./h.js\n    events:\n      - event: E\nchains:\n  - id: 1\n    rpc:\n      url: https://x\n    start_block: 0\n    contracts:\n      - name: C\n        address: \"0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984\"\n";
        let cfg: super::evm::HumanConfig = serde_yaml::from_str(yaml).unwrap();
        let out = cfg.to_string();
        let raw = serde_yaml::to_string(&cfg).unwrap();
        let expected =
            format!("# yaml-language-server: $schema=./node_modules/envio/evm.schema.json\n{raw}");
        assert_eq!(
            out, expected,
            "Display output must remain byte-identical for config_hash stability — header and body both."
        );
    }

    // libyaml tags unquoted `0x…` as int. A 20-byte address overflows u64
    // but serde_yaml hands the raw scalar text to the String visitor
    // unchanged — locking that contract guards against a future YAML
    // library that would coerce through f64 instead.
    #[test]
    fn deserialize_unquoted_hex_address_yaml() {
        let single = "address: 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984\n";
        #[derive(serde::Deserialize)]
        struct Wrap {
            address: NormalizedList<String>,
        }
        let de: Wrap = serde_yaml::from_str(single).unwrap();
        assert_eq!(
            Vec::<String>::from(de.address),
            vec!["0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string()]
        );

        let list = "address:\n  - 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984\n  - 0x4537e328Bf7e4eFA29D05CAeA260D7fE26af9D74\n";
        let de: Wrap = serde_yaml::from_str(list).unwrap();
        assert_eq!(
            Vec::<String>::from(de.address),
            vec![
                "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string(),
                "0x4537e328Bf7e4eFA29D05CAeA260D7fE26af9D74".to_string(),
            ]
        );
    }

    #[test]
    fn deserializes_factory_contract_config() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/factory-contract-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        let contracts = cfg.chains[0].contracts.as_ref().unwrap();
        println!("{:?}", contracts[0]);

        assert!(contracts[0].config.is_some());
        assert!(contracts[1].config.is_some());
        assert_eq!(contracts[1].address, None.into());
    }

    #[test]
    fn deserializes_dynamic_contract_config() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/dynamic-address-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        assert!(cfg.chains[0].contracts.as_ref().unwrap()[0]
            .config
            .is_some());
        assert!(cfg.chains[1].contracts.as_ref().unwrap()[0]
            .config
            .is_none());
    }

    #[test]
    fn deserializes_fuel_config() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test/configs/fuel-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: fuel::HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        let expected_cfg = fuel::HumanConfig {
            base: BaseConfig {
                name: "Fuel indexer".to_string(),
                description: None,
                schema: None,
                handlers: None,
                full_batch_size: None,
                storage: None,
            },
            ecosystem: fuel::EcosystemTag::Fuel,
            contracts: None,
            raw_events: None,
            chains: vec![fuel::Chain {
                id: 0,
                skip: None,
                start_block: 0,
                end_block: None,
                hyperfuel_config: None,
                max_reorg_depth: None,
                block_lag: None,
                contracts: Some(vec![ChainContract {
                    name: "Greeter".to_string(),
                    address: "0x4a2ce054e3e94155f7092f7365b212f7f45105b74819c623744ebcc5d065c6ac"
                        .to_string()
                        .into(),
                    start_block: None,
                    config: Some(fuel::ContractConfig {
                        abi_file_path: "../abis/greeter-abi.json".to_string(),
                        handler: Some("./src/EventHandlers.js".to_string()),
                        events: vec![
                            fuel::EventConfig {
                                name: "NewGreeting".to_string(),
                                log_id: None,
                                type_: None,
                            },
                            fuel::EventConfig {
                                name: "ClearGreeting".to_string(),
                                log_id: None,
                                type_: None,
                            },
                        ],
                    }),
                }]),
            }],
        };

        // deserializes fuel config
        assert_eq!(cfg, expected_cfg);
    }

    #[test]
    fn serializes_fuel_config() {
        let cfg = fuel::HumanConfig {
            base: BaseConfig {
                name: "Fuel indexer".to_string(),
                description: None,
                schema: None,
                handlers: None,
                full_batch_size: None,
                storage: None,
            },
            ecosystem: fuel::EcosystemTag::Fuel,
            contracts: None,
            raw_events: None,
            chains: vec![],
        };

        assert_eq!(
            serde_yaml::to_string(&cfg).unwrap(),
            "name: Fuel indexer\necosystem: fuel\nchains: []\n"
        );
    }

    #[test]
    fn deserialize_storage_config() {
        use super::StorageConfig;

        // Both fields present
        let yaml = "postgres: true\nclickhouse: true\n";
        let de: StorageConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(
            de,
            StorageConfig {
                postgres: Some(true),
                clickhouse: Some(true),
            }
        );

        // Only clickhouse set
        let yaml = "clickhouse: true\n";
        let de: StorageConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(
            de,
            StorageConfig {
                postgres: None,
                clickhouse: Some(true),
            }
        );

        // Unknown field should fail (deny_unknown_fields)
        let yaml = "postgres: true\nbigquery: true\n";
        let err = serde_yaml::from_str::<StorageConfig>(yaml).unwrap_err();
        assert!(
            err.to_string().contains("unknown field `bigquery`"),
            "Unexpected error: {err}"
        );
    }

    #[test]
    fn deserialize_evm_config_with_storage() {
        use super::evm::HumanConfig as EvmConfig;
        let yaml = r#"
name: storage-test
storage:
  postgres: true
  clickhouse: true
chains:
  - id: 1
    start_block: 0
"#;
        let cfg: EvmConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(
            cfg.base.storage,
            Some(super::StorageConfig {
                postgres: Some(true),
                clickhouse: Some(true),
            })
        );
    }

    #[test]
    fn deserialize_underscores_between_numbers() {
        let num = serde_json::json!(2_000_000);
        let de: i32 = serde_json::from_value(num).unwrap();
        assert_eq!(2_000_000, de);
    }

    #[test]
    fn deserialize_chain_with_underscores_between_numbers() {
        let chain_json = serde_json::json!({"id": 1, "start_block": 2_000, "end_block": 2_000_000, "contracts": []});
        let de: Chain = serde_json::from_value(chain_json).unwrap();

        assert_eq!(
            Chain {
                id: 1,
                skip: None,
                hypersync_config: None,
                rpc: None,
                start_block: 2_000,
                max_reorg_depth: None,
                block_lag: None,
                end_block: Some(2_000_000),
                contracts: Some(vec![])
            },
            de
        );
    }

    mod svm_yaml {
        use crate::config_parsing::human_config::svm::*;
        use pretty_assertions::assert_eq;

        const METAPLEX_YAML: &str = r#"
name: metaplex-token-metadata
ecosystem: svm
chains:
  - rpc: https://api.mainnet-beta.solana.com
    hypersync_config:
      url: https://solana.hypersync.xyz
    start_block: 200000000
    programs_experimental:
      - name: TokenMetadata
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        instructions:
          - name: CreateMetadataAccountV3
            discriminator: "0x21"
          - name: UpdateMetadataAccountV2
            discriminator: "0x0f"
            account_filters:
              - position: 0
                values: ["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"]
            field_selection:
              transaction_fields: true
"#;

        #[test]
        fn deserialize_metaplex_yaml() {
            let cfg: HumanConfig = serde_yaml::from_str(METAPLEX_YAML).unwrap();
            assert_eq!(cfg.chains.len(), 1);
            let chain = &cfg.chains[0];
            assert_eq!(
                chain.hypersync_config.as_ref().map(|h| h.url.as_str()),
                Some("https://solana.hypersync.xyz")
            );
            let programs = chain.programs.as_ref().unwrap();
            assert_eq!(programs.len(), 1);
            let program = &programs[0];
            assert_eq!(
                program,
                &Program {
                    name: "TokenMetadata".to_string(),
                    program_id: "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s".to_string(),
                    handler: None,
                    idl: None,
                    instructions: vec![
                        Instruction {
                            name: "CreateMetadataAccountV3".to_string(),
                            discriminator: Some("0x21".to_string()),
                            is_inner: None,
                            account_filters: None,
                            field_selection: None,
                            accounts: None,
                            args: None,
                        },
                        Instruction {
                            name: "UpdateMetadataAccountV2".to_string(),
                            discriminator: Some("0x0f".to_string()),
                            is_inner: None,
                            account_filters: Some(AccountFilters::Flat(vec![AccountFilter {
                                position: 0,
                                values: vec![
                                    "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s".to_string(),
                                ],
                            }])),
                            field_selection: Some(SvmFieldSelection {
                                transaction_fields: Some(FieldSelectionValue::All(true)),
                                log_fields: None,
                                token_balance_fields: None,
                            }),
                            accounts: None,
                            args: None,
                        },
                    ],
                }
            );
        }

        #[test]
        fn rejects_unknown_fields() {
            let bad = r#"
name: x
ecosystem: svm
chains:
  - rpc: r
    start_block: 1
    programs_experimental:
      - name: P
        program_id: metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s
        bogus_extra: true
        instructions: []
"#;
            assert!(serde_yaml::from_str::<HumanConfig>(bad).is_err());
        }
    }
}
