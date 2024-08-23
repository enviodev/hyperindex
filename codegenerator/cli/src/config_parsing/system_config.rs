use super::{
    chain_helpers::get_confirmed_block_threshold_from_id,
    entity_parsing::{Entity, GraphQLEnum, Schema},
    human_config::{
        self,
        evm::{EventConfig, EventDecoder, HumanConfig as EvmConfig, Network as EvmNetwork},
        fuel::HumanConfig as FuelConfig,
    },
    hypersync_endpoints,
    validation::validate_names_valid_rescript,
};
use crate::{
    config_parsing::human_config::evm::{RpcBlockField, RpcTransactionField},
    constants::{project_paths::DEFAULT_SCHEMA_PATH, DEFAULT_CONFIRMED_BLOCK_THRESHOLD},
    project_paths::{path_utils, ParsedProjectPaths},
    utils::unique_hashmap,
};
use anyhow::{anyhow, Context, Result};
use ethers::abi::{ethabi::Event as EthAbiEvent, EventExt, EventParam, HumanReadableParser};
use itertools::Itertools;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::PathBuf,
};

type ContractNameKey = String;
type NetworkIdKey = u64;
type EntityKey = String;
type GraphqlEnumKey = String;
type NetworkMap = HashMap<NetworkIdKey, Network>;
type ContractMap = HashMap<ContractNameKey, Contract>;
pub type EntityMap = HashMap<EntityKey, Entity>;
pub type GraphQlEnumMap = HashMap<GraphqlEnumKey, GraphQLEnum>;

#[derive(Debug, PartialEq)]
pub enum Ecosystem {
    Evm,
    Fuel,
}

#[derive(Debug)]
pub struct SystemConfig {
    pub name: String,
    pub ecosystem: Ecosystem,
    pub schema_path: String,
    pub parsed_project_paths: ParsedProjectPaths,
    pub networks: NetworkMap,
    pub contracts: ContractMap,
    pub unordered_multichain_mode: bool,
    pub rollback_on_reorg: bool,
    pub save_full_history: bool,
    pub schema: Schema,
    pub field_selection: FieldSelection,
    pub enable_raw_events: bool,
}

//Getter methods for system config
impl SystemConfig {
    pub fn get_contracts(&self) -> Vec<&Contract> {
        let mut contracts: Vec<&Contract> = self.contracts.values().collect();
        contracts.sort_by_key(|c| c.name.clone());
        contracts
    }

    pub fn get_contract(&self, name: &ContractNameKey) -> Option<&Contract> {
        self.contracts.get(name)
    }

    pub fn get_entity_names(&self) -> Vec<EntityKey> {
        let mut entity_names: Vec<EntityKey> = self
            .schema
            .entities
            .values()
            .map(|v| v.name.clone())
            .collect();
        //For consistent templating in alphabetical order
        entity_names.sort();
        entity_names
    }

    pub fn get_entity(&self, entity_name: &EntityKey) -> Option<&Entity> {
        self.schema.entities.get(entity_name)
    }

    pub fn get_entities(&self) -> Vec<&Entity> {
        let mut entities: Vec<&Entity> = self.schema.entities.values().collect();
        //For consistent templating in alphabetical order
        entities.sort_by_key(|e| e.name.clone());
        entities
    }

    pub fn get_entity_map(&self) -> &EntityMap {
        &self.schema.entities
    }

    pub fn get_gql_enum(&self, enum_name: &GraphqlEnumKey) -> Option<&GraphQLEnum> {
        self.schema.enums.get(enum_name)
    }

    pub fn get_gql_enum_map(&self) -> &GraphQlEnumMap {
        &self.schema.enums
    }

    pub fn get_gql_enums(&self) -> Vec<&GraphQLEnum> {
        let mut enums: Vec<&GraphQLEnum> = self.schema.enums.values().collect();
        //For consistent templating in alphabetical order
        enums.sort_by_key(|e| e.name.clone());
        enums
    }

    pub fn get_gql_enum_names_set(&self) -> HashSet<EntityKey> {
        self.schema.enums.keys().cloned().collect()
    }

    pub fn get_networks(&self) -> Vec<&Network> {
        let mut networks: Vec<&Network> = self.networks.values().collect();
        networks.sort_by_key(|n| n.id);
        networks
    }

    pub fn get_path_to_schema(&self) -> Result<PathBuf> {
        let schema_path = path_utils::get_config_path_relative_to_root(
            &self.parsed_project_paths,
            PathBuf::from(&self.schema_path),
        )
        .context("Failed creating a relative path to schema")?;

        Ok(schema_path)
    }

