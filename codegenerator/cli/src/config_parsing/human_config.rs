use super::{hypersync_endpoints, validation};
use crate::{
    constants::links,
    project_paths::{path_utils, ParsedProjectPaths},
    utils::normalized_list::NormalizedList,
};
use anyhow::{anyhow, Context};
use ethers::abi::{Event as EthAbiEvent, HumanReadableParser};
use serde::{Deserialize, Serialize};
use std::env;
use std::path::PathBuf;

type NetworkId = u64;

#[derive(Debug, Serialize, Deserialize)]
pub struct HumanConfig {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub contracts: Option<Vec<GlobalContractConfig>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
    pub networks: Vec<Network>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unordered_multichain_mode: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub event_decoder: Option<EventDecoder>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rollback_on_reorg: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub save_full_history: Option<bool>,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
#[serde(rename_all = "kebab-case")]
pub enum EventDecoder {
    Viem,
    HypersyncClient,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct HypersyncConfig {
    #[serde(alias = "url")]
    pub endpoint_url: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum SyncSourceConfig {
    RpcConfig(RpcConfig),
    HypersyncConfig(HypersyncConfig),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
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

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct NetworkContractConfig {
    pub name: String,
    pub address: NormalizedList<String>,
    #[serde(flatten)]
    //If this is "None" it should be expected that
    //there is a global config for the contract
    pub local_contract_config: Option<LocalContractConfig>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConfigEvent {
    pub event: EventNameOrSig,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_async: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required_entities: Option<Vec<RequiredEntity>>,
}

#[derive(Debug, PartialEq, Deserialize, Clone)]
#[serde(try_from = "String")]
pub enum EventNameOrSig {
    Name(String),
    Event(EthAbiEvent),
}

impl EventNameOrSig {
    pub fn get_abi_event(
        &self,
        opt_abi: &Option<ethers::abi::Contract>,
    ) -> anyhow::Result<EthAbiEvent> {
        match self {
            EventNameOrSig::Event(e) => Ok(e.clone()),
            EventNameOrSig::Name(config_event_name) => match opt_abi {
                Some(contract_abi) => {
                    let event = contract_abi.event(config_event_name).context(format!(
                        "Failed retrieving event {} from abi",
                        config_event_name
                    ))?;
                    Ok(event.clone())
                }
                None => Err(anyhow!(
                    "No abi file provided for event {}",
                    config_event_name
                )),
            },
        }
    }
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

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RequiredEntity {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub labels: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub array_labels: Option<Vec<String>>,
}

impl Serialize for EventNameOrSig {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            EventNameOrSig::Name(event_name) => serializer.serialize_str(event_name),
            EventNameOrSig::Event(eth_abi_event) => {
                serializer.serialize_str(eth_abi_event.to_human_readable().as_str())
            }
        }
    }
}

pub trait ToHumanReadable {
    fn to_human_readable(&self) -> String;
}

impl ToHumanReadable for ethers::abi::Event {
    fn to_human_readable(&self) -> String {
        format!(
            "{}({}){}",
            self.name,
            self.inputs
                .iter()
                .map(|input| {
                    let param_type = input.kind.to_string();
                    let indexed_keyword = if input.indexed { " indexed " } else { " " };
                    let param_name = input.name.clone();

                    format!("{}{}{}", param_type, indexed_keyword, param_name)
                })
                .collect::<Vec<_>>()
                .join(", "),
            if self.anonymous { " anonymous" } else { "" },
        )
    }
}

impl TryFrom<String> for EventNameOrSig {
    type Error = String;

    fn try_from(event_string: String) -> Result<Self, Self::Error> {
        let parse_event_sig = |sig: &str| -> Result<EthAbiEvent, Self::Error> {
            match HumanReadableParser::parse_event(sig) {
                Ok(event) => Ok(event),
                Err(err) => Err(format!(
                    "EE103: Unable to parse event signature {} due to the following error: {}. \
                     Please refer to our docs on how to correctly define a human readable ABI.",
                    sig, err
                )),
            }
        };

        let trimmed = event_string.trim();

        let name_or_sig = if trimmed.starts_with("event ") {
            let parsed_event = parse_event_sig(trimmed)?;
            EventNameOrSig::Event(parsed_event)
        } else if trimmed.contains('(') {
            let signature = format!("event {}", trimmed);
            let parsed_event = parse_event_sig(&signature)?;
            EventNameOrSig::Event(parsed_event)
        } else {
            EventNameOrSig::Name(trimmed.to_string())
        };

        Ok(name_or_sig)
    }
}

impl EventNameOrSig {
    pub fn get_name(&self) -> String {
        match self {
            EventNameOrSig::Name(name) => name.to_owned(),
            EventNameOrSig::Event(event) => event.name.clone(),
        }
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

    use super::{
        EventNameOrSig, HumanConfig, LocalContractConfig, Network, NetworkContractConfig,
        NormalizedList,
    };
    use ethers::abi::{Event, EventParam, ParamType};
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
    fn deserializes_event_name() {
        let event_string = serde_json::to_string("MyEvent").unwrap();

        let name_or_sig = serde_json::from_str::<EventNameOrSig>(&event_string).unwrap();
        let expected = EventNameOrSig::Name("MyEvent".to_string());
        assert_eq!(name_or_sig, expected);
    }

    #[test]
    fn deserializes_event_sig_with_event_prefix() {
        let event_string = serde_json::to_string("event MyEvent(uint256 myArg)").unwrap();

        let name_or_sig = serde_json::from_str::<EventNameOrSig>(&event_string).unwrap();
        let expected_event = Event {
            name: "MyEvent".to_string(),
            anonymous: false,
            inputs: vec![EventParam {
                indexed: false,
                name: "myArg".to_string(),
                kind: ParamType::Uint(256),
            }],
        };
        let expected = EventNameOrSig::Event(expected_event);
        assert_eq!(name_or_sig, expected);
    }

    #[test]
    fn deserializes_event_sig_without_event_prefix() {
        let event_string = serde_json::to_string("MyEvent(uint256 myArg)").unwrap();

        let name_or_sig = serde_json::from_str::<EventNameOrSig>(&event_string).unwrap();
        let expected_event = Event {
            name: "MyEvent".to_string(),
            anonymous: false,
            inputs: vec![EventParam {
                indexed: false,
                name: "myArg".to_string(),
                kind: ParamType::Uint(256),
            }],
        };
        let expected = EventNameOrSig::Event(expected_event);
        assert_eq!(name_or_sig, expected);
    }

    #[test]
    #[should_panic]
    fn deserializes_event_sig_invalid_panics() {
        let event_string = serde_json::to_string("MyEvent(uint69 myArg)").unwrap();
        serde_json::from_str::<EventNameOrSig>(&event_string).unwrap();
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
