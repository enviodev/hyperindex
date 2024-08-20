use super::validation;
use crate::{
    constants::links,
    utils::normalized_list::{NormalizedList, SingleOrList},
};
use anyhow::Context;
use schemars::{json_schema, JsonSchema, Schema, SchemaGenerator};
use serde::{Deserialize, Serialize};
use std::{borrow::Cow, path::PathBuf};

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
    #[serde(flatten)]
    //If this is "None" it should be expected that
    //there is a global config for the contract
    pub config: Option<T>,
}

pub mod evm {
    use super::{GlobalContract, NetworkContract, NetworkId};
    use crate::{rescript_types::RescriptTypeIdent, utils::normalized_list::SingleOrList};
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
        #[schemars(description = "Custom path to config file")]
        pub schema: Option<String>,
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
                           valid block on a reorg (default: true)"
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
            description = "An object representing additional fields to add to the event passed to \
                           handlers."
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
        #[schemars(description = "Fields of a transaction to add to the event passed to handlers")]
        pub transaction_fields: Option<Vec<TransactionField>>,
        #[schemars(description = "Fields of a block to add to the event passed to handlers")]
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
        From,
        To,
        Gas,
        GasPrice,
        MaxPriorityFeePerGas,
        MaxFeePerGas,
        CumulativeGasUsed,
        EffectiveGasPrice,
        GasUsed,
        Input,
        Nonce,
        Value,
        V,
        R,
        S,
        ContractAddress,
        LogsBloom,
        Type,
        Root,
        Status,
        YParity,
        ChainId,
        // AccessList, //TODO this should produce an array of AccessList records
        MaxFeePerBlobGas,
        BlobVersionedHashes,
        Kind,
        L1Fee,
        L1GasPrice,
        L1GasUsed,
        L1FeeScalar,
        GasUsedForL1,
        //These values are available by default on the block
        //so no need to allow users to configure these values
        // BlockHash,
        // BlockNumber,
    }

    impl From<TransactionField> for RescriptTypeIdent {
        fn from(value: TransactionField) -> Self {
            match value {
                TransactionField::TransactionIndex => Self::Int,
                TransactionField::Hash => Self::String,
                TransactionField::From => Self::Address,
                TransactionField::To => Self::Address,
                TransactionField::Gas => Self::BigInt,
                TransactionField::GasPrice => Self::BigInt,
                TransactionField::MaxPriorityFeePerGas => Self::BigInt,
                TransactionField::MaxFeePerGas => Self::BigInt,
                TransactionField::CumulativeGasUsed => Self::BigInt,
                TransactionField::EffectiveGasPrice => Self::BigInt,
                TransactionField::GasUsed => Self::BigInt,
                TransactionField::Input => Self::String,
                TransactionField::Nonce => Self::BigInt,
                TransactionField::Value => Self::BigInt,
                TransactionField::V => Self::String,
                TransactionField::R => Self::String,
                TransactionField::S => Self::String,
                TransactionField::ContractAddress => Self::Address,
                TransactionField::LogsBloom => Self::String,
                TransactionField::Type => Self::Int,
                TransactionField::Root => Self::String,
                TransactionField::Status => Self::Int,
                TransactionField::YParity => Self::String,
                TransactionField::ChainId => Self::Int,
                // TransactionField::AccessList => todo!(),
                TransactionField::MaxFeePerBlobGas => Self::BigInt,
                TransactionField::BlobVersionedHashes => Self::Array(Box::new(Self::String)),
                TransactionField::Kind => Self::Int,
                TransactionField::L1Fee => Self::BigInt,
                TransactionField::L1GasPrice => Self::BigInt,
                TransactionField::L1GasUsed => Self::BigInt,
                TransactionField::L1FeeScalar => Self::Float,
                TransactionField::GasUsedForL1 => Self::BigInt,
            }
        }
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

    impl From<BlockField> for RescriptTypeIdent {
        fn from(value: BlockField) -> RescriptTypeIdent {
            match value {
                BlockField::ParentHash => RescriptTypeIdent::String,
                BlockField::Nonce => RescriptTypeIdent::BigInt,
                BlockField::Sha3Uncles => RescriptTypeIdent::String,
                BlockField::LogsBloom => RescriptTypeIdent::String,
                BlockField::TransactionsRoot => RescriptTypeIdent::String,
                BlockField::StateRoot => RescriptTypeIdent::String,
                BlockField::ReceiptsRoot => RescriptTypeIdent::String,
                BlockField::Miner => RescriptTypeIdent::Address,
                BlockField::Difficulty => RescriptTypeIdent::BigInt,
                BlockField::TotalDifficulty => RescriptTypeIdent::BigInt,
                BlockField::ExtraData => RescriptTypeIdent::String,
                BlockField::Size => RescriptTypeIdent::BigInt,
                BlockField::GasLimit => RescriptTypeIdent::BigInt,
                BlockField::GasUsed => RescriptTypeIdent::BigInt,
                BlockField::Uncles => RescriptTypeIdent::Array(Box::new(RescriptTypeIdent::String)),
                BlockField::BaseFeePerGas => RescriptTypeIdent::BigInt,
                BlockField::BlobGasUsed => RescriptTypeIdent::BigInt,
                BlockField::ExcessBlobGas => RescriptTypeIdent::BigInt,
                BlockField::ParentBeaconBlockRoot => RescriptTypeIdent::String,
                BlockField::WithdrawalsRoot => RescriptTypeIdent::String,
                // BlockField::Withdrawals => todo!(), //should be array of withdrawal record
                BlockField::L1BlockNumber => RescriptTypeIdent::Int,
                BlockField::SendCount => RescriptTypeIdent::String,
                BlockField::SendRoot => RescriptTypeIdent::String,
                BlockField::MixHash => RescriptTypeIdent::String,
            }
        }
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
        #[serde(alias = "endpoint_url")]
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
    #[serde(deny_unknown_fields)]
    pub struct Network {
        #[schemars(description = "Public chain/network id")]
        pub id: NetworkId,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(
            description = "RPC Config that will be used to subscribe to blockchain data on this \
                           network (TIP: This is optional and in most cases does not need to be \
                           specified if the network is supported with HyperSync. We recommend \
                           using HyperSync instead of RPC for 100x speed-up)"
        )]
        pub rpc_config: Option<RpcConfig>,
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
        pub start_block: i32,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The block at which the indexer should terminate.")]
        pub end_block: Option<i32>,
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
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    pub struct EventConfig {
        #[schemars(description = "The human readable signature of an event 'eg. \
                                  Transfer(address indexed from, address indexed to, uint256 \
                                  value)' OR a reference to the name of an event in a json ABI \
                                  file defined in your contract config. A provided signature \
                                  will take precedence over what is defined in the json ABI")]
        pub event: String,
    }

    impl EventConfig {
        pub fn event_string_from_abi_event(abi_event: &ethers::abi::Event) -> String {
            format!(
                "{}({}){}",
                abi_event.name,
                abi_event
                    .inputs
                    .iter()
                    .map(|input| {
                        let param_type = input.kind.to_string();
                        let indexed_keyword = if input.indexed { " indexed " } else { " " };
                        let param_name = input.name.clone();

                        format!("{}{}{}", param_type, indexed_keyword, param_name)
                    })
                    .collect::<Vec<_>>()
                    .join(", "),
                if abi_event.anonymous {
                    " anonymous"
                } else {
                    ""
                },
            )
        }
    }
}

pub mod fuel {
    use std::fmt::Display;

    use super::{GlobalContract, NetworkContract, NetworkId};
    use schemars::JsonSchema;
    use serde::{Deserialize, Serialize};

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
        #[schemars(description = "Custom path to config file")]
        pub schema: Option<String>,
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
    pub struct Network {
        #[schemars(description = "Public chain/network id")]
        pub id: NetworkId,
        #[schemars(description = "The block at which the indexer should start ingesting data")]
        pub start_block: i32,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "The block at which the indexer should terminate.")]
        pub end_block: Option<i32>,
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

    #[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    pub struct EventConfig {
        #[schemars(
            description = "A reference to a struct in the ABI or a unique name for the provided \
                           log_id"
        )]
        pub name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        #[schemars(description = "A reference to a log_id in the ABI")]
        pub log_id: Option<String>,
    }
}

