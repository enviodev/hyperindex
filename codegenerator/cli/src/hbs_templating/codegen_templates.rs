use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    capitalization::{Capitalize, CapitalizedOptions},
    config_parsing::{
        entity_parsing::{Entity, Field, RescriptType},
        event_parsing::abi_to_rescript_type,
        human_config::{self, SyncConfigUnstable, SYNC_CONFIG_DEFAULT},
        system_config::{self, SystemConfig},
    },
    persisted_state::{PersistedState, PersistedStateJsonString},
    project_paths::{handler_paths::HandlerPathsTemplate, ParsedProjectPaths},
    template_dirs::TemplateDirs,
};
use anyhow::{anyhow, Context, Result};
use ethers::abi::{Event, EventExt};
use serde::Deserialize;
use serde::Serialize;

pub trait HasName {
    fn set_name(&mut self, name: CapitalizedOptions);
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventParamTypeTemplate {
    pub param_name: CapitalizedOptions,
    pub type_rescript: String,
    pub default_value_rescript: String,
    pub default_value_non_rescript: String,
    pub is_eth_address: bool,
    pub type_rescript_skar_decoded_param: String,
    pub is_indexed: bool,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EventParamTypeTemplate>,
}
impl HasName for EventRecordTypeTemplate {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
#[serde(rename_all = "lowercase")]
pub enum RelationshipTypeTemplate {
    Object,
    Array,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRelationalTypesTemplate {
    pub relational_key: CapitalizedOptions,
    pub mapped_entity: CapitalizedOptions,
    pub relationship_type: RelationshipTypeTemplate,
    pub is_array: bool,
    pub is_optional: bool,
    pub derived_from_field_key: Option<String>,
}

impl EntityRelationalTypesTemplate {
    fn from_config_entity(field: &Field, entity: &Entity) -> Self {
        let is_array = field.field_type.is_array();
        let relationship_type = if is_array {
            RelationshipTypeTemplate::Array
        } else {
            RelationshipTypeTemplate::Object
        };

        EntityRelationalTypesTemplate {
            relational_key: field.name.to_capitalized_options(),
            mapped_entity: entity.name.to_capitalized_options(),
            relationship_type,
            is_optional: field.field_type.is_optional(),
            is_array,
            derived_from_field_key: field.derived_from_field.clone(),
        }
    }
}

pub trait HasIsDerivedFrom {
    fn get_is_derived_from(&self) -> bool;
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct FilteredTemplateLists<T: HasIsDerivedFrom> {
    pub all: Vec<T>,
    pub filtered_not_derived_from: Vec<T>,
}

impl<T: HasIsDerivedFrom + Clone> FilteredTemplateLists<T> {
    pub fn new(unfiltered: Vec<T>) -> Self {
        let filtered_not_derived_from = unfiltered
            .iter()
            .filter(|item| !item.get_is_derived_from())
            .cloned()
            .collect::<Vec<T>>();

        FilteredTemplateLists {
            all: unfiltered,
            filtered_not_derived_from,
        }
    }

