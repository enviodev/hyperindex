use super::{
    entity_parsing::{Entity, GraphQLEnum, Schema},
    human_config::{self, HumanConfig, HypersyncConfig, RpcConfig, SyncSourceConfig},
};
use crate::{
    project_paths::{handler_paths::DEFAULT_SCHEMA_PATH, path_utils, ParsedProjectPaths},
    utils::unique_hashmap,
};
use anyhow::{anyhow, Context, Result};
use ethers::abi::ethabi::Event as EthAbiEvent;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
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

pub struct SystemConfig {
    pub name: String,
    pub schema_path: String,
    pub parsed_project_paths: ParsedProjectPaths,
    pub networks: NetworkMap,
    pub contracts: ContractMap,
    pub unordered_multichain_mode: bool,
    pub schema: Schema,
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

    pub fn get_entity_names_set(&self) -> HashSet<EntityKey> {
        self.schema.entities.keys().cloned().collect()
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
            .filter_map(|c| c.get_path_to_abi_file(&self.parsed_project_paths))
            .collect::<Result<HashSet<_>>>()?
            .into_iter()
            .collect::<Vec<_>>();

        filtered_unique_abi_files.sort();

        Ok(filtered_unique_abi_files)
    }
}

//Parse methods for system config
impl SystemConfig {
    pub fn parse_from_human_cfg_with_schema(
        human_cfg: &HumanConfig,
        schema: Schema,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Self> {
        let mut networks: NetworkMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        //Add all global contracts
        if let Some(global_contracts) = &human_cfg.contracts {
            for g_contract in global_contracts {
                let opt_abi = g_contract.parse_abi(project_paths)?;
                let events = g_contract
                    .events
                    .iter()
                    .cloned()
                    .map(|e| Event::try_from_config_event(e, &opt_abi, &schema))
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

        for network in &human_cfg.networks {
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
                            .map(|e| Event::try_from_config_event(e, &opt_abi, &schema))
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

        Ok(SystemConfig {
            name: human_cfg.name.clone(),
            parsed_project_paths: project_paths.clone(),
            schema_path: human_cfg
                .schema
                .clone()
                .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
            networks,
            contracts,
            unordered_multichain_mode: human_cfg.unordered_multichain_mode.unwrap_or(false),
            schema,
        })
    }

    pub fn parse_from_human_config(
        human_cfg: &HumanConfig,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Self> {
        let relative_schema_path_from_config = human_cfg
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

        Self::parse_from_human_cfg_with_schema(human_cfg, schema, project_paths)
    }
}

type ServerUrl = String;

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Network {
    pub id: u64,
    pub sync_source: SyncSourceConfig,
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
            SyncSourceConfig::HypersyncConfig(HypersyncConfig { endpoint_url }) => {
                Some(endpoint_url.clone())
            }
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
    pub fn get_contract<'a>(&self, config: &'a SystemConfig) -> Result<&'a Contract> {
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
    pub fn get_abi(&self) -> ethers::abi::Contract {
        let mut events_abi = ethers::abi::Contract::default();

        for event_container in &self.events {
            events_abi
                .events
                .entry(event_container.event.name.clone())
                .or_default()
                .push(event_container.event.clone());
        }

        events_abi
    }

    pub fn get_stringified_abi(&self) -> Result<String> {
        let events_abi = self.get_abi();

        let stringified_abi =
            serde_json::to_string(&events_abi).context("Failed serializing abi")?;

        Ok(stringified_abi)
    }

    pub fn get_event_names(&self) -> Vec<String> {
        self.events.iter().map(|e| e.event.name.clone()).collect()
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

    pub fn get_path_to_abi_file(
        &self,
        project_paths: &ParsedProjectPaths,
    ) -> Option<Result<PathBuf>> {
        self.abi_file_path.as_ref().map(|abi_path| {
            let abi_rel_path = path_utils::get_config_path_relative_to_root(
                project_paths,
                PathBuf::from(abi_path),
            )
            .context(format!(
                "Failed creating a relative path to abi in contract {}",
                self.name
            ))?;

            Ok(abi_rel_path)
        })
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct Event {
    pub event: EthAbiEvent,
    pub required_entities: Vec<human_config::RequiredEntity>,
    pub is_async: bool,
}

impl Event {
    pub fn try_from_config_event(
        human_cfg_event: human_config::ConfigEvent,
        opt_abi: &Option<ethers::abi::Contract>,
        schema: &Schema,
    ) -> Result<Self> {
        let event = human_cfg_event.event.get_abi_event(opt_abi)?;

        let required_entities = human_cfg_event.required_entities.unwrap_or_else(|| {
            // If no required entities are specified, we assume all entities are required
            schema
                .entities
                .values()
                .cloned()
                .map(|entity| human_config::RequiredEntity {
                    name: entity.name,
                    labels: None,
                    array_labels: None,
                })
                .collect()
        });
        let is_async = human_cfg_event.is_async.unwrap_or_else(|| false);

        Ok(Event {
            event,
            required_entities,
            is_async,
        })
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
struct RequiredEntity {
    pub name: String,
    pub labels: Vec<String>,
    pub array_labels: Vec<String>,
}
impl From<human_config::RequiredEntity> for RequiredEntity {
    fn from(r: human_config::RequiredEntity) -> Self {
        RequiredEntity {
            name: r.name,
            labels: r.labels.unwrap_or_else(|| vec![]),
            array_labels: r.array_labels.unwrap_or_else(|| vec![]),
        }
    }
}

#[cfg(test)]
mod test {
    use super::SystemConfig;
    use crate::{
        config_parsing::{self, entity_parsing::Schema},
        project_paths::ParsedProjectPaths,
    };

    #[test]
    fn test_get_contract_abi() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_root = test_dir.as_str();
        let config_dir = "configs/config1.yaml";
        let generated = "generated/";
        let project_paths = ParsedProjectPaths::new(project_root, generated, config_dir)
            .expect("Failed creating parsed_paths");

        let human_cfg =
            config_parsing::human_config::deserialize_config_from_yaml(&project_paths.config)
                .expect("Failed deserializing config");

        let config = SystemConfig::parse_from_human_cfg_with_schema(
            &human_cfg,
            Schema::empty(),
            &project_paths,
        )
        .expect("Failed parsing config");

        let contract_name = "Contract1".to_string();

        let contract_abi = config
            .get_contract(&contract_name)
            .expect("Failed getting contract")
            .get_abi();

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

        let expected_abi: ethers::abi::Contract =
            serde_json::from_str(expected_abi_string).unwrap();

        assert_eq!(expected_abi, contract_abi);
    }
}
