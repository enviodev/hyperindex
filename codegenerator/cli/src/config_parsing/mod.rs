use ethers::abi::{Event as EthAbiEvent, HumanReadableParser};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::path::PathBuf;

use crate::hbs_templating::codegen_templates::EventType;
use crate::project_paths::handler_paths::ContractUniqueId;
use crate::{
    capitalization::{Capitalize, CapitalizedOptions},
    project_paths::ParsedPaths,
};

use anyhow::{anyhow, Context};

pub mod chain_helpers;
pub mod entity_parsing;
pub mod event_parsing;
pub mod hypersync_endpoints;
pub mod validation;

pub mod constants;
use crate::links;

use self::hypersync_endpoints::HypersyncEndpoint;
pub mod contract_import;
pub mod graph_migration;

type NetworkId = u64;

#[derive(Debug, Serialize, Deserialize)]
pub struct Config {
    name: String,
    description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
    pub networks: Vec<Network>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "kebab-case")]
enum HypersyncWorkerType {
    Skar,
    EthArchive,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct HypersyncConfig {
    worker_type: HypersyncWorkerType,
    endpoint_url: String,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "snake_case")]
enum SyncSourceConfig {
    RpcConfig(RpcConfig),
    HypersyncConfig(HypersyncConfig),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Network {
    pub id: NetworkId,
    #[serde(flatten, skip_serializing_if = "Option::is_none")]
    sync_source: Option<SyncSourceConfig>,
    start_block: i32,
    pub contracts: Vec<ConfigContract>,
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

// default value functions for sync config
fn default_initial_block_interval() -> u32 {
    constants::SYNC_CONFIG.initial_block_interval
}

fn default_backoff_multiplicative() -> f32 {
    constants::SYNC_CONFIG.backoff_multiplicative
}

fn default_acceleration_additive() -> u32 {
    constants::SYNC_CONFIG.acceleration_additive
}

fn default_interval_ceiling() -> u32 {
    constants::SYNC_CONFIG.interval_ceiling
}

fn default_backoff_millis() -> u32 {
    constants::SYNC_CONFIG.backoff_millis
}

fn default_query_timeout_millis() -> u32 {
    constants::SYNC_CONFIG.query_timeout_millis
}

#[allow(non_snake_case)]
fn default_unstable__sync_config() -> SyncConfigUnstable {
    SyncConfigUnstable {
        initial_block_interval: default_initial_block_interval(),
        backoff_multiplicative: default_backoff_multiplicative(),
        acceleration_additive: default_acceleration_additive(),
        interval_ceiling: default_interval_ceiling(),
        backoff_millis: default_backoff_millis(),
        query_timeout_millis: default_query_timeout_millis(),
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[allow(non_snake_case)] //Stop compiler warning for the double underscore in unstable__sync_config
pub struct RpcConfig {
    url: String,
    #[serde(default = "default_unstable__sync_config")]
    unstable__sync_config: SyncConfigUnstable,
}

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct ConfigContract {
    pub name: String,
    // Eg for implementing a custom deserializer
    //  #[serde(deserialize_with = "abi_path_to_abi")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abi_file_path: Option<String>,
    pub handler: String,
    address: NormalizedList<String>,
    pub events: Vec<ConfigEvent>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ConfigEvent {
    pub event: EventNameOrSig,
    #[serde(skip_serializing_if = "Option::is_none")]
    required_entities: Option<Vec<RequiredEntity>>,
}

#[derive(Debug, PartialEq, Deserialize, Clone)]
#[serde(try_from = "String")]
pub enum EventNameOrSig {
    Name(String),
    Event(EthAbiEvent),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RequiredEntity {
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    labels: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    array_labels: Option<Vec<String>>,
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

trait ToHumanReadable {
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

impl<T: Serialize + Clone> Serialize for NormalizedList<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.inner.serialize(serializer)
    }
}

impl TryFrom<String> for EventNameOrSig {
    type Error = String;

    fn try_from(event_string: String) -> Result<Self, Self::Error> {
        let parse_event_sig = |sig: &str| -> Result<EthAbiEvent, Self::Error> {
            match HumanReadableParser::parse_event(sig) {
                Ok(event) => Ok(event),
                Err(err) => Err(format!(
                    "EE103: Unable to parse event signature {} due to the following error: {}. Please refer to our docs on how to correctly define a human readable ABI.",
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

// We require this intermediate struct in order to allow the config to skip specifying "address".
#[derive(Deserialize)]
struct IntermediateConfigContract {
    pub name: String,
    pub abi_file_path: Option<String>,
    pub handler: String,
    // This is the difference - adding Option<> around it.
    address: Option<NormalizedList<String>>,
    events: Vec<ConfigEvent>,
}

impl From<IntermediateConfigContract> for ConfigContract {
    fn from(icc: IntermediateConfigContract) -> Self {
        ConfigContract {
            name: icc.name,
            abi_file_path: icc.abi_file_path,
            handler: icc.handler,
            address: icc.address.unwrap_or(NormalizedList { inner: vec![] }),
            events: icc.events,
        }
    }
}

impl<'de> Deserialize<'de> for ConfigContract {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        IntermediateConfigContract::deserialize(deserializer).map(ConfigContract::from)
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(untagged)]
enum SingleOrList<T: Clone> {
    Single(T),
    List(Vec<T>),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct OptSingleOrList<T: Clone>(Option<SingleOrList<T>>);

impl<T: Clone> OptSingleOrList<T> {
    fn to_normalized_list(&self) -> NormalizedList<T> {
        let list: Vec<T> = match &self.0 {
            Some(single_or_list) => match single_or_list {
                SingleOrList::Single(val) => vec![val.clone()],
                SingleOrList::List(list) => list.to_vec(),
            },
            None => Vec::new(),
        };

        NormalizedList { inner: list }
    }
}

#[derive(Debug, Deserialize, Clone, PartialEq)]
#[serde(try_from = "OptSingleOrList<T>")]
struct NormalizedList<T: Clone> {
    inner: Vec<T>,
}

impl<T: Clone> NormalizedList<T> {
    pub fn from(list: Vec<T>) -> Self {
        NormalizedList { inner: list }
    }

    pub fn from_single(val: T) -> Self {
        Self::from(vec![val])
    }
}

impl<T: Clone> TryFrom<OptSingleOrList<T>> for NormalizedList<T> {
    type Error = String;

    fn try_from(single_or_list: OptSingleOrList<T>) -> Result<Self, Self::Error> {
        Ok(single_or_list.to_normalized_list())
    }
}

// fn abi_path_to_abi<'de, D>(deserializer: D) -> Result<u64, D::Error>
// where
//     D: Deserializer<'de>,
// {
//     let abi_file_path: &str = Deserialize::deserialize(deserializer)?;
//     // ... convert to abi here
// }

type StringifiedAbi = String;
type EthAddress = String;
type ServerUrl = String;

#[derive(Debug, Serialize, PartialEq, Clone)]
struct NetworkConfigTemplate {
    pub id: NetworkId,
    rpc_config: Option<RpcConfig>,
    skar_server_url: Option<ServerUrl>,
    eth_archive_server_url: Option<ServerUrl>,
    start_block: i32,
    pub contracts: Vec<ConfigContract>,
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct ChainConfigTemplate {
    network_config: NetworkConfigTemplate,
    contracts: Vec<ContractTemplate>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct ChainConfigEvent {
    name: CapitalizedOptions,
    event_type: EventType,
}

impl ChainConfigEvent {
    pub fn new(contract_name: String, event_name: String) -> Self {
        let name = event_name.to_capitalized_options();
        let event_type = EventType::new(contract_name, event_name);

        ChainConfigEvent { name, event_type }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct ContractTemplate {
    name: CapitalizedOptions,
    abi: StringifiedAbi,
    addresses: Vec<EthAddress>,
    events: Vec<ChainConfigEvent>,
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

pub fn deserialize_config_from_yaml(config_path: &PathBuf) -> anyhow::Result<Config> {
    let config = std::fs::read_to_string(config_path).context(
        format!(
            "EE104: Failed to resolve config path {0}. Make sure you're in the correct directory and that a config file with the name {0} exists",
            &config_path.to_str().unwrap_or("unknown config file name path"),
        )
    )?;

    let mut deserialized_yaml: Config = serde_yaml::from_str(&config).context(format!(
        "EE105: Failed to deserialize config. Visit the docs for more information {}",
        links::DOC_CONFIGURATION_FILE
    ))?;

    deserialized_yaml.name = strip_to_letters(&deserialized_yaml.name);

    // Validating the config file
    validation::validate_deserialized_config_yaml(config_path, &deserialized_yaml)?;

    Ok(deserialized_yaml)
}

pub async fn convert_config_to_chain_configs(
    parsed_paths: &ParsedPaths,
) -> anyhow::Result<Vec<ChainConfigTemplate>> {
    let config = deserialize_config_from_yaml(&parsed_paths.project_paths.config)?;

    let mut chain_configs = Vec::new();
    for network in config.networks.iter() {
        let mut contract_templates = Vec::new();

        for contract in network.contracts.iter() {
            let contract_unique_id = ContractUniqueId {
                network_id: network.id,
                name: contract.name.clone(),
            };

            let parsed_abi_from_file = parsed_paths.get_contract_abi(&contract_unique_id)?;

            let mut reduced_abi = ethers::abi::Contract::default();

            for config_event in contract.events.iter() {
                let abi_event = match &config_event.event {
                    EventNameOrSig::Name(config_event_name) => match &parsed_abi_from_file {
                        Some(contract_abi) => {
                            contract_abi.event(config_event_name).context(format!(
                            "EE300: event \"{}\" cannot be parsed the provided abi for contract {}",
                            config_event_name, contract.name
                        ))?
                        }
                        None => {
                            let message = anyhow!("EE301: Please add abi_file_path for contract {} to your config to parse event {} or define the signature in the config", contract.name, config_event_name);
                            Err(message)?
                        }
                    },
                    EventNameOrSig::Event(abi_event) => abi_event,
                };

                reduced_abi
                    .events
                    .entry(abi_event.name.clone())
                    .or_default()
                    .push(abi_event.clone());
            }

            let stringified_abi = serde_json::to_string(&reduced_abi)?;
            let contract_template = ContractTemplate {
                name: contract.name.to_capitalized_options(),
                abi: stringified_abi,
                addresses: contract.address.inner.clone(),
                events: contract
                    .events
                    .iter()
                    .map(|config_event| {
                        ChainConfigEvent::new(contract.name.clone(), config_event.event.get_name())
                    })
                    .collect(),
            };
            contract_templates.push(contract_template);
        }

        let (rpc_config, skar_server_url, eth_archive_server_url) = match &network.sync_source {
            Some(sync_source) => match sync_source {
                SyncSourceConfig::RpcConfig(rpc_config) => (Some(rpc_config.clone()), None, None),
                SyncSourceConfig::HypersyncConfig(hypersync_config) => {
                    match hypersync_config.worker_type {
                        HypersyncWorkerType::Skar => {
                            (None, Some(hypersync_config.endpoint_url.clone()), None)
                        }
                        HypersyncWorkerType::EthArchive => {
                            (None, None, Some(hypersync_config.endpoint_url.clone()))
                        }
                    }
                }
            },
            None => {
                let defualt_hypersync_endpoint = hypersync_endpoints::get_default_hypersync_endpoint(&network.id)
                    .context("EE106: Undefined network config, please provide rpc_config, read more in our docs https://docs.envio.dev/docs/configuration-file")?;

                defualt_hypersync_endpoint.check_endpoint_health().await.context(format!("EE107: hypersync endpoint unhealthy at network {}, please provide rpc_config or hypersync_config. Read more in our docs https://docs.envio.dev/docs/configuration-file", network.id ))?;
                match defualt_hypersync_endpoint {
                    HypersyncEndpoint::Skar(skar_url) => (None, Some(skar_url), None),
                    HypersyncEndpoint::EthArchive(eth_archive_url) => {
                        (None, None, Some(eth_archive_url))
                    }
                }
            }
        };

        let network_config = NetworkConfigTemplate {
            id: network.id.clone(),
            start_block: network.start_block.clone(),
            contracts: network.contracts.clone(),
            rpc_config,
            skar_server_url,
            eth_archive_server_url,
        };

        let chain_config = ChainConfigTemplate {
            network_config,
            contracts: contract_templates,
        };
        chain_configs.push(chain_config);
    }
    Ok(chain_configs)
}

pub fn get_project_name_from_config(parsed_paths: &ParsedPaths) -> Result<String, Box<dyn Error>> {
    let config = deserialize_config_from_yaml(&parsed_paths.project_paths.config)?;
    Ok(config.name)
}

pub fn is_rescript(handler_path: &HashMap<ContractUniqueId, PathBuf>) -> bool {
    for handler_path in handler_path.values() {
        if let Ok(path_str) = handler_path.clone().into_os_string().into_string() {
            if path_str.ends_with(".bs.js") {
                return true;
            }
        }
    }
    false
}
#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use ethers::abi::{Event, EventParam, ParamType};

    use crate::capitalization::Capitalize;
    use crate::config_parsing::{EventNameOrSig, NetworkConfigTemplate, NormalizedList};
    use crate::{cli_args::ProjectPathsArgs, project_paths::ParsedPaths};

    use super::{ChainConfigEvent, ChainConfigTemplate};

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
    #[tokio::test]
    async fn check_config_with_multiple_sync_sources() {
        let project_root = String::from("test");
        let config = String::from("configs/invalid-multiple-sync-config6.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();
        let parsed = super::convert_config_to_chain_configs(&parsed_paths)
            .await
            .unwrap();

        assert!(
            parsed[0].network_config.rpc_config.is_none(),
            "rpc config should have been none since it was defined second"
        );

        assert!(
            parsed[0].network_config.skar_server_url.is_some(),
            "skar config should be some since it was defined first"
        );
    }

    #[tokio::test]
    async fn convert_to_chain_configs_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let abi_file_path = PathBuf::from("test/abis/Contract1.json");

        let event1 = super::ConfigEvent {
            event: EventNameOrSig::Name(String::from("NewGravatar")),
            required_entities: None,
        };

        let event2 = super::ConfigEvent {
            event: EventNameOrSig::Name(String::from("UpdatedGravatar")),
            required_entities: None,
        };

        let contract1 = super::ConfigContract {
            handler: "./src/EventHandler.js".to_string(),
            address: NormalizedList::from_single(address1.clone()),
            name: String::from("Contract1"),
            //needed to have relative path in order to match config1.yaml
            abi_file_path: Some(String::from("../abis/Contract1.json")),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts = vec![contract1.clone()];

        let sync_config = super::SyncConfigUnstable {
            initial_block_interval: 10000,
            interval_ceiling: 10000,
            backoff_multiplicative: 0.8,
            acceleration_additive: 2000,
            backoff_millis: 5000,
            query_timeout_millis: 20000,
        };

        let rpc_config1 = super::RpcConfig {
            url: String::from("https://eth.com"),
            unstable__sync_config: sync_config,
        };

        let network1 = NetworkConfigTemplate {
            id: 1,
            rpc_config: Some(rpc_config1),
            skar_server_url: None,
            eth_archive_server_url: None,
            start_block: 0,
            contracts,
        };

        let project_root = String::from("test");
        let config = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();
        let chain_configs = super::convert_config_to_chain_configs(&parsed_paths)
            .await
            .unwrap();
        let abi_unparsed_string =
            fs::read_to_string(abi_file_path).expect("expected json file to be at this path");
        let abi_parsed: ethers::abi::Contract = serde_json::from_str(&abi_unparsed_string).unwrap();
        let abi_parsed_string = serde_json::to_string(&abi_parsed).unwrap();
        let contract1_name = String::from("Contract1");
        let contract1 = super::ContractTemplate {
            name: contract1_name.to_capitalized_options(),
            abi: abi_parsed_string,
            addresses: vec![address1.clone()],
            events: vec![
                ChainConfigEvent::new(contract1_name.clone(), event1.event.get_name()),
                ChainConfigEvent::new(contract1_name.clone(), event2.event.get_name()),
            ],
        };

        let chain_config_1 = ChainConfigTemplate {
            network_config: network1,
            contracts: vec![contract1],
        };

        let expected_chain_configs = vec![chain_config_1];

        assert_eq!(
            expected_chain_configs[0].network_config,
            chain_configs[0].network_config
        );
        assert_eq!(expected_chain_configs, chain_configs,);
    }

    #[tokio::test]
    async fn convert_to_chain_configs_case_2() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let address2 = String::from("0x1E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let abi_file_path = PathBuf::from("test/abis/Contract1.json");

        let event1 = super::ConfigEvent {
            event: EventNameOrSig::Name(String::from("NewGravatar")),
            required_entities: None,
        };

        let event2 = super::ConfigEvent {
            event: EventNameOrSig::Name(String::from("UpdatedGravatar")),
            required_entities: None,
        };

        let contract1 = super::ConfigContract {
            handler: "./src/EventHandler.js".to_string(),
            address: NormalizedList::from_single(address1.clone()),
            name: String::from("Contract1"),
            abi_file_path: Some(String::from("../abis/Contract1.json")),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts1 = vec![contract1.clone()];

        let sync_config = super::SyncConfigUnstable {
            initial_block_interval: 10000,
            interval_ceiling: 10000,
            backoff_multiplicative: 0.8,
            acceleration_additive: 2000,
            backoff_millis: 5000,
            query_timeout_millis: 20000,
        };

        let rpc_config1 = super::RpcConfig {
            url: String::from("https://eth.com"),
            unstable__sync_config: sync_config,
        };

        let network1 = NetworkConfigTemplate {
            id: 1,
            rpc_config: Some(rpc_config1),
            skar_server_url: None,
            eth_archive_server_url: None,
            start_block: 0,
            contracts: contracts1,
        };

        let contract2 = super::ConfigContract {
            handler: "./src/EventHandler.js".to_string(),
            address: NormalizedList::from_single(address2.clone()),
            name: String::from("Contract2"),
            abi_file_path: Some(String::from("../abis/Contract2.json")),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts2 = vec![contract2];

        let sync_config = super::SyncConfigUnstable {
            initial_block_interval: 10000,
            interval_ceiling: 10000,
            backoff_multiplicative: 0.8,
            acceleration_additive: 2000,
            backoff_millis: 5000,
            query_timeout_millis: 20000,
        };

        let rpc_config2 = super::RpcConfig {
            url: String::from("https://eth.com"),
            unstable__sync_config: sync_config,
        };

        let network2 = NetworkConfigTemplate {
            id: 2,
            rpc_config: Some(rpc_config2),
            skar_server_url: None,
            eth_archive_server_url: None,
            start_block: 0,
            contracts: contracts2,
        };

        let project_root = String::from("test");
        let config = String::from("configs/config2.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let chain_configs = super::convert_config_to_chain_configs(&parsed_paths)
            .await
            .unwrap();

        let abi_unparsed_string =
            fs::read_to_string(abi_file_path).expect("expected json file to be at this path");
        let abi_parsed: ethers::abi::Contract = serde_json::from_str(&abi_unparsed_string).unwrap();
        let abi_parsed_string = serde_json::to_string(&abi_parsed).unwrap();
        let contract1_name = String::from("Contract1");
        let contract1 = super::ContractTemplate {
            name: contract1_name.to_capitalized_options(),
            abi: abi_parsed_string.clone(),
            addresses: vec![address1.clone()],
            events: vec![
                ChainConfigEvent::new(contract1_name.clone(), event1.event.get_name()),
                ChainConfigEvent::new(contract1_name.clone(), event2.event.get_name()),
            ],
        };
        let contract2_name = String::from("Contract2");
        let contract2 = super::ContractTemplate {
            name: contract2_name.to_capitalized_options(),
            abi: abi_parsed_string.clone(),
            addresses: vec![address2.clone()],
            events: vec![
                ChainConfigEvent::new(contract2_name.clone(), event1.event.get_name()),
                ChainConfigEvent::new(contract2_name.clone(), event2.event.get_name()),
            ],
        };

        let chain_config_1 = ChainConfigTemplate {
            network_config: network1,
            contracts: vec![contract1],
        };
        let chain_config_2 = ChainConfigTemplate {
            network_config: network2,
            contracts: vec![contract2],
        };

        let expected_chain_configs = vec![chain_config_1, chain_config_2];

        assert_eq!(chain_configs, expected_chain_configs);
    }

    #[tokio::test]
    async fn convert_to_chain_configs_case_3() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let abi_file_path = PathBuf::from("test/abis/Contract1.json");

        let event1 = super::ConfigEvent {
            event: EventNameOrSig::Name(String::from("NewGravatar")),
            required_entities: None,
        };

        let event2 = super::ConfigEvent {
            event: EventNameOrSig::Name(String::from("UpdatedGravatar")),
            required_entities: None,
        };

        let contract1 = super::ConfigContract {
            handler: "./src/EventHandler.js".to_string(),
            address: NormalizedList::from_single(address1.clone()),
            name: String::from("Contract1"),
            abi_file_path: Some(String::from("../abis/Contract1.json")),
            events: vec![event1.clone(), event2.clone()],
        };

        let contracts1 = vec![contract1.clone()];

        let network1 = NetworkConfigTemplate {
            id: 1,
            rpc_config: None,
            skar_server_url: Some("http://eth.hypersync.bigdevenergy.link:1100".to_string()),
            eth_archive_server_url: None,
            start_block: 0,
            contracts: contracts1,
        };

        let project_root = String::from("test");
        let config = String::from("configs/config3.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let chain_configs = super::convert_config_to_chain_configs(&parsed_paths)
            .await
            .unwrap();

        let abi_unparsed_string =
            fs::read_to_string(abi_file_path).expect("expected json file to be at this path");
        let abi_parsed: ethers::abi::Contract = serde_json::from_str(&abi_unparsed_string).unwrap();
        let abi_parsed_string = serde_json::to_string(&abi_parsed).unwrap();

        let contract1_name = String::from("Contract1");
        let contract1 = super::ContractTemplate {
            name: contract1_name.to_capitalized_options(),
            abi: abi_parsed_string.clone(),
            addresses: vec![address1.clone()],
            events: vec![
                ChainConfigEvent::new(contract1_name.clone(), event1.event.get_name()),
                ChainConfigEvent::new(contract1_name.clone(), event2.event.get_name()),
            ],
        };

        let chain_config_1 = ChainConfigTemplate {
            network_config: network1,
            contracts: vec![contract1],
        };

        let expected_chain_configs = vec![chain_config_1];

        assert_eq!(chain_configs, expected_chain_configs);
    }

    #[tokio::test]
    async fn convert_to_chain_configs_case_4() {
        let network1 = NetworkConfigTemplate {
            id: 1,
            rpc_config: None,
            skar_server_url: Some("https://myskar.com".to_string()),
            eth_archive_server_url: None,
            start_block: 0,
            contracts: vec![],
        };

        let network2 = NetworkConfigTemplate {
            id: 43114,
            rpc_config: None,
            skar_server_url: None,
            //Should default to eth archive since there is no skar endpoint at this id
            eth_archive_server_url: Some("http://46.4.5.110:72".to_string()),
            start_block: 0,
            contracts: vec![],
        };

        let project_root = String::from("test");
        let config = String::from("configs/config4.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();
        let chain_configs = super::convert_config_to_chain_configs(&parsed_paths)
            .await
            .unwrap();

        let chain_config_1 = ChainConfigTemplate {
            network_config: network1,
            contracts: vec![],
        };

        let chain_config_2 = ChainConfigTemplate {
            network_config: network2,
            contracts: vec![],
        };

        let expected_chain_configs = vec![chain_config_1, chain_config_2];
        assert_eq!(expected_chain_configs, chain_configs);
    }

    #[tokio::test]
    #[should_panic]
    async fn convert_to_chain_configs_case_5() {
        //Bad chain ID without sync config should panic
        let project_root = String::from("test");
        let config = String::from("configs/config5.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        super::convert_config_to_chain_configs(&parsed_paths)
            .await
            .unwrap();
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
}
