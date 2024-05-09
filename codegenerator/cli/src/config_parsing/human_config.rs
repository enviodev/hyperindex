use super::{hypersync_endpoints, validation};
use crate::{
    constants::links,
    project_paths::{path_utils, ParsedProjectPaths},
    utils::normalized_list::NormalizedList,
};
use anyhow::Context;
use schemars::{schema_for, JsonSchema};
use serde::{Deserialize, Serialize};
use std::env;
use std::path::PathBuf;

type NetworkId = u64;

#[derive(Debug, Serialize, Deserialize, JsonSchema)]
#[schemars(
    title = "Envio Config Schema",
    description = "Schema for a YAML config for an envio indexer"
)]
pub struct HumanConfig {
    #[schemars(description = "Name of the project")]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Description of the project")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contracts: Option<Vec<GlobalContractConfig>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[schemars(description = "Custom path to config file")]
    pub schema: Option<String>,
    #[schemars(
        description = "Configuration of the blockchain networks that the project is deployed on"
    )]
    pub networks: Vec<Network>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unordered_multichain_mode: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_decoder: Option<EventDecoder>,
}

impl HumanConfig {
    pub fn to_json_schema_pretty() -> String {
        let schema = schema_for!(HumanConfig);
        serde_json::to_string_pretty(&schema)
            .expect("Failed to generate JSON schema for config.yaml")
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum EventDecoder {
    Viem,
    HypersyncClient,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
pub struct GlobalContractConfig {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abi_file_path: Option<String>,
    pub handler: String,
    pub events: Vec<ConfigEvent>,
}

impl GlobalContractConfig {
    pub fn parse_abi(
        &self,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<Option<ethers::abi::Contract>> {
        match &self.abi_file_path {
            None => Ok(None),
            Some(abi_path_relative_string) => {
                let relative_path_buf = PathBuf::from(abi_path_relative_string);
                let abi_path =
                    path_utils::get_config_path_relative_to_root(project_paths, relative_path_buf)
                        .context("Failed getting abi path")?;
                let parsed = parse_contract_abi(abi_path).context(format!(
                    "Failed parsing global contract {} abi {}",
                    self.name, abi_path_relative_string
                ))?;
                Ok(Some(parsed))
            }
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
pub struct HypersyncConfig {
    #[serde(alias = "url")]
    pub endpoint_url: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SyncSourceConfig {
    RpcConfig(RpcConfig),
    HypersyncConfig(HypersyncConfig),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
pub struct Network {
    pub id: NetworkId,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    pub sync_source: Option<SyncSourceConfig>,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub contracts: Vec<NetworkContractConfig>,
}

impl Network {
    pub fn get_sync_source_with_default(&self) -> anyhow::Result<SyncSourceConfig> {
        match &self.sync_source {
            Some(s) => Ok(s.clone()),
            None => {
                let defualt_hypersync_endpoint = hypersync_endpoints::get_default_hypersync_endpoint(self.id.clone())
                    .context("EE106: Undefined network config, please provide rpc_config, read more in our docs https://docs.envio.dev/docs/configuration-file")?;

                Ok(SyncSourceConfig::HypersyncConfig(
                    defualt_hypersync_endpoint,
                ))
            }
        }
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone, JsonSchema)]
pub struct SyncConfigUnstable {
    #[serde(default = "default_initial_block_interval")]
    initial_block_interval: u32,

    #[serde(default = "default_backoff_multiplicative")]
    backoff_multiplicative: f32,

    #[serde(default = "default_acceleration_additive")]
    acceleration_additive: u32,

    #[serde(default = "default_interval_ceiling")]
    interval_ceiling: u32,

    #[serde(default = "default_backoff_millis")]
    backoff_millis: u32,

    #[serde(default = "default_query_timeout_millis")]
    query_timeout_millis: u32,
}

pub const SYNC_CONFIG_DEFAULT: SyncConfigUnstable = SyncConfigUnstable {
    initial_block_interval: 10_000,
    backoff_multiplicative: 0.8,
    acceleration_additive: 2_000,
    interval_ceiling: 10_000,
    backoff_millis: 5000,
    query_timeout_millis: 20_000,
};

// default value functions for sync config
fn default_initial_block_interval() -> u32 {
    SYNC_CONFIG_DEFAULT.initial_block_interval
}

fn default_backoff_multiplicative() -> f32 {
    SYNC_CONFIG_DEFAULT.backoff_multiplicative
}

fn default_acceleration_additive() -> u32 {
    SYNC_CONFIG_DEFAULT.acceleration_additive
}

fn default_interval_ceiling() -> u32 {
    SYNC_CONFIG_DEFAULT.interval_ceiling
}

fn default_backoff_millis() -> u32 {
    SYNC_CONFIG_DEFAULT.backoff_millis
}

fn default_query_timeout_millis() -> u32 {
    SYNC_CONFIG_DEFAULT.query_timeout_millis
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
#[allow(non_snake_case)] //Stop compiler warning for the double underscore in unstable__sync_config
pub struct RpcConfig {
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unstable__sync_config: Option<SyncConfigUnstable>,
}

impl RpcConfig {
    //used only in tests
    #[cfg(test)]
    pub fn new(url: &str) -> Self {
        RpcConfig {
            url: String::from(url),
            unstable__sync_config: Some(SYNC_CONFIG_DEFAULT),
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
pub struct NetworkContractConfig {
    pub name: String,
    pub address: NormalizedList<String>,
    #[serde(flatten)]
    //If this is "None" it should be expected that
    //there is a global config for the contract
    pub local_contract_config: Option<LocalContractConfig>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
pub struct LocalContractConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abi_file_path: Option<String>,
    pub handler: String,
    pub events: Vec<ConfigEvent>,
}

impl LocalContractConfig {
    pub fn parse_abi(
        &self,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<Option<ethers::abi::Contract>> {
        match &self.abi_file_path {
            None => Ok(None),
            Some(abi_path_relative_string) => {
                let relative_path_buf = PathBuf::from(abi_path_relative_string);
                let abi_path =
                    path_utils::get_config_path_relative_to_root(project_paths, relative_path_buf)?;
                let parsed = parse_contract_abi(abi_path).context(format!(
                    "Failed parsing local network contract abi {}",
                    abi_path_relative_string
                ))?;
                Ok(Some(parsed))
            }
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ConfigEvent {
    pub event: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_async: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required_entities: Option<Vec<RequiredEntity>>,
}

pub fn parse_contract_abi(abi_path: PathBuf) -> anyhow::Result<ethers::abi::Contract> {
    let abi_file = std::fs::read_to_string(&abi_path).context(format!(
        "Failed to read abi file at {:?}, relative to the current directory {:?}",
        abi_path,
        env::current_dir().unwrap_or(PathBuf::default())
    ))?;

    let abi: ethers::abi::Contract = serde_json::from_str(&abi_file).context(format!(
        "Failed to deserialize ABI at {:?} -  Please ensure the ABI file is formatted correctly \
         or contact the team.",
        abi_path
    ))?;

    Ok(abi)
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct RequiredEntity {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub labels: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub array_labels: Option<Vec<String>>,
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

pub fn deserialize_config_from_yaml(config_path: &PathBuf) -> anyhow::Result<HumanConfig> {
    let config = std::fs::read_to_string(config_path).context(format!(
        "EE104: Failed to resolve config path {0}. Make sure you're in the correct directory and \
         that a config file with the name {0} exists",
        &config_path
            .to_str()
            .unwrap_or("unknown config file name path"),
    ))?;

    let mut deserialized_yaml: HumanConfig = serde_yaml::from_str(&config).context(format!(
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
    use std::path::PathBuf;

    use crate::config_parsing::human_config::EventDecoder;

    use super::{HumanConfig, LocalContractConfig, Network, NetworkContractConfig, NormalizedList};
    use serde_json::json;

    #[test]
    fn test_flatten_deserialize_local_contract() {
        let yaml = r#"
name: Contract1
handler: ./src/EventHandler.js
address: ["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"]
events: []
    "#;

        let deserialized: NetworkContractConfig = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContractConfig {
            name: "Contract1".to_string(),
            address: NormalizedList::from(vec![
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()
            ]),
            local_contract_config: Some(LocalContractConfig {
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

        let deserialized: NetworkContractConfig = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContractConfig {
            name: "Contract1".to_string(),
            address: vec![].into(),
            local_contract_config: Some(LocalContractConfig {
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

        let deserialized: NetworkContractConfig = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContractConfig {
            name: "Contract1".to_string(),
            address: vec!["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()].into(),
            local_contract_config: Some(LocalContractConfig {
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

        let deserialized: NetworkContractConfig = serde_yaml::from_str(yaml).unwrap();
        let expected = NetworkContractConfig {
            name: "Contract1".to_string(),
            address: NormalizedList::from(vec![
                "0x2E645469f354BB4F5c8a05B3b30A929361cf77eC".to_string()
            ]),
            local_contract_config: None,
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

        assert!(cfg.networks[0].contracts[0].local_contract_config.is_some());
        assert!(cfg.networks[0].contracts[1].local_contract_config.is_some());
        assert_eq!(cfg.networks[0].contracts[1].address, None.into());
    }

    #[test]
    fn deserializes_dynamic_contract_config() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/dynamic-address-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: HumanConfig = serde_yaml::from_str(&file_str).unwrap();

        assert!(cfg.networks[0].contracts[0].local_contract_config.is_some());
        assert!(cfg.networks[1].contracts[0].local_contract_config.is_none());
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
                sync_source: None,
                start_block: 2_000,
                end_block: Some(2_000_000),
                contracts: vec![]
            },
            de
        );
    }
}
