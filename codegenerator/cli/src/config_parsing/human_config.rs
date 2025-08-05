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

    fn always_inline_schema() -> bool {
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

type NetworkId = u64;

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
pub struct NetworkContract<T> {
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
        description = "The block at which the indexer should start ingesting data for this specific contract. \
                       If not specified, uses the network start_block. Can be greater than the network start_block for more specific indexing."
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

#[derive(Debug)]
pub enum HumanConfig {
    Evm(evm::HumanConfig),
    Fuel(fuel::HumanConfig),
}

impl Display for HumanConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                HumanConfig::Evm(config) => config.to_string(),
                HumanConfig::Fuel(config) => config.to_string(),
            }
        )
    }
}

pub mod evm {
    use super::{GlobalContract, NetworkContract, NetworkId};
    use crate::utils::normalized_list::SingleOrList;
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
        #[schemars(description = "Name of the project")]
        pub name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Description of the project")]
        pub description: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Ecosystem of the project.")]
        pub ecosystem: Option<EcosystemTag>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Custom path to schema.graphql file")]
        pub schema: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Path where the generated directory will be placed. By default it's \
                           'generated' relative to the current working directory. If set, it'll \
                           be a path relative to the config file location."
        )]
        pub output: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Global contract definitions that must contain all definitions except \
                           addresses. You can share a single handler/abi/event definitions for \
                           contracts across multiple chains."
        )]
        pub contracts: Option<Vec<GlobalContract<ContractConfig>>>,
        #[schemars(
            description = "Configuration of the blockchain networks that the project is deployed \
                           on."
        )]
        pub networks: Vec<Network>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "A flag to indicate if the indexer should use a single queue for all \
                           chains or a queue per chain (default: false)"
        )]
        pub unordered_multichain_mode: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The event decoder to use for the indexer (default: hypersync-client)"
        )]
        pub event_decoder: Option<EventDecoder>,
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
    #[derive(Debug, Serialize, Deserialize, PartialEq, Eq, Hash, Clone, Display, JsonSchema)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
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
        ChainId,
        AccessList,
        MaxFeePerBlobGas,
        BlobVersionedHashes,
        Kind,
        L1Fee,
        L1GasPrice,
        L1GasUsed,
        L1FeeScalar,
        GasUsedForL1,
        AuthorizationList,
        //These values are available by default on the block
        //so no need to allow users to configure these values
        // BlockHash,
        // BlockNumber,
    }

    #[subenum(RpcBlockField)]
    #[derive(Debug, Serialize, Deserialize, PartialEq, Eq, Hash, Clone, Display, JsonSchema)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
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

    #[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
    #[serde(rename_all = "kebab-case", deny_unknown_fields)]
    pub enum EventDecoder {
        Viem,
        HypersyncClient,
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

    #[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct RpcSyncConfig {
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
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct RpcConfig {
        #[schemars(
            description = "URL of the RPC endpoint. Can be a single URL or an array of URLs. If \
                           multiple URLs are provided, the first one will be used as the primary \
                           RPC endpoint and the rest will be used as fallbacks."
        )]
        pub url: SingleOrList<String>,
        #[serde(flatten, skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Config options for RPC syncing")]
        pub sync_config: Option<RpcSyncConfig>,
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
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Rpc {
        #[schemars(description = "The RPC endpoint URL.")]
        pub url: String,
        #[schemars(
            description = "Determines if this RPC is for historical sync, real-time chain \
                           indexing, or as a fallback."
        )]
        #[serde(rename = "for")]
        pub source_for: For,
        #[serde(flatten, skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Options for RPC data-source indexing.")]
        pub sync_config: Option<RpcSyncConfig>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(untagged)]
    pub enum NetworkRpc {
        Url(String),
        Single(Rpc),
        List(Vec<Rpc>),
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct Network {
        #[schemars(description = "The public blockchain network ID.")]
        pub id: NetworkId,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "RPC configuration for utilizing as the network's data-source. \
                           Typically optional for chains with HyperSync support, which is highly \
                           recommended. HyperSync dramatically enhances performance, providing up \
                           to a 1000x speed boost over traditional RPC."
        )]
        pub rpc_config: Option<RpcConfig>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "RPC configuration for your indexer. If not specified \
                                  otherwise, for networks supported by HyperSync, RPC serves as \
                                  a fallback for added reliability. For others, it acts as the \
                                  primary data-source. HyperSync offers significant performance \
                                  improvements, up to a 1000x faster than traditional RPC.")]
        pub rpc: Option<NetworkRpc>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Optional HyperSync Config for additional fine-tuning")]
        pub hypersync_config: Option<HypersyncConfig>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "The number of blocks from the head that the indexer should account for \
                           in case of reorgs."
        )]
        pub confirmed_block_threshold: Option<i32>,
        #[schemars(description = "The block at which the indexer should start ingesting data")]
        pub start_block: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The block at which the indexer should terminate.")]
        pub end_block: Option<u64>,
        #[schemars(description = "All the contracts that should be indexed on the given network")]
        pub contracts: Vec<NetworkContract<ContractConfig>>,
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
        #[schemars(
            description = "The relative path to a file where handlers are registered for the \
                           given contract"
        )]
        pub handler: String,
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

    use super::{GlobalContract, NetworkContract, NetworkId};
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
        #[schemars(description = "Name of the project")]
        pub name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Description of the project")]
        pub description: Option<String>,
        #[schemars(description = "Ecosystem of the project.")]
        pub ecosystem: EcosystemTag,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Custom path to schema.graphql file")]
        pub schema: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Path where the generated directory will be placed. By default it's \
                           'generated' relative to the current working directory. If set, it'll \
                           be a path relative to the config file location."
        )]
        pub output: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "Global contract definitions that must contain all definitions except \
                           addresses. You can share a single handler/abi/event definitions for \
                           contracts across multiple chains."
        )]
        pub contracts: Option<Vec<GlobalContract<ContractConfig>>>,
        #[schemars(
            description = "Configuration of the blockchain networks that the project is deployed \
                           on."
        )]
        pub networks: Vec<Network>,
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
    pub struct Network {
        #[schemars(description = "Public chain/network id")]
        pub id: NetworkId,
        #[schemars(description = "The block at which the indexer should start ingesting data")]
        pub start_block: u64,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The block at which the indexer should terminate.")]
        pub end_block: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "Optional HyperFuel Config for additional fine-tuning")]
        pub hyperfuel_config: Option<HyperfuelConfig>,
        #[schemars(description = "All the contracts that should be indexed on the given network")]
        pub contracts: Vec<NetworkContract<ContractConfig>>,
    }

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(deny_unknown_fields)]
    pub struct ContractConfig {
        #[schemars(description = "Relative path (from config) to a json abi.")]
        pub abi_file_path: String,
        #[schemars(
            description = "The relative path to a file where handlers are registered for the \
                           given contract"
        )]
        pub handler: String,
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