    #[cfg(test)]
    pub fn empty() -> Self {
        FilteredTemplateLists {
            all: Vec::new(),
            filtered_not_derived_from: Vec::new(),
        }
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityParamTypeTemplate {
    pub field_name: CapitalizedOptions,
    pub type_rescript: RescriptType,
    pub type_pg: String,
    pub maybe_entity_name: Option<CapitalizedOptions>,
    ///Used in template to tell whether it is a field looked up from another table or a value in
    ///the table
    pub is_derived_from: bool,
}

impl HasIsDerivedFrom for EntityParamTypeTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.is_derived_from
    }
}

impl EntityParamTypeTemplate {
    fn from_entity_field(field: &Field, config: &SystemConfig) -> Result<Self> {
        let entity_names_set = config.get_entity_names_set();
        let type_rescript = field
            .field_type
            .to_rescript_type(&entity_names_set)
            .context("Failed getting rescript type")?
            .into();

        let is_derived_from = field.derived_from_field.is_some();

        let type_pg = field
            .field_type
            .to_postgres_type(&entity_names_set, is_derived_from)
            .context("Failed getting postgres type")?;

        let maybe_entity_name = field
            .field_type
            .get_maybe_entity_name()
            .map(|s| s.to_capitalized_options());

        Ok(EntityParamTypeTemplate {
            field_name: field.name.to_capitalized_options(),
            type_rescript,
            is_derived_from,
            type_pg,
            maybe_entity_name,
        })
    }
}

impl HasIsDerivedFrom for EntityRelationalTypesTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.derived_from_field_key.is_some()
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EntityParamTypeTemplate>,
    pub relational_params: FilteredTemplateLists<EntityRelationalTypesTemplate>,
    pub filtered_params: FilteredTemplateLists<EntityParamTypeTemplate>,
}

impl EntityRecordTypeTemplate {
    fn from_config_entity(entity: &Entity, config: &SystemConfig) -> Result<Self> {
        let params: Vec<EntityParamTypeTemplate> = entity
            .fields
            .iter()
            .map(|field| EntityParamTypeTemplate::from_entity_field(field, config))
            .collect::<Result<_>>()
            .context(format!(
                "Failed templating entity fields of entity: {}",
                entity.name
            ))?;

        let entity_relational_types_templates = entity
            .get_related_entities(config.get_entity_map())
            .context(format!(
                "Failed getting relational fields of entity: {}",
                entity.name
            ))?
            .iter()
            .map(|(field, related_entity)| {
                EntityRelationalTypesTemplate::from_config_entity(field, related_entity)
            })
            .collect();

        let relational_params = FilteredTemplateLists::new(entity_relational_types_templates);

        let filtered_params = FilteredTemplateLists::new(params.clone());

        Ok(EntityRecordTypeTemplate {
            name: entity.name.to_capitalized_options(),
            params,
            relational_params,
            filtered_params,
        })
    }
}

impl HasName for EntityRecordTypeTemplate {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct RequiredEntityEntityFieldTemplate {
    pub field_name: CapitalizedOptions,
    pub type_name: CapitalizedOptions,
    pub is_optional: bool,
    pub is_array: bool,
    pub is_derived_from: bool,
}

impl RequiredEntityEntityFieldTemplate {
    fn from_config_entity(field: &Field, entity: &Entity) -> Self {
        RequiredEntityEntityFieldTemplate {
            field_name: field.name.to_capitalized_options(),
            type_name: entity.name.to_capitalized_options(),
            is_optional: field.field_type.is_optional(),
            is_array: field.field_type.is_array(),
            is_derived_from: field.derived_from_field.is_some(),
        }
    }
}

impl HasIsDerivedFrom for RequiredEntityEntityFieldTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.is_derived_from
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct RequiredEntityTemplate {
    pub name: CapitalizedOptions,
    pub labels: Option<Vec<String>>,
    pub array_labels: Option<Vec<String>>,
    pub entity_fields_of_required_entity: FilteredTemplateLists<RequiredEntityEntityFieldTemplate>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct EventType {
    //Contract name and event name joined with a '_'
    //Always capitalized
    //Used as a unique per-contract event variant in rescript
    full: String,
    //Contract name and event name joined with a '_' truncated to  63 char max
    //Always capitalized
    //for char limit in postgres for enums
    truncated_for_pg_enum_limit: String,
}

impl EventType {
    pub fn new(contract_name: String, event_name: String) -> Self {
        let full = contract_name.capitalize() + "_" + &event_name;
        const MAX_CHAR_LIMIT_FOR_PG_ENUM: usize = 63;
        let truncated_for_pg_enum_limit = full
            .chars()
            .enumerate()
            .filter(|(i, _x)| i < &MAX_CHAR_LIMIT_FOR_PG_ENUM)
            .map(|(_i, x)| x)
            .collect();

        EventType {
            full,
            truncated_for_pg_enum_limit,
        }
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventTemplate {
    pub name: CapitalizedOptions,
    //Used for the eventType variant in Types.res and the truncated version in postgres
    pub event_type: EventType,
    pub params: Vec<EventParamTypeTemplate>,
    pub indexed_params: Vec<EventParamTypeTemplate>,
    pub body_params: Vec<EventParamTypeTemplate>,
    pub required_entities: Vec<RequiredEntityTemplate>,
    pub is_async: bool,
    pub topic0: String,
}

impl EventTemplate {
    pub fn from_config_event(
        config_event: &system_config::Event,
        config: &SystemConfig,
        contract_name: &String,
    ) -> Result<Self> {
        let name = config_event.event.name.to_owned().to_capitalized_options();
        let params = config_event
            .event
            .inputs
            .iter()
            .enumerate()
            .map(|(index, input)| {
                let key: String = if input.name.is_empty() {
                    format!("_{}", index)
                } else {
                    input.name.to_string()
                };
                let type_rescript = abi_to_rescript_type(&input.into());

                EventParamTypeTemplate {
                    param_name: key.to_capitalized_options(),
                    default_value_rescript: type_rescript.get_default_value_rescript(),
                    default_value_non_rescript: type_rescript.get_default_value_non_rescript(),
                    type_rescript: type_rescript.to_string(),
                    is_eth_address: type_rescript == RescriptType::Address,
                    is_indexed: input.indexed,
                    type_rescript_skar_decoded_param: type_rescript.to_string_decoded_skar(),
                }
            })
            .collect::<Vec<_>>();

        let indexed_params = params
            .iter()
            .filter(|param| param.is_indexed)
            .cloned()
            .collect();

        let body_params = params
            .iter()
            .filter(|param| !param.is_indexed)
            .cloned()
            .collect();

        let all_entity_names = config.get_entity_names();

        let required_entities = config_event
            .required_entities
            .iter()
            .map(|required_entity| {
                let entity = config.get_entity(&required_entity.name)
                    .cloned()
                    .ok_or_else(|| {
                        // Look to see if there is a key that is similar in the keys of `entity_fields_of_required_entity_map`.
                        // It is similar if the lower case of the key is the same as the lowercase
                        // of the required_entity.name.
                        let required_entity_name_lower = required_entity.name.to_lowercase();
                        // NOTE: this is a very primative similarity metric. We could use something
                        // like the Levenshtein distance or something more 'fuzzy'. The https://docs.rs/strsim/latest/strsim/
                        // crate looks great for this!
                        let key_that_is_similar = all_entity_names.iter()
                            .find(|&key| key.to_lowercase() == required_entity_name_lower);

                        match key_that_is_similar {
                            Some(similar_key) =>
                                anyhow!("Required entity with name {} not found in Schema - did you mean '{}'? Note, capitalization matters.", &required_entity.name, similar_key),
                            None => anyhow!("Required entity with name {} not found in Schema. Note, capitalization matters.", &required_entity.name)
                        }
                    }).context("Validating 'requiredEntity' fields in config.")?;

                let required_entity_entity_field_templates = entity.get_related_entities(config.get_entity_map()).context(format!("Failed retrieving related entities of required entity {}", entity.name))?
                    .iter().map(|(field, related_entity)| RequiredEntityEntityFieldTemplate::from_config_entity(field, related_entity)).collect();

                let entity_fields_of_required_entity =
                    FilteredTemplateLists::new(required_entity_entity_field_templates);

                Ok(RequiredEntityTemplate {
                    name: required_entity.name.to_capitalized_options(),
                    labels: required_entity.labels.clone(),
                    array_labels: required_entity.array_labels.clone(),
                    entity_fields_of_required_entity,
                })
            })
            .collect::<Result<_>>()?;

        let topic0 = event_selector(&config_event.event);

        Ok(EventTemplate {
            name,
            event_type: EventType::new(contract_name.clone(), config_event.event.name.clone()),
            params,
            required_entities,
            is_async: config_event.is_async,
            body_params,
            indexed_params,
            topic0,
        })
    }
}

fn event_selector(event: &Event) -> String {
    ethers::core::utils::hex::encode_prefixed(ethers::utils::keccak256(
        event.abi_signature().as_bytes(),
    ))
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct ContractTemplate {
    pub name: CapitalizedOptions,
    pub codegen_events: Vec<EventTemplate>,
    pub abi: StringifiedAbi,
    pub handler: HandlerPathsTemplate,
}

impl ContractTemplate {
    fn from_config_contract(
        contract: &system_config::Contract,
        project_paths: &ParsedProjectPaths,
        config: &SystemConfig,
    ) -> Result<Self> {
        let name = contract.name.to_capitalized_options();
        let handler = HandlerPathsTemplate::from_contract(contract, project_paths)
            .context("Failed building handler paths template")?;
        let codegen_events = contract
            .events
            .iter()
            .map(|event| EventTemplate::from_config_event(event, config, &contract.name))
            .collect::<Result<_>>()?;
        let abi = contract
            .get_stringified_abi()
            .context(format!("Failed getting abi of contract {}", contract.name))?;

        Ok(ContractTemplate {
            name,
            handler,
            codegen_events,
            abi,
        })
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct PerNetworkContractEventTemplate {
    pub name: CapitalizedOptions,
    //Used for the eventType variant in Types.res and the truncated version in postgres
    pub event_type: EventType,
}

impl PerNetworkContractEventTemplate {
    fn new(event_name: String, contract_name: String) -> Self {
        PerNetworkContractEventTemplate {
            name: event_name.to_capitalized_options(),
            event_type: EventType::new(contract_name, event_name),
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct PerNetworkContractTemplate {
    name: CapitalizedOptions,
    addresses: Vec<EthAddress>,
    events: Vec<PerNetworkContractEventTemplate>,
}

impl PerNetworkContractTemplate {
    fn from_config_network_contract(
        network_contract: &system_config::NetworkContract,
        config: &SystemConfig,
    ) -> anyhow::Result<Self> {
        let contract = network_contract
            .get_contract(config)
            .context("Failed getting contract")?;

        let events = contract
            .get_event_names()
            .into_iter()
            .map(|n| PerNetworkContractEventTemplate::new(n, contract.name.clone()))
            .collect();

        Ok(PerNetworkContractTemplate {
            name: network_contract.name.to_capitalized_options(),
            addresses: network_contract.addresses.clone(),
            events,
        })
    }
}

type EthAddress = String;
type StringifiedAbi = String;
type ServerUrl = String;

///Same as Rpc config defined in human config but no optional values
#[derive(Debug, Serialize, PartialEq, Clone)]
#[allow(non_snake_case)] //Stop compiler warning for the double underscore in unstable__sync_config
struct RpcConfig {
    pub url: String,
    pub unstable__sync_config: SyncConfigUnstable,
}

impl From<human_config::RpcConfig> for RpcConfig {
    fn from(value: human_config::RpcConfig) -> Self {
        Self {
            url: value.url,
            unstable__sync_config: value
                .unstable__sync_config
                .unwrap_or_else(|| SYNC_CONFIG_DEFAULT),
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
struct NetworkTemplate {
    pub id: u64,
    rpc_config: Option<RpcConfig>,
    skar_server_url: Option<ServerUrl>,
    start_block: i32,
}

impl NetworkTemplate {
    fn from_config_network(network: &system_config::Network) -> Self {
        NetworkTemplate {
            id: network.id,
            rpc_config: network.get_rpc_config().map(|c| c.into()),
            skar_server_url: network.get_skar_url(),
            start_block: network.start_block,
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct NetworkConfigTemplate {
    network_config: NetworkTemplate,
    codegen_contracts: Vec<PerNetworkContractTemplate>,
}

impl NetworkConfigTemplate {
    fn from_config_network(
        network: &system_config::Network,
        config: &SystemConfig,
    ) -> Result<Self> {
        let network_config = NetworkTemplate::from_config_network(network);
        let codegen_contracts = network
            .contracts
            .iter()
            .map(|network_contract| {
                PerNetworkContractTemplate::from_config_network_contract(network_contract, config)
            })
            .collect::<Result<_>>()
            .context("Failed mapping network contracts")?;

        Ok(NetworkConfigTemplate {
            network_config,
            codegen_contracts,
        })
    }
}

#[derive(Serialize)]
pub struct ProjectTemplate {
    project_name: String,
    codegen_contracts: Vec<ContractTemplate>,
    entities: Vec<EntityRecordTypeTemplate>,
    chain_configs: Vec<NetworkConfigTemplate>,
    codegen_out_path: String,
    persisted_state: PersistedStateJsonString,
}

impl ProjectTemplate {
    pub fn generate_templates(&self, project_paths: &ParsedProjectPaths) -> Result<()> {
        let template_dirs = TemplateDirs::new();
        let dynamic_codegen_dir = template_dirs
            .get_codegen_dynamic_dir()
            .context("Failed getting dynamic codegen dir")?;

        let hbs =
            HandleBarsDirGenerator::new(&dynamic_codegen_dir, &self, &project_paths.generated);
        hbs.generate_hbs_templates()?;

        Ok(())
    }

    pub fn from_config(cfg: &SystemConfig, project_paths: &ParsedProjectPaths) -> Result<Self> {
        //TODO: make this a method in path handlers
        let gitignore_generated_path = project_paths.generated.join("*");
        let gitignore_path_str = gitignore_generated_path
            .to_str()
            .ok_or_else(|| anyhow!("invalid codegen path"))?
            .to_string();

        let codegen_contracts: Vec<ContractTemplate> = cfg
            .get_contracts()
            .iter()
            .map(|cfg_contract| {
                ContractTemplate::from_config_contract(cfg_contract, project_paths, cfg)
            })
            .collect::<Result<_>>()
            .context("Failed generating contract template types")?;

        let entities: Vec<EntityRecordTypeTemplate> = cfg
            .get_entities()
            .iter()
            .map(|entity| EntityRecordTypeTemplate::from_config_entity(entity, cfg))
            .collect::<Result<_>>()
            .context("Failed generating entity template types")?;

        let chain_configs: Vec<NetworkConfigTemplate> = cfg
            .get_networks()
            .iter()
            .map(|network| NetworkConfigTemplate::from_config_network(network, cfg))
            .collect::<Result<_>>()
            .context("Failed generating chain configs template")?;

        let persisted_state = PersistedState::get_current_state(cfg)
            .context("Failed creating default persisted state")?
            .into();

        Ok(ProjectTemplate {
            project_name: cfg.name.clone(),
            codegen_contracts,
            entities,
            chain_configs,
            codegen_out_path: gitignore_path_str,
            persisted_state,
        })
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        capitalization::Capitalize,
        config_parsing::{
            entity_parsing::RescriptType, human_config, human_config::RpcConfig,
            system_config::SystemConfig,
        },
        project_paths::ParsedProjectPaths,
    };

    fn get_per_contract_events_vec_helper(
        event_names: Vec<&str>,
        contract_name: &str,
    ) -> Vec<PerNetworkContractEventTemplate> {
        event_names
            .into_iter()
            .map(|n| PerNetworkContractEventTemplate::new(n.to_string(), contract_name.to_string()))
            .collect()
    }

    fn get_test_path_string_helper() -> String {
        format!("{}/test", env!("CARGO_MANIFEST_DIR"))
    }

    fn get_project_template_helper(configs_file_name: &str) -> super::ProjectTemplate {
        let project_root = get_test_path_string_helper();
        let config = format!("configs/{}", configs_file_name);
        let generated = "generated/";
        let project_paths =
            ParsedProjectPaths::new(&project_root, generated, &config).expect("Parsed paths");

        let yaml_config = human_config::deserialize_config_from_yaml(&project_paths.config)
            .expect("Config should be deserializeable");

        let config = SystemConfig::parse_from_human_config(&yaml_config, &project_paths)
            .expect("Deserialized yml config should be parseable");

        let project_template = super::ProjectTemplate::from_config(&config, &project_paths)
            .expect("should be able to get project template");
        project_template
    }

    #[test]
    fn check_config_with_multiple_sync_sources() {
        let project_template = get_project_template_helper("invalid-multiple-sync-config6.yaml");

        assert!(
            project_template.chain_configs[0]
                .network_config
                .rpc_config
                .is_none(),
            "rpc config should have been none since it was defined second"
        );

        assert!(
            project_template.chain_configs[0]
                .network_config
                .skar_server_url
                .is_some(),
            "skar config should be some since it was defined first"
        );
    }

    #[test]
    fn chain_configs_parsed_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let rpc_config1 = RpcConfig::new("https://eth.com").into();

        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1),
            skar_server_url: None,
            start_block: 0,
        };

        let events =
            get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"], "Contract1");
        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
            network_config: network1,
            codegen_contracts: vec![contract1],
        };

        let expected_chain_configs = vec![chain_config_1];

        let project_template = get_project_template_helper("config1.yaml");

        assert_eq!(
            expected_chain_configs[0].network_config,
            project_template.chain_configs[0].network_config
        );
        assert_eq!(expected_chain_configs, project_template.chain_configs,);
    }

    #[tokio::test]
    async fn chain_configs_parsed_case_2() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let address2 = String::from("0x1E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let rpc_config1: super::RpcConfig = RpcConfig::new("https://eth.com").into();

        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1.clone()),
            skar_server_url: None,
            start_block: 0,
        };

        let network2 = super::NetworkTemplate {
            id: 2,
            rpc_config: Some(rpc_config1),
            skar_server_url: None,
            start_block: 0,
        };

        let events =
            get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"], "Contract1");
        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
        };

        let events =
            get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"], "Contract2");
        let contract2 = super::PerNetworkContractTemplate {
            name: String::from("Contract2").to_capitalized_options(),
            addresses: vec![address2.clone()],
            events,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
            network_config: network1,
            codegen_contracts: vec![contract1],
        };
        let chain_config_2 = super::NetworkConfigTemplate {
            network_config: network2,
            codegen_contracts: vec![contract2],
        };

        let expected_chain_configs = vec![chain_config_1, chain_config_2];

        let project_template = get_project_template_helper("config2.yaml");

        assert_eq!(expected_chain_configs, project_template.chain_configs);
    }

    #[test]
    fn convert_to_chain_configs_case_3() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: None,
            skar_server_url: Some("https://eth.hypersync.xyz".to_string()),
            start_block: 0,
        };

        let events =
            get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"], "Contract1");

        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
            network_config: network1,
            codegen_contracts: vec![contract1],
        };

        let expected_chain_configs = vec![chain_config_1];

        let project_template = get_project_template_helper("config3.yaml");

        assert_eq!(expected_chain_configs, project_template.chain_configs);
    }

    #[test]
    fn convert_to_chain_configs_case_4() {
        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: None,
            skar_server_url: Some("https://myskar.com".to_string()),
            start_block: 0,
        };

        let network2 = super::NetworkTemplate {
            id: 5,
            rpc_config: None,
            skar_server_url: Some("https://goerli.hypersync.xyz".to_string()),
            start_block: 0,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
            network_config: network1,
            codegen_contracts: vec![],
        };

        let chain_config_2 = super::NetworkConfigTemplate {
            network_config: network2,
            codegen_contracts: vec![],
        };

        let expected_chain_configs = vec![chain_config_1, chain_config_2];
        let project_template = get_project_template_helper("config4.yaml");

        assert_eq!(expected_chain_configs, project_template.chain_configs);
    }

    #[test]
    #[should_panic]
    fn convert_to_chain_configs_case_5() {
        //Bad chain ID without sync config should panic
        get_project_template_helper("config5.yaml");
    }

    const RESCRIPT_BIG_INT_TYPE: RescriptType = RescriptType::BigInt;
    const RESCRIPT_ADDRESS_TYPE: RescriptType = RescriptType::Address;
    const RESCRIPT_STRING_TYPE: RescriptType = RescriptType::String;

    impl EventParamTypeTemplate {
        fn new(param_name: &str, res_type: RescriptType) -> Self {
            Self {
                param_name: param_name.to_string().to_capitalized_options(),
                type_rescript: res_type.to_string(),
                default_value_rescript: res_type.get_default_value_rescript(),
                default_value_non_rescript: res_type.get_default_value_non_rescript(),
                is_eth_address: res_type == RESCRIPT_ADDRESS_TYPE,
                is_indexed: false,
                type_rescript_skar_decoded_param: res_type.to_string_decoded_skar(),
            }
        }
    }

    fn make_expected_event_template(
        topic0: String,
        required_entity: RequiredEntityTemplate,
    ) -> EventTemplate {
        let params = vec![
            EventParamTypeTemplate::new("id", RESCRIPT_BIG_INT_TYPE),
            EventParamTypeTemplate::new("owner", RESCRIPT_ADDRESS_TYPE),
            EventParamTypeTemplate::new("displayName", RESCRIPT_STRING_TYPE),
            EventParamTypeTemplate::new("imageUrl", RESCRIPT_STRING_TYPE),
        ];

        EventTemplate {
            name: "NewGravatar".to_string().to_capitalized_options(),
            event_type: EventType {
                full: "Contract1_NewGravatar".to_string(),
                truncated_for_pg_enum_limit: "Contract1_NewGravatar".to_string(),
            },
            topic0,
            body_params: params.clone(),
            params,
            indexed_params: vec![],
            required_entities: vec![required_entity],
            is_async: false,
        }
    }

    #[test]
    fn abi_event_to_record_1() {
        let project_template = get_project_template_helper("config1.yaml");

        let new_gavatar_event_template =
            project_template.codegen_contracts[0].codegen_events[0].clone();

        let expected_event_template = make_expected_event_template(
            new_gavatar_event_template.topic0.clone(),
            RequiredEntityTemplate {
                name: "EmptyEntity".to_string().to_capitalized_options(),
                labels: None,
                array_labels: None,
                entity_fields_of_required_entity: FilteredTemplateLists {
                    all: vec![],
                    filtered_not_derived_from: vec![],
                },
            },
        );

        assert_eq!(expected_event_template, new_gavatar_event_template);
    }

    #[test]
    fn abi_event_to_record_2() {
        let project_template = get_project_template_helper("gravatar-with-required-entities.yaml");

        let new_gavatar_event_template = &project_template.codegen_contracts[0].codegen_events[0];
        let expected_event_template = make_expected_event_template(
            new_gavatar_event_template.topic0.clone(),
            RequiredEntityTemplate {
                name: String::from("Gravatar").to_capitalized_options(),
                labels: Some(vec![String::from("gravatarWithChanges")]),
                array_labels: None,
                entity_fields_of_required_entity: FilteredTemplateLists::empty(),
            },
        );

        assert_eq!(&expected_event_template, new_gavatar_event_template);
    }
}
