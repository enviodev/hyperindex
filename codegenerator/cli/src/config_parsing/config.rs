use anyhow::{anyhow, Context, Result};
use ethers::abi::ethabi::Event as EthAbiEvent;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
};

use crate::{
    project_paths::{handler_paths::DEFAULT_SCHEMA_PATH, path_utils, ProjectPaths},
    utils::unique_hashmap,
};

use super::{
    entity_parsing::{Entity, Schema},
    Config as YamlConfig, HypersyncConfig, HypersyncWorkerType, RpcConfig, SyncSourceConfig,
};

type ContractNameKey = String;
type NetworkIdKey = u64;
type EntityKey = String;
type NetworkMap = HashMap<NetworkIdKey, Network>;
type ContractMap = HashMap<ContractNameKey, Contract>;
pub type EntityMap = HashMap<EntityKey, Entity>;

pub struct Config {
    pub name: String,
    pub schema_path: String,
    networks: NetworkMap,
    contracts: ContractMap,
    entities: EntityMap,
}

impl Config {
    pub fn get_contracts(&self) -> Vec<&Contract> {
        let mut contracts: Vec<&Contract> = self.contracts.values().collect();
        contracts.sort_by_key(|c| c.name.clone());
        contracts
    }

    pub fn get_contract(&self, name: &ContractNameKey) -> Option<&Contract> {
        self.contracts.get(name)
    }

    pub fn get_entity_names(&self) -> Vec<EntityKey> {
        let mut entity_names: Vec<EntityKey> =
            self.entities.values().map(|v| v.name.clone()).collect();
        //For consistent templating in alphabetical order
        entity_names.sort();
        entity_names
    }

    pub fn get_entity(&self, entity_name: &EntityKey) -> Option<&Entity> {
        self.entities.get(entity_name)
    }

    pub fn get_entities(&self) -> Vec<&Entity> {
        let mut entities: Vec<&Entity> = self.entities.values().collect();
        //For consistent templating in alphabetical order
        entities.sort_by_key(|e| e.name.clone());
        entities
    }

    pub fn get_entity_map(&self) -> &EntityMap {
        &self.entities
    }

    pub fn get_entity_names_set(&self) -> HashSet<EntityKey> {
        self.entities.keys().cloned().collect()
    }

    pub fn get_networks(&self) -> Vec<&Network> {
        let mut networks: Vec<&Network> = self.networks.values().collect();
        networks.sort_by_key(|n| n.id);
        networks
    }
}