fn strip_to_letters(string: &str) -> String {
    let mut pg_friendly_name = String::new();
    for c in string.chars() {
        if c.is_alphabetic() {
            pg_friendly_name.push(c);
        }
    }
    pg_friendly_name
}

pub fn deserialize_config_from_yaml(config_path: &PathBuf) -> anyhow::Result<evm::HumanConfig> {
    let config = std::fs::read_to_string(config_path).context(format!(
        "EE104: Failed to resolve config path {0}. Make sure you're in the correct directory and \
         that a config file with the name {0} exists",
        &config_path
            .to_str()
            .unwrap_or("unknown config file name path"),
    ))?;

    let mut deserialized_yaml: evm::HumanConfig =
        serde_yaml::from_str(&config).context(format!(
            "EE105: Failed to deserialize config. Visit the docs for more information {}",
            links::DOC_CONFIGURATION_FILE
        ))?;

    deserialized_yaml.name = strip_to_letters(&deserialized_yaml.name);

    // Validating the config file
    validation::validate_deserialized_config_yaml(config_path, &deserialized_yaml)?;

    Ok(deserialized_yaml)
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
    fn valid_name_conversion() {
        let name_with_space = super::strip_to_letters("My too lit to quit indexer");
        let expected_name_with_space = "Mytoolittoquitindexer";
        let name_with_special_chars = super::strip_to_letters("Myto@littoq$itindexer");
        let expected_name_with_special_chars = "Mytolittoqitindexer";
        let name_with_numbers = super::strip_to_letters("yes0123456789okay");
        let expected_name_with_numbers = "yesokay";
        assert_eq!(name_with_space, expected_name_with_space);
        assert_eq!(name_with_special_chars, expected_name_with_special_chars);
        assert_eq!(name_with_numbers, expected_name_with_numbers);
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
            ecosystem: fuel::EcosystemTag::Fuel,
            contracts: None,
            networks: vec![fuel::Network {
                id: 0,
                start_block: 0,
                end_block: None,
                contracts: vec![NetworkContract {
                    name: "OrderBook".to_string(),
                    address: "0x4a2ce054e3e94155f7092f7365b212f7f45105b74819c623744ebcc5d065c6ac"
                        .to_string()
                        .into(),
                    config: Some(fuel::ContractConfig {
                        abi_file_path: "./abis/spark-orderbook.json".to_string(),
                        handler: "./src/OrderBookHandlers.ts".to_string(),
                        events: vec![
                            fuel::EventConfig {
                                name: "OrderChangeEvent".to_string(),
                                log_id: None.into(),
                            },
                            fuel::EventConfig {
                                name: "MarketCreateEvent".to_string(),
                                log_id: None.into(),
                            },
                            fuel::EventConfig {
                                name: "TradeEvent".to_string(),
                                log_id: None.into(),
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
            ecosystem: fuel::EcosystemTag::Fuel,
            contracts: None,
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
                start_block: 2_000,
                confirmed_block_threshold: None,
                end_block: Some(2_000_000),
                contracts: vec![]
            },
            de
        );
    }
}