#[cfg(test)]
mod tests {
    use super::{
        evm::{ContractConfig, EventDecoder, HumanConfig, Network},
        NetworkContract,
    };
    use crate::{config_parsing::human_config::fuel, utils::normalized_list::NormalizedList};
    use pretty_assertions::assert_eq;
    use schemars::{schema_for, Schema};
    use serde_json::json;
    use std::path::PathBuf;

    #[test]
    fn test_evm_config_schema() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("npm/envio/evm.schema.json");
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
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("npm/envio/fuel.schema.json");
        let npm_schema: Schema =
            serde_json::from_str(&std::fs::read_to_string(config_path).unwrap()).unwrap();

        let actual_schema = schema_for!(fuel::HumanConfig);

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

        let deserialized: NetworkContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContract {
            name: "Contract1".to_string(),
            address: NormalizedList::from(vec![
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()
            ]),
            start_block: None,
            config: Some(ContractConfig {
                abi_file_path: None,
                handler: "./src/EventHandler.js".to_string(),
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

        let deserialized: NetworkContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContract {
            name: "Contract1".to_string(),
            address: vec![].into(),
            start_block: None,
            config: Some(ContractConfig {
                abi_file_path: None,
                handler: "./src/EventHandler.js".to_string(),
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

        let deserialized: NetworkContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContract {
            name: "Contract1".to_string(),
            address: vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()].into(),
            start_block: None,
            config: Some(ContractConfig {
                abi_file_path: None,
                handler: "./src/EventHandler.js".to_string(),
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

        let deserialized: NetworkContract<ContractConfig> = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContract {
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
    fn deserializes_factory_contract_config() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/factory-contract-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        println!("{:?}", cfg.networks[0].contracts[0]);

        assert!(cfg.networks[0].contracts[0].config.is_some());
        assert!(cfg.networks[0].contracts[1].config.is_some());
        assert_eq!(cfg.networks[0].contracts[1].address, None.into());
    }

    #[test]
    fn deserializes_dynamic_contract_config() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/dynamic-address-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        assert!(cfg.networks[0].contracts[0].config.is_some());
        assert!(cfg.networks[1].contracts[0].config.is_none());
    }

    #[test]
    fn deserializes_fuel_config() {
        let config_path =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("test/configs/fuel-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: fuel::HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        let expected_cfg = fuel::HumanConfig {
            name: "Fuel indexer".to_string(),
            description: None,
            schema: None,
            output: None,
            ecosystem: fuel::EcosystemTag::Fuel,
            contracts: None,
            raw_events: None,
            networks: vec![fuel::Network {
                id: 0,
                start_block: 0,
                end_block: None,
                hyperfuel_config: None,
                contracts: vec![NetworkContract {
                    name: "Greeter".to_string(),
                    address: "0x4a2ce054e3e94155f7092f7365b212f7f45105b74819c623744ebcc5d065c6ac"
                        .to_string()
                        .into(),
                    start_block: None,
                    config: Some(fuel::ContractConfig {
                        abi_file_path: "../abis/greeter-abi.json".to_string(),
                        handler: "./src/EventHandlers.js".to_string(),
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
                }],
            }],
        };

        // deserializes fuel config
        assert_eq!(cfg, expected_cfg);
    }

    #[test]
    fn serializes_fuel_config() {
        let cfg = fuel::HumanConfig {
            name: "Fuel indexer".to_string(),
            description: None,
            schema: None,
            output: None,
            ecosystem: fuel::EcosystemTag::Fuel,
            contracts: None,
            raw_events: None,
            networks: vec![],
        };

        assert_eq!(
            serde_yaml::to_string(&cfg).unwrap(),
            "name: Fuel indexer\necosystem: fuel\nnetworks: []\n"
        );
    }

    #[test]
    fn deserializes_event_decoder() {
        assert_eq!(
            serde_json::from_value::<EventDecoder>(json!("viem")).unwrap(),
            EventDecoder::Viem
        );
        assert_eq!(
            serde_json::from_value::<EventDecoder>(json!("hypersync-client")).unwrap(),
            EventDecoder::HypersyncClient
        );
        assert_eq!(
            serde_json::to_value(&EventDecoder::HypersyncClient).unwrap(),
            json!("hypersync-client")
        );
        assert_eq!(
            serde_json::to_value(&EventDecoder::Viem).unwrap(),
            json!("viem")
        );
    }

    #[test]
    fn deserialize_underscores_between_numbers() {
        let num = serde_json::json!(2_000_000);
        let de: i32 = serde_json::from_value(num).unwrap();
        assert_eq!(2_000_000, de);
    }

    #[test]
    fn deserialize_network_with_underscores_between_numbers() {
        let network_json = serde_json::json!({"id": 1, "start_block": 2_000, "end_block": 2_000_000, "contracts": []});
        let de: Network = serde_json::from_value(network_json).unwrap();

        assert_eq!(
            Network {
                id: 1,
                hypersync_config: None,
                rpc_config: None,
                rpc: None,
                start_block: 2_000,
                confirmed_block_threshold: None,
                end_block: Some(2_000_000),
                contracts: vec![]
            },
            de
        );
    }
}