impl Config {
    pub fn parse_from_yaml_with_schema(
        yaml_cfg: &YamlConfig,
        schema: Schema,
        project_paths: &ProjectPaths,
    ) -> Result<Self> {
        let mut networks: NetworkMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        //Add all global contracts
        if let Some(global_contracts) = &yaml_cfg.contracts {
            for g_contract in global_contracts {
                let opt_abi = g_contract.parse_abi(project_paths)?;
                let events = g_contract
                    .events
                    .iter()
                    .cloned()
                    .map(|e| Event::try_from_config_event(e, &opt_abi))
                    .collect::<Result<Vec<_>>>()
                    .context(format!(
                        "Failed parsing abi types for events in global contract {}",
                        g_contract.name,
                    ))?;

                let contract = Contract {
                    name: g_contract.name.clone(),
                    events,
                    handler_path: g_contract.handler.clone(),
                    abi_file_path: g_contract.abi_file_path.clone(),
                };

                //Check if contract exists
                unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                    .context("Failed inserting globally defined contract")?;
            }
        }

        for network in &yaml_cfg.networks {
            for contract in network.contracts.clone() {
                //Add values for local contract
                match contract.local_contract_config {
                    Some(l_contract) => {
                        //If there is a local contract, parse it and insert into contracts
                        let opt_abi = l_contract.parse_abi(project_paths)?;

                        let events = l_contract
                            .events
                            .iter()
                            .cloned()
                            .map(|e| Event::try_from_config_event(e, &opt_abi))
                            .collect::<Result<Vec<_>>>()?;

                        let contract = Contract {
                            name: contract.name,
                            events,
                            handler_path: l_contract.handler,
                            abi_file_path: l_contract.abi_file_path,
                        };

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context(format!(
                            "Failed inserting locally defined network contract at network id {}",
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

            let sync_source = network.get_sync_source_with_default().context(
                "EE106: Undefined network config, please provide rpc_config, \
                    read more in our docs https://docs.envio.dev/docs/configuration-file",
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
                id: network.id as u64,
                start_block: network.start_block,
                sync_source,
                contracts,
            };

            unique_hashmap::try_insert(&mut networks, network.id.clone(), network)
                .context("Failed inserting network at networks map")?;
        }

        let mut entities = HashMap::new();

        for entity in schema.entities {
            unique_hashmap::try_insert(&mut entities, entity.name.clone(), entity)
                .context("Failed inserting entity at entities map")?;
        }

        Ok(Config {
            name: yaml_cfg.name.clone(),
            schema_path: yaml_cfg
                .schema
                .clone()
                .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
            networks,
            contracts,
            entities,
        })
    }

    pub fn parse_from_yaml_config(
        yaml_cfg: &YamlConfig,
        project_paths: &ProjectPaths,
    ) -> Result<Self> {
        let relative_schema_path_from_config = yaml_cfg
            .schema
            .clone()
            .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string());

        let schema_path = path_utils::get_config_path_relative_to_root(
            project_paths,
            PathBuf::from(relative_schema_path_from_config.clone()),
        )
        .context("Failed creating a relative path to schema")?;

        let schema =
            Schema::parse_from_file(&schema_path).context("Parsing schema file for config")?;

        Self::parse_from_yaml_with_schema(yaml_cfg, schema, project_paths)
    }
}

type ServerUrl = String;

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Network {
    pub id: u64,
    sync_source: SyncSourceConfig,
    pub start_block: i32,
    pub contracts: Vec<NetworkContract>,
}

impl Network {
    pub fn get_rpc_config(&self) -> Option<RpcConfig> {
        match &self.sync_source {
            SyncSourceConfig::RpcConfig(cfg) => Some(cfg.clone()),
            _ => None,
        }
    }

    pub fn get_skar_url(&self) -> Option<ServerUrl> {
        match &self.sync_source {
            SyncSourceConfig::HypersyncConfig(HypersyncConfig {
                worker_type: HypersyncWorkerType::Skar,
                endpoint_url,
            }) => Some(endpoint_url.clone()),
            _ => None,
        }
    }

    pub fn get_eth_archive_url(&self) -> Option<ServerUrl> {
        match &self.sync_source {
            SyncSourceConfig::HypersyncConfig(HypersyncConfig {
                worker_type: HypersyncWorkerType::EthArchive,
                endpoint_url,
            }) => Some(endpoint_url.clone()),
            _ => None,
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct NetworkContract {
    pub name: ContractNameKey,
    pub addresses: Vec<String>,
}

impl NetworkContract {
    pub fn get_contract<'a>(&self, config: &'a Config) -> Result<&'a Contract> {
        config.get_contract(&self.name).ok_or_else(|| {
            anyhow!(
                "Unexpected, network contract {} should have a contract in mapping",
                self.name
            )
        })
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Contract {
    pub name: ContractNameKey,
    pub handler_path: String,
    pub abi_file_path: Option<String>,
    pub events: Vec<Event>,
}

impl Contract {
    pub fn get_stringified_abi(&self) -> Result<String> {
        let mut events_abi = ethers::abi::Contract::default();

        for event_container in &self.events {
            events_abi
                .events
                .entry(event_container.event.name.clone())
                .or_default()
                .push(event_container.event.clone());
        }

        let stringified_abi =
            serde_json::to_string(&events_abi).context("Failed serializing abi")?;

        Ok(stringified_abi)
    }

    pub fn get_event_names(&self) -> Vec<String> {
        self.events.iter().map(|e| e.event.name.clone()).collect()
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Event {
    pub event: EthAbiEvent,
    pub required_entities: Vec<super::RequiredEntity>,
}

impl Event {
    fn try_from_config_event(
        yaml_cfg_event: super::ConfigEvent,
        opt_abi: &Option<ethers::abi::Contract>,
    ) -> Result<Self> {
        let event = yaml_cfg_event.event.get_abi_event(opt_abi)?;
        let required_entities = yaml_cfg_event.required_entities.unwrap_or_else(|| vec![]);

        Ok(Event {
            event,
            required_entities,
        })
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct RequiredEntity {
    pub name: String,
    pub labels: Vec<String>,
    pub array_labels: Vec<String>,
}
impl From<super::RequiredEntity> for RequiredEntity {
    fn from(r: super::RequiredEntity) -> Self {
        RequiredEntity {
            name: r.name,
            labels: r.labels.unwrap_or_else(|| vec![]),
            array_labels: r.array_labels.unwrap_or_else(|| vec![]),
        }
    }
}