    pub fn get_all_paths_to_handlers(&self) -> Result<Vec<PathBuf>> {
        let mut all_paths_to_handlers = self
            .get_contracts()
            .into_iter()
            .map(|c| c.get_path_to_handler(&self.parsed_project_paths))
            .collect::<Result<HashSet<_>>>()?
            .into_iter()
            .collect::<Vec<_>>();

        all_paths_to_handlers.sort();

        Ok(all_paths_to_handlers)
    }

    pub fn get_all_paths_to_abi_files(&self) -> Result<Vec<PathBuf>> {
        let mut filtered_unique_abi_files = self
            .get_contracts()
            .into_iter()
            .filter_map(|c| c.abi.path.clone())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();

        filtered_unique_abi_files.sort();
        Ok(filtered_unique_abi_files)
    }
}

//Parse methods for system config
impl SystemConfig {
    pub fn from_evm_config(
        evm_config: EvmConfig,
        schema: Schema,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Self> {
        let mut networks: NetworkMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        //Add all global contracts
        if let Some(global_contracts) = evm_config.contracts {
            for g_contract in global_contracts {
                let abi_from_file =
                    EvmAbi::from_file(&g_contract.config.abi_file_path, project_paths)?;

                let events = g_contract
                    .config
                    .events
                    .iter()
                    .cloned()
                    .map(|e| Event::from_evm_event_config(e, &abi_from_file))
                    .collect::<Result<Vec<_>>>()
                    .context(format!(
                        "Failed parsing abi types for events in global contract {}",
                        g_contract.name,
                    ))?;

                let contract = Contract::new(
                    g_contract.name.clone(),
                    g_contract.config.handler.clone(),
                    events,
                    abi_from_file,
                )
                .context("Failed parsing globally defined contract")?;

                //Check if contract exists
                unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                    .context("Failed inserting globally defined contract")?;
            }
        }

        for network in evm_config.networks {
            for contract in network.contracts.clone() {
                //Add values for local contract
                match contract.config {
                    Some(l_contract) => {
                        //If there is a local contract, parse it and insert into contracts
                        let abi_from_file =
                            EvmAbi::from_file(&l_contract.abi_file_path, project_paths)?;

                        let events = l_contract
                            .events
                            .iter()
                            .cloned()
                            .map(|e| Event::from_evm_event_config(e, &abi_from_file))
                            .collect::<Result<Vec<_>>>()?;

                        let contract =
                            Contract::new(contract.name, l_contract.handler, events, abi_from_file)
                                .context(format!(
                                    "Failed parsing locally defined network contract at network \
                                     id {}",
                                    network.id
                                ))?;

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context(format!(
                                "Failed inserting locally defined network contract at network id \
                                 {}",
                                network.id,
                            ))?;
                    }
                    None => {
                        //Validate that there is a global contract for the given contract if
                        //there is no config
                        if !contracts.get(&contract.name).is_some() {
                            Err(anyhow!(
                                "Failed to find contract '{}' in global contract config. If you \
                                 don't use global contracts for multiple networks support, please \
                                 specify events and handler for the contract.",
                                contract.name
                            ))?;
                        }
                    }
                }
            }

            let sync_source = SyncSource::from_evm_network_config(
                network.clone(),
                evm_config.event_decoder.clone(),
            )?;

            let contracts: Vec<NetworkContract> = network
                .contracts
                .iter()
                .cloned()
                .map(|c| NetworkContract {
                    name: c.name,
                    addresses: c.address.into(),
                })
                .collect();

            let network = Network {
                id: network.id,
                confirmed_block_threshold: network
                    .confirmed_block_threshold
                    .unwrap_or(get_confirmed_block_threshold_from_id(network.id)),
                start_block: network.start_block,
                end_block: network.end_block,
                sync_source,
                contracts,
            };

            unique_hashmap::try_insert(&mut networks, network.id.clone(), network)
                .context("Failed inserting network at networks map")?;
        }

        let field_selection =
            evm_config
                .field_selection
                .map_or(Ok(FieldSelection::empty()), |field_selection| {
                    FieldSelection::try_from_config_field_selection(field_selection, &networks)
                })?;

        Ok(SystemConfig {
            name: evm_config.name.clone(),
            ecosystem: Ecosystem::Evm,
            parsed_project_paths: project_paths.clone(),
            schema_path: evm_config
                .schema
                .clone()
                .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
            networks,
            contracts,
            unordered_multichain_mode: evm_config.unordered_multichain_mode.unwrap_or(false),
            rollback_on_reorg: evm_config.rollback_on_reorg.unwrap_or(true),
            save_full_history: evm_config.save_full_history.unwrap_or(false),
            schema,
            field_selection,
            enable_raw_events: evm_config.raw_events.unwrap_or(false),
        })
    }

    pub fn from_fuel_config(
        fuel_config: FuelConfig,
        schema: Schema,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Self> {
        let mut networks: NetworkMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        //Add all global contracts
        if let Some(global_contracts) = &fuel_config.contracts {
            for g_contract in global_contracts {
                let events = g_contract
                    .config
                    .events
                    .iter()
                    .cloned()
                    .map(|e| {
                        Event::from_evm_event_config(
                            EventConfig {
                                event: format!("{}()", e.name),
                                name: None,
                            },
                            &None,
                        )
                    })
                    .collect::<Result<Vec<_>>>()
                    .context(format!(
                        "Failed parsing abi types for events in global contract {}",
                        g_contract.name,
                    ))?;

                let contract = Contract::new(
                    g_contract.name.clone(),
                    g_contract.config.handler.clone(),
                    events,
                    None,
                )?;

                //Check if contract exists
                unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                    .context("Failed inserting globally defined contract")?;
            }
        }

        for network in &fuel_config.networks {
            for contract in network.contracts.clone() {
                //Add values for local contract
                match contract.config {
                    Some(l_contract) => {
                        let events = l_contract
                            .events
                            .iter()
                            .cloned()
                            .map(|e| {
                                Event::from_evm_event_config(
                                    EventConfig {
                                        event: format!("{}()", e.name),
                                        name: None,
                                    },
                                    &None,
                                )
                            })
                            .collect::<Result<Vec<_>>>()?;

                        // FIXME: Support Fuel for contract
                        let contract =
                            Contract::new(contract.name.clone(), l_contract.handler, events, None)?;

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context(format!(
                                "Failed inserting locally defined network contract at network id \
                               {}",
                                network.id,
                            ))?;
                    }
                    None => {
                        //Validate that there is a global contract for the given contract if
                        //there is no local_contract_config
                        if !contracts.get(&contract.name).is_some() {
                            Err(anyhow!(
                                "Expected a local network config definition or a global definition"
                            ))?;
                        }
                    }
                }
            }

            let sync_source = SyncSource::HyperfuelConfig(HyperfuelConfig {
                endpoint_url: "https://fuel-testnet.hypersync.xyz".to_string(),
            });

            let contracts: Vec<NetworkContract> = network
                .contracts
                .iter()
                .cloned()
                .map(|c| NetworkContract {
                    name: c.name,
                    addresses: c.address.into(),
                })
                .collect();

            let network = Network {
                id: network.id as u64,
                start_block: network.start_block,
                end_block: network.end_block,
                confirmed_block_threshold: DEFAULT_CONFIRMED_BLOCK_THRESHOLD,
                sync_source,
                contracts,
            };

            unique_hashmap::try_insert(&mut networks, network.id.clone(), network)
                .context("Failed inserting network at networks map")?;
        }

        Ok(SystemConfig {
            name: fuel_config.name.clone(),
            ecosystem: Ecosystem::Fuel,
            parsed_project_paths: project_paths.clone(),
            schema_path: fuel_config
                .schema
                .clone()
                .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
            networks,
            contracts,
            unordered_multichain_mode: false,
            rollback_on_reorg: false,
            save_full_history: false,
            schema,
            field_selection: FieldSelection::empty(),
            enable_raw_events: false,
        })
    }

    pub fn parse_from_project_files(project_paths: &ParsedProjectPaths) -> Result<Self> {
        let human_config_string =
            std::fs::read_to_string(&project_paths.config).context(format!(
          "EE104: Failed to resolve config path {0}. Make sure you're in the correct directory and \
           that a config file with the name {0} exists",
          &project_paths.config
              .to_str()
              .unwrap_or("{unknown}"),
        ))?;

        let config_discriminant: human_config::ConfigDiscriminant =
          serde_yaml::from_str(&human_config_string)
                .context("EE105: Failed to deserialize config. The config.yaml file is either not a valid yaml or the \"ecosystem\" field is not a string.")?;

        let ecosystem = match config_discriminant.ecosystem.as_ref() {
            Some("evm") => Ecosystem::Evm,
            Some("fuel") => Ecosystem::Fuel,
            Some(ecosystem) => {
                return Err(anyhow!(
                    "EE105: Failed to deserialize config. The ecosystem \"{}\" is not supported.",
                    ecosystem
                ))
            }
            None => Ecosystem::Evm,
        };

        match ecosystem {
            Ecosystem::Evm => {
                let evm_config = human_config::deserialize_config_from_yaml(human_config_string)?;
                let schema = Schema::parse_from_file(&project_paths, &evm_config.schema)
                    .context("Parsing schema file for config")?;
                Self::from_evm_config(evm_config, schema, project_paths)
            }
            Ecosystem::Fuel => return Err(anyhow!("EE105: Failed to deserialize config. It's not supported with the main envio package yet, please install the envio@fuel version.")),
        }
    }
}

type ServerUrl = String;

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct HypersyncConfig {
    pub endpoint_url: ServerUrl,
    pub is_client_decoder: bool,
}

#[derive(Debug, Serialize, Clone, PartialEq)]
pub struct HyperfuelConfig {
    pub endpoint_url: ServerUrl,
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct SyncConfig {
    initial_block_interval: u32,
    backoff_multiplicative: f64,
    acceleration_additive: u32,
    interval_ceiling: u32,
    backoff_millis: u32,
    query_timeout_millis: u32,
    fallback_stall_timeout: u32,
}

impl Default for SyncConfig {
    fn default() -> Self {
        const QUERY_TIMEOUT_MILLIS: u32 = 20_000;
        Self {
            initial_block_interval: 10_000,
            backoff_multiplicative: 0.8,
            acceleration_additive: 2_000,
            interval_ceiling: 10_000,
            backoff_millis: 5000,
            query_timeout_millis: QUERY_TIMEOUT_MILLIS,
            fallback_stall_timeout: QUERY_TIMEOUT_MILLIS / 2,
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct RpcConfig {
    pub urls: Vec<String>,
    pub sync_config: SyncConfig,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SyncSource {
    RpcConfig(RpcConfig),
    HypersyncConfig(HypersyncConfig),
    HyperfuelConfig(HyperfuelConfig),
}

// Check if the given RPC URL is valid in terms of formatting.
// For now, we only check if it starts with http:// or https://
fn validate_url(url: &str) -> bool {
    // Check URL format
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return false;
    }
    true
}

impl SyncSource {
    fn from_evm_network_config(
        network: EvmNetwork,
        event_decoder: Option<EventDecoder>,
    ) -> Result<Self> {
        let is_client_decoder = match event_decoder {
            Some(EventDecoder::HypersyncClient) | None => true,
            Some(EventDecoder::Viem) => false,
        };
        match network {
            human_config::evm::Network {
                hypersync_config: Some(_),
                rpc_config: Some(_),
                ..
            } => {
                Err(anyhow!("EE106: Cannot define both rpc_config and hypersync_config for the same network, please choose only one of them, read more in our docs https://docs.envio.dev/docs/configuration-file"))
            }
            human_config::evm::Network {
              hypersync_config: None,
              rpc_config: None,
                ..
            } => {
                let defualt_hypersync_endpoint = hypersync_endpoints::get_default_hypersync_endpoint(network.id.clone())
                    .context("EE106: Undefined network config, please provide rpc_config, read more in our docs https://docs.envio.dev/docs/configuration-file")?;
                Ok(Self::HypersyncConfig(HypersyncConfig {
                    endpoint_url: defualt_hypersync_endpoint,
                    is_client_decoder,
                }))
            }
            human_config::evm::Network {
              hypersync_config: None,
              rpc_config: Some(human_config::evm::RpcConfig {
                url,
                sync_config
              }),
              ..
          } => {
            let urls: Vec<String> = url.into();
            for url in urls.iter() {
              if !validate_url(url) {
                return Err(anyhow!("EE109: The RPC url \"{}\" is incorrect format. The RPC url needs to start with either http:// or https://", url));
              }
            }
            Ok(Self::RpcConfig(RpcConfig {
                urls,
                sync_config: match sync_config {
                    None => SyncConfig::default(),
                    Some(c) => {
                      let query_timeout_millis = c
                        .query_timeout_millis
                        .unwrap_or_else(|| SyncConfig::default().query_timeout_millis);
                      SyncConfig {
                        acceleration_additive: c
                            .acceleration_additive
                            .unwrap_or_else(|| SyncConfig::default().acceleration_additive),
                        backoff_millis: c
                            .backoff_millis
                            .unwrap_or_else(|| SyncConfig::default().backoff_millis),
                        backoff_multiplicative: c
                            .backoff_multiplicative
                            .unwrap_or_else(|| SyncConfig::default().backoff_multiplicative),
                        initial_block_interval: c
                            .initial_block_interval
                            .unwrap_or_else(|| SyncConfig::default().initial_block_interval),
                        interval_ceiling: c
                            .interval_ceiling
                            .unwrap_or_else(|| SyncConfig::default().interval_ceiling),
                        query_timeout_millis,
                        fallback_stall_timeout: c
                            .fallback_stall_timeout
                            .unwrap_or_else(|| query_timeout_millis / 2),
                    }},
                },
            }))},
            human_config::evm::Network {
              hypersync_config: Some(human_config::evm::HypersyncConfig { url }),
              rpc_config: None,
              ..
          } => {
                if !validate_url(&url) {
                  return Err(anyhow!("EE106: The HyperSync url \"{}\" is incorrect format. The HyperSync url needs to start with either http:// or https://", url));
                }
                Ok(Self::HypersyncConfig(HypersyncConfig { endpoint_url: url, is_client_decoder }))
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Network {
    pub id: u64,
    pub sync_source: SyncSource,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub confirmed_block_threshold: i32,
    pub contracts: Vec<NetworkContract>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NetworkContract {
    pub name: ContractNameKey,
    pub addresses: Vec<String>,
}

impl NetworkContract {
    pub fn get_contract<'a>(&self, config: &'a SystemConfig) -> Result<&'a Contract> {
        config.get_contract(&self.name).ok_or_else(|| {
            anyhow!(
                "Unexpected, network contract {} should have a contract in mapping",
                self.name
            )
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct EvmAbi {
    // The path is not always present since we allow to get ABI from events
    pub path: Option<PathBuf>,
    pub raw: String,
    typed: ethers::abi::Abi,
}

impl EvmAbi {
    pub fn from_file(
        abi_file_path: &Option<String>,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Option<Self>> {
        match &abi_file_path {
            None => Ok(None),
            Some(abi_file_path) => {
                #[derive(Deserialize)]
                #[serde(untagged)]
                enum AbiOrNestedAbi {
                    Abi(ethers::abi::Abi),
                    NestedAbi { abi: ethers::abi::Abi },
                }

                let relative_path_buf = PathBuf::from(abi_file_path);
                let path =
                    path_utils::get_config_path_relative_to_root(project_paths, relative_path_buf)
                        .context("Failed to get path to ABI relative to the root of the project")?;
                let mut raw = fs::read_to_string(&path)
                    .context(format!("Failed to read ABI file at \"{}\"", abi_file_path))?;

                // Abi files generated by the hardhat plugin can contain a nested abi field. This code to support that.
                let typed = match serde_json::from_str::<AbiOrNestedAbi>(&raw).context(format!(
                    "Failed to decode ABI file at \"{}\"",
                    abi_file_path
                ))? {
                    AbiOrNestedAbi::Abi(abi) => abi,
                    AbiOrNestedAbi::NestedAbi { abi } => {
                        raw = serde_json::to_string(&abi)
                            .context("Failed serializing ABI from nested field")?;
                        abi
                    }
                };
                Ok(Some(Self {
                    path: Some(path),
                    raw,
                    typed,
                }))
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Contract {
    pub name: ContractNameKey,
    pub handler_path: String,
    pub abi: EvmAbi,
    pub events: Vec<Event>,
}

impl Contract {
    pub fn new(
        name: String,
        handler_path: String,
        events: Vec<Event>,
        abi_from_file: Option<EvmAbi>,
    ) -> Result<Self> {
        let mut events_abi = ethers::abi::Abi::default();

        let mut event_names = Vec::new();
        for event in &events {
            let event_abi = event.get_event();
            events_abi
                .events
                .entry(event_abi.name.clone())
                .or_default()
                .push(event_abi.clone());

            event_names.push(event.name.clone());
        }
        validate_names_valid_rescript(&event_names, "event".to_string())?;

        let events_abi_raw = serde_json::to_string(&events_abi)
            .context("Failed serializing ABI with filtered events")?;

        Ok(Self {
            name,
            events,
            handler_path,
            abi: EvmAbi {
                path: abi_from_file.and_then(|abi| abi.path),
                raw: events_abi_raw,
                typed: events_abi,
            },
        })
    }

    pub fn get_path_to_handler(&self, project_paths: &ParsedProjectPaths) -> Result<PathBuf> {
        let handler_path = path_utils::get_config_path_relative_to_root(
            project_paths,
            PathBuf::from(&self.handler_path),
        )
        .context(format!(
            "Failed creating a relative path to handler in contract {}",
            self.name
        ))?;

        Ok(handler_path)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    event: NormalizedEthAbiEvent,
    pub name: String,
    pub is_async: bool,
}

impl Event {
    fn get_abi_event(event_string: &String, opt_abi: &Option<EvmAbi>) -> Result<EthAbiEvent> {
        let parse_event_sig = |sig: &str| -> Result<EthAbiEvent> {
            match HumanReadableParser::parse_event(sig) {
                Ok(event) => Ok(event),
                Err(err) => Err(anyhow!(
                    "EE103: Unable to parse event signature {} due to the following error: {}. \
                     Please refer to our docs on how to correctly define a human readable ABI.",
                    sig,
                    err
                )),
            }
        };

        let event_string = event_string.trim();

        if event_string.starts_with("event ") {
            parse_event_sig(event_string)
        } else if event_string.contains('(') {
            let signature = format!("event {}", event_string);
            parse_event_sig(&signature)
        } else {
            match opt_abi {
                Some(abi) => {
                    let event = abi
                        .typed
                        .event(event_string)
                        .context(format!("Failed retrieving event {} from abi", event_string))?;
                    Ok(event.clone())
                }
                None => Err(anyhow!("No abi file provided for event {}", event_string)),
            }
        }
    }

    pub fn from_evm_event_config(
        human_cfg_event: EventConfig,
        opt_abi: &Option<EvmAbi>,
    ) -> Result<Self> {
        let event: NormalizedEthAbiEvent =
            Event::get_abi_event(&human_cfg_event.event, opt_abi)?.into();

        Ok(Event {
            name: human_cfg_event.name.unwrap_or(event.0.name.to_owned()),
            event,
            is_async: false,
        })
    }

    fn get_event(&self) -> &EthAbiEvent {
        &self.event.0
    }

    pub fn get_event_inputs(&self) -> Vec<EventParam> {
        self.get_event().inputs.clone()
    }

    pub fn get_event_topic0(&self) -> String {
        ethers::core::utils::hex::encode_prefixed(ethers::utils::keccak256(
            self.get_event().abi_signature().as_bytes(),
        ))
    }

    pub fn get_event_signature(&self) -> String {
        EventConfig::event_string_from_abi_event(&self.event.0)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FieldSelection {
    pub transaction_fields: Vec<human_config::evm::TransactionField>,
    pub block_fields: Vec<human_config::evm::BlockField>,
}

impl FieldSelection {
    fn new(
        transaction_fields: Vec<human_config::evm::TransactionField>,
        block_fields: Vec<human_config::evm::BlockField>,
    ) -> Self {
        Self {
            transaction_fields,
            block_fields,
        }
    }

    pub fn empty() -> Self {
        Self::new(vec![], vec![])
    }

    pub fn try_from_config_field_selection(
        field_selection_cfg: human_config::evm::FieldSelection,
        network_map: &NetworkMap,
    ) -> Result<Self> {
        //validate transaction field selection with rpc
        let has_rpc_sync_src = network_map
            .values()
            .sorted_by_key(|n| n.id)
            .fold(false, |accum, n| {
                accum || matches!(n.sync_source, SyncSource::RpcConfig(_))
            });

        let transaction_fields = field_selection_cfg.transaction_fields.unwrap_or(vec![]);
        let block_fields = field_selection_cfg.block_fields.unwrap_or(vec![]);

        //Validate no duplicates in field selection
        let tx_duplicates: Vec<_> = transaction_fields.iter().duplicates().collect();

        if !tx_duplicates.is_empty() {
            return Err(anyhow!(
                "transaction_fields selection contains the following duplicates: {}",
                tx_duplicates.iter().join(", ")
            ));
        }

        let block_duplicates: Vec<_> = block_fields.iter().duplicates().collect();

        if !block_duplicates.is_empty() {
            return Err(anyhow!(
                "block_fields selection contains the following duplicates: {}",
                block_duplicates.iter().join(", ")
            ));
        }

        if has_rpc_sync_src {
            let invalid_rpc_tx_fields: Vec<_> = transaction_fields
                .iter()
                .cloned()
                .filter(|field| RpcTransactionField::try_from(field.clone()).is_err())
                .collect();

            if !invalid_rpc_tx_fields.is_empty() {
                return Err(anyhow!(
                    "The following selected transaction_fields are unavailable for indexing via \
                     RPC: {}",
                    invalid_rpc_tx_fields.iter().join(", ")
                ));
            }

            let invalid_rpc_block_fields: Vec<_> = block_fields
                .iter()
                .cloned()
                .filter(|field| RpcBlockField::try_from(field.clone()).is_err())
                .collect();

            if !invalid_rpc_block_fields.is_empty() {
                return Err(anyhow!(
                    "The following selected block_fields are unavailable for indexing via RPC: {}",
                    invalid_rpc_block_fields.iter().join(", ")
                ));
            }
        }

        Ok(Self::new(transaction_fields, block_fields))
    }
}

#[derive(Debug, Clone, PartialEq)]
struct NormalizedEthAbiEvent(EthAbiEvent);

impl From<EthAbiEvent> for NormalizedEthAbiEvent {
    fn from(value: EthAbiEvent) -> Self {
        let normalized_unnamed_params: Vec<EventParam> = value
            .inputs
            .into_iter()
            .enumerate()
            .map(|(i, e)| {
                let name = if e.name == "" {
                    format!("_{}", i)
                } else {
                    e.name
                };
                EventParam { name, ..e }
            })
            .collect();
        let event = EthAbiEvent {
            inputs: normalized_unnamed_params,
            ..value
        };

        NormalizedEthAbiEvent(event)
    }
}

#[cfg(test)]
mod test {
    use std::path::PathBuf;

    use super::SystemConfig;
    use crate::{
        config_parsing::{
            self,
            entity_parsing::Schema,
            human_config::evm::HumanConfig as EvmConfig,
            system_config::{Event, SyncConfig, SyncSource},
        },
        project_paths::ParsedProjectPaths,
    };
    use ethers::abi::{Event as EthAbiEvent, EventParam, ParamType};
    use handlebars::Handlebars;
    use serde_json::json;

    #[test]
    fn renders_nested_f32() {
        let hbs = Handlebars::new();

        let rendered_backoff_multiplicative = hbs
            .render_template(
                "{{backoff_multiplicative}}",
                &json!({"backoff_multiplicative": 0.8}),
            )
            .unwrap();
        assert_eq!(&rendered_backoff_multiplicative, "0.8");

        let sync_config = SyncConfig {
            initial_block_interval: 10_000,
            backoff_multiplicative: 0.8,
            acceleration_additive: 2_000,
            interval_ceiling: 10_000,
            backoff_millis: 5000,
            query_timeout_millis: 20_000,
            fallback_stall_timeout: 10_000,
        };

        assert_eq!(sync_config.backoff_multiplicative.to_string(), "0.8");

        let rendered_backoff_multiplicative = hbs
            .render_template(
                "{{backoff_multiplicative}}",
                &json!({"backoff_multiplicative": sync_config.backoff_multiplicative}),
            )
            .unwrap();
        assert_eq!(&rendered_backoff_multiplicative, "0.8");
    }

    #[test]
    fn test_get_contract_abi() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_root = test_dir.as_str();
        let config_dir = "configs/config1.yaml";
        let generated = "generated/";
        let project_paths = ParsedProjectPaths::new(project_root, generated, config_dir)
            .expect("Failed creating parsed_paths");
        let human_config_string = std::fs::read_to_string(&project_paths.config).unwrap();

        let evm_config =
            config_parsing::human_config::deserialize_config_from_yaml(human_config_string)
                .expect("Failed deserializing config");

        let config = SystemConfig::from_evm_config(evm_config, Schema::empty(), &project_paths)
            .expect("Failed parsing config");

        let contract_name = "Contract1".to_string();

        let contract_abi = config
            .get_contract(&contract_name)
            .expect("Failed getting contract")
            .abi
            .typed
            .clone();

        let expected_abi_string = r#"
                [
                {
                    "anonymous": false,
                    "inputs": [
                    {
                        "indexed": false,
                        "name": "id",
                        "type": "uint256"
                    },
                    {
                        "indexed": false,
                        "name": "owner",
                        "type": "address"
                    },
                    {
                        "indexed": false,
                        "name": "displayName",
                        "type": "string"
                    },
                    {
                        "indexed": false,
                        "name": "imageUrl",
                        "type": "string"
                    }
                    ],
                    "name": "NewGravatar",
                    "type": "event"
                },
                {
                    "anonymous": false,
                    "inputs": [
                    {
                        "indexed": false,
                        "name": "id",
                        "type": "uint256"
                    },
                    {
                        "indexed": false,
                        "name": "owner",
                        "type": "address"
                    },
                    {
                        "indexed": false,
                        "name": "displayName",
                        "type": "string"
                    },
                    {
                        "indexed": false,
                        "name": "imageUrl",
                        "type": "string"
                    }
                    ],
                    "name": "UpdatedGravatar",
                    "type": "event"
                }
                ]
    "#;

        let expected_abi: ethers::abi::Abi = serde_json::from_str(expected_abi_string).unwrap();

        assert_eq!(expected_abi, contract_abi);
    }

    #[test]
    fn parse_event_sig_with_event_prefix() {
        let event_string = "event MyEvent(uint256 myArg)".to_string();

        let expected_event = EthAbiEvent {
            name: "MyEvent".to_string(),
            anonymous: false,
            inputs: vec![EventParam {
                indexed: false,
                name: "myArg".to_string(),
                kind: ParamType::Uint(256),
            }],
        };
        assert_eq!(
            Event::get_abi_event(&event_string, &None).unwrap(),
            expected_event
        );
    }

    #[test]
    fn parse_event_sig_without_event_prefix() {
        let event_string = ("MyEvent(uint256 myArg)").to_string();

        let expected_event = EthAbiEvent {
            name: "MyEvent".to_string(),
            anonymous: false,
            inputs: vec![EventParam {
                indexed: false,
                name: "myArg".to_string(),
                kind: ParamType::Uint(256),
            }],
        };
        assert_eq!(
            Event::get_abi_event(&event_string, &None).unwrap(),
            expected_event
        );
    }

    #[test]
    fn parse_event_sig_invalid_panics() {
        let event_string = ("MyEvent(uint69 myArg)").to_string();
        assert_eq!(
            Event::get_abi_event(&event_string, &None)
                .unwrap_err()
                .to_string(),
            "EE103: Unable to parse event signature event MyEvent(uint69 myArg) due to the \
             following error: UnrecognisedToken 14:20 `uint69`. Please refer to our docs on how \
             to correctly define a human readable ABI."
        );
    }

    #[test]
    fn fails_to_parse_event_name_without_abi() {
        let event_string = ("MyEvent").to_string();
        assert_eq!(
            Event::get_abi_event(&event_string, &None)
                .unwrap_err()
                .to_string(),
            "No abi file provided for event MyEvent"
        );
    }

    #[test]
    fn test_valid_urls() {
        let valid_url_1 = "https://eth-mainnet.g.alchemy.com/v2/T7uPV59s7knYTOUardPPX0hq7n7_rQwv";
        let valid_url_2 = "http://api.example.org:8080";
        let valid_url_3 = "https://eth.com/rpc-endpoint";
        let is_valid_url_1 = super::validate_url(valid_url_1);
        let is_valid_url_2 = super::validate_url(valid_url_2);
        let is_valid_url_3 = super::validate_url(valid_url_3);
        assert!(is_valid_url_1);
        assert!(is_valid_url_2);
        assert!(is_valid_url_3);
    }

    #[test]
    fn test_invalid_urls() {
        let invalid_url_missing_slash = "http:/example.com";
        let invalid_url_other_protocol = "ftp://example.com";
        let is_invalid_missing_slash = super::validate_url(invalid_url_missing_slash);
        let is_invalid_other_protocol = super::validate_url(invalid_url_other_protocol);
        assert!(!is_invalid_missing_slash);
        assert!(!is_invalid_other_protocol);
    }

    #[test]
    fn deserializes_contract_config_with_multiple_sync_sources() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/invalid-multiple-sync-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: EvmConfig = serde_yaml::from_str(&file_str).unwrap();

        // Both hypersync and rpc config should be present
        assert!(cfg.networks[0].rpc_config.is_some());
        assert!(cfg.networks[0].hypersync_config.is_some());

        let error = SyncSource::from_evm_network_config(cfg.networks[0].clone(), cfg.event_decoder)
            .unwrap_err();

        assert_eq!(error.to_string(), "EE106: Cannot define both rpc_config and hypersync_config for the same network, please choose only one of them, read more in our docs https://docs.envio.dev/docs/configuration-file");
    }
}
