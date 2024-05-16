use super::{
    chain_helpers::get_confirmed_block_threshold_from_id,
    entity_parsing::{Entity, GraphQLEnum, Schema},
    human_config::{self, EventDecoder, HumanConfig, HypersyncConfig, RpcConfig, SyncSourceConfig},
    validation::validate_names_not_reserved,
};
use crate::{
    project_paths::{handler_paths::DEFAULT_SCHEMA_PATH, path_utils, ParsedProjectPaths},
    utils::unique_hashmap,
};
use anyhow::{anyhow, Context, Result};
use ethers::abi::{ethabi::Event as EthAbiEvent, EventParam, HumanReadableParser};

use itertools::Itertools;
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

#[derive(Debug)]
pub struct SystemConfig {
    pub name: String,
    pub schema_path: String,
    pub parsed_project_paths: ParsedProjectPaths,
    pub networks: NetworkMap,
    pub contracts: ContractMap,
    pub unordered_multichain_mode: bool,
    pub event_decoder: EventDecoder,
    pub rollback_on_reorg: bool,
    pub save_full_history: bool,
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
                let abi_from_file = EvmAbi::from_file(&g_contract.abi_file_path, project_paths)?;

                let events = g_contract
                    .events
                    .iter()
                    .cloned()
                    .map(|e| Event::try_from_config_event(e, &abi_from_file, &schema))
                    .collect::<Result<Vec<_>>>()
                    .context(format!(
                        "Failed parsing abi types for events in global contract {}",
                        g_contract.name,
                    ))?;

                let contract = Contract::new(
                    g_contract.name.clone(),
                    g_contract.handler.clone(),
                    events,
                    abi_from_file,
                )
                .context("Failed parsing globally defined contract")?;

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
                        let abi_from_file =
                            EvmAbi::from_file(&l_contract.abi_file_path, project_paths)?;

                        let events = l_contract
                            .events
                            .iter()
                            .cloned()
                            .map(|e| Event::try_from_config_event(e, &abi_from_file, &schema))
                            .collect::<Result<Vec<_>>>()?;

                        let contract =
                            Contract::new(contract.name, l_contract.handler, events, abi_from_file)
                                .context(format!(
                            "Failed parsing locally defined network contract at network id {}",
                            network.id
                        ))?;

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
            event_decoder: human_cfg
                .event_decoder
                .clone()
                .unwrap_or(EventDecoder::HypersyncClient),
            rollback_on_reorg: human_cfg.rollback_on_reorg.unwrap_or(false),
            save_full_history: human_cfg.save_full_history.unwrap_or(false),
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

#[derive(Debug, Clone, PartialEq)]
pub struct Network {
    pub id: u64,
    pub sync_source: SyncSourceConfig,
    pub start_block: i32,
    pub end_block: Option<i32>,
    pub confirmed_block_threshold: i32,
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
    typed: ethers::abi::Contract,
}

impl EvmAbi {
    pub fn from_file(
        abi_file_path: &Option<String>,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Option<Self>> {
        match &abi_file_path {
            None => Ok(None),
            Some(abi_file_path) => {
                let relative_path_buf = PathBuf::from(abi_file_path);
                let path =
                    path_utils::get_config_path_relative_to_root(project_paths, relative_path_buf)
                        .context("Failed to get path to ABI relative to the root of the project")?;
                let raw = fs::read_to_string(&path)
                    .context(format!("Failed to read ABI file at \"{}\"", abi_file_path))?;
                let decoding_context_error =
                    format!("Failed to decode ABI file at \"{}\"", abi_file_path);
                let typed: ethers::abi::Abi =
                    serde_json::from_str(&raw).context(decoding_context_error.clone())?;
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
        name: ContractNameKey,
        handler_path: String,
        events: Vec<Event>,
        abi_from_file: Option<EvmAbi>,
    ) -> Result<Self> {
        let mut events_abi = ethers::abi::Contract::default();

        let mut event_names = Vec::new();
        let mut entity_and_label_names = Vec::new();
        for event in &events {
            events_abi
                .events
                .entry(event.get_event().name.clone())
                .or_default()
                .push(event.get_event().clone());

            event_names.push(event.event.0.name.clone());

            for entity in &event.required_entities {
                entity_and_label_names.push(entity.name.clone());
                if let Some(labels) = &entity.labels {
                    entity_and_label_names.extend(labels.clone());
                }
                if let Some(array_labels) = &entity.array_labels {
                    entity_and_label_names.extend(array_labels.clone());
                }
            }
            // Checking that entity names do not include any reserved words
            validate_names_not_reserved(&entity_and_label_names, "Required Entities".to_string())?;
        }
        // Checking that event names do not include any reserved words
        validate_names_not_reserved(&event_names, "Events".to_string())?;

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

    pub fn get_event_names(&self) -> Vec<String> {
        self.events
            .iter()
            .map(|e| e.get_event().name.clone())
            .collect()
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
    pub required_entities: Vec<human_config::RequiredEntity>,
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

    pub fn try_from_config_event(
        human_cfg_event: human_config::ConfigEvent,
        opt_abi: &Option<EvmAbi>,
        schema: &Schema,
    ) -> Result<Self> {
        let event = Event::get_abi_event(&human_cfg_event.event, opt_abi)?.into();

        let required_entities = human_cfg_event.required_entities.unwrap_or_else(|| {
            // If no required entities are specified, we assume all entities are required
            schema
                .entities
                .values()
                .sorted_by_key(|v| &v.name)
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

    pub fn get_event(&self) -> &EthAbiEvent {
        &self.event.0
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

#[derive(Debug, Clone, PartialEq)]
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
        config_parsing::{self, entity_parsing::Schema, system_config::Event},
        project_paths::ParsedProjectPaths,
    };
    use ethers::abi::{Event as EthAbiEvent, EventParam, ParamType};

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

        let expected_abi: ethers::abi::Contract =
            serde_json::from_str(expected_abi_string).unwrap();

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
            "EE103: Unable to parse event signature event MyEvent(uint69 myArg) due to the following error: UnrecognisedToken 14:20 `uint69`. Please refer to our docs on how to correctly define a human readable ABI."
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
}
