use std::collections::HashMap;
use std::path::PathBuf;

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    capitalization::{Capitalize, CapitalizedOptions},
    config_parsing::{
        entity_parsing::{Entity, Field, GraphQLEnum, MultiFieldIndex, RescriptType, Schema},
        event_parsing::abi_to_rescript_type,
        human_config::evm::EventDecoder,
        postgres_types,
        system_config::{self, RpcConfig, SystemConfig},
    },
    persisted_state::{PersistedState, PersistedStateJsonString},
    project_paths::{
        handler_paths::HandlerPathsTemplate, path_utils::add_trailing_relative_dot,
        ParsedProjectPaths,
    },
    template_dirs::TemplateDirs,
};
use anyhow::{anyhow, Context, Result};
use ethers::abi::{Event, EventExt};
use pathdiff::diff_paths;
use serde::Deserialize;
use serde::Serialize;

pub trait HasName {
    fn set_name(&mut self, name: CapitalizedOptions);
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventParamTypeTemplate {
    pub param_name: CapitalizedOptions,
    pub type_rescript: String,
    pub type_rescript_schema: String,
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
pub struct GraphQlEnumTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<CapitalizedOptions>,
    pub has_multiple_params: bool,
}

impl GraphQlEnumTypeTemplate {
    fn from_config_gql_enum(gql_enum: &GraphQLEnum) -> Result<Self> {
        let params: Vec<CapitalizedOptions> = gql_enum
            .values
            .iter()
            .map(|value| Ok(value.to_capitalized_options().clone()))
            .collect::<Result<_>>()
            .context(format!(
                "Failed templating gql enum fields of enum: {}",
                gql_enum.name
            ))?;
        let has_multiple_params = params.len() > 1;
        Ok(GraphQlEnumTypeTemplate {
            name: gql_enum.name.to_capitalized_options(),
            params,
            has_multiple_params,
        })
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
    pub object_name: CapitalizedOptions,
    pub is_array: bool,
    pub is_optional: bool,
    pub is_derived_from: bool,
}

impl EntityRelationalTypesTemplate {
    fn from_config_entity(field: &Field, entity: &Entity, schema: &Schema) -> anyhow::Result<Self> {
        let is_array = field.field_type.is_array();

        let relationship_type = if is_array {
            RelationshipTypeTemplate::Array
        } else {
            RelationshipTypeTemplate::Object
        };

        Ok(EntityRelationalTypesTemplate {
            relational_key: field
                .get_relational_key(schema)
                .context(format!(
                    "Failed getting relational key of field {} on entity {}",
                    field.name, entity.name
                ))?
                .to_capitalized_options(),
            object_name: field.name.to_capitalized_options(),
            mapped_entity: entity.name.to_capitalized_options(),
            relationship_type,
            is_optional: field.field_type.is_optional(),
            is_array,
            is_derived_from: field.field_type.is_derived_from(),
        })
    }
}

pub trait HasIsDerivedFrom {
    fn get_is_derived_from(&self) -> bool;
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct FilteredTemplateLists<T: HasIsDerivedFrom> {
    pub all: Vec<T>,
    pub filtered_not_derived_from: Vec<T>,
    pub filtered_is_derived_from: Vec<T>,
}

impl<T: HasIsDerivedFrom + Clone> FilteredTemplateLists<T> {
    pub fn new(unfiltered: Vec<T>) -> Self {
        let filtered_not_derived_from = unfiltered
            .iter()
            .filter(|item| !item.get_is_derived_from())
            .cloned()
            .collect::<Vec<T>>();

        let filtered_is_derived_from = unfiltered
            .iter()
            .filter(|item| item.get_is_derived_from())
            .cloned()
            .collect::<Vec<T>>();

        FilteredTemplateLists {
            all: unfiltered,
            filtered_not_derived_from,
            filtered_is_derived_from,
        }
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityParamTypeTemplate {
    pub field_name: CapitalizedOptions,
    pub type_rescript: RescriptType,
    pub type_rescript_schema: String,
    pub type_pg: String,
    pub is_entity_field: bool,
    ///Used in template to tell whether it is a field looked up from another table or a value in
    ///the table
    pub is_derived_from: bool,
    pub is_indexed_field: bool,
}

impl HasIsDerivedFrom for EntityParamTypeTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.is_derived_from
    }
}

impl EntityParamTypeTemplate {
    fn from_entity_field(field: &Field, entity: &Entity, config: &SystemConfig) -> Result<Self> {
        let type_rescript: RescriptType = field
            .field_type
            .to_rescript_type(&config.schema)
            .context("Failed getting rescript type")?
            .into();

        let schema = &config.schema;

        let is_derived_from = field.field_type.is_derived_from();

        let type_pg = field
            .field_type
            .to_postgres_type(&config.schema)
            .context("Failed getting postgres type")?;

        let is_entity_field = field.field_type.is_entity_field(schema)?;
        let is_indexed_field = field.is_indexed_field(entity);

        Ok(EntityParamTypeTemplate {
            field_name: field.name.to_capitalized_options(),
            type_rescript_schema: type_rescript.to_rescript_schema(),
            type_rescript,
            is_derived_from,
            type_pg,
            is_entity_field,
            is_indexed_field,
        })
    }
}

impl HasIsDerivedFrom for EntityRelationalTypesTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.is_derived_from
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityIndexParamGroup {
    params: Vec<EntityParamTypeTemplate>,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct DerivedFieldTemplate {
    pub field_name: String,
    pub derived_from_entity: String,
    pub derived_from_field: String,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub postgres_fields: Vec<postgres_types::Field>,
    pub composite_indices: Vec<Vec<String>>,
    pub derived_fields: Vec<DerivedFieldTemplate>,
    pub params: Vec<EntityParamTypeTemplate>,
    pub index_groups: Vec<EntityIndexParamGroup>,
    pub relational_params: FilteredTemplateLists<EntityRelationalTypesTemplate>,
    pub filtered_params: FilteredTemplateLists<EntityParamTypeTemplate>,
}

impl EntityRecordTypeTemplate {
    fn from_config_entity(entity: &Entity, config: &SystemConfig) -> Result<Self> {
        // Collect all field templates
        let params: Vec<EntityParamTypeTemplate> = entity
            .get_fields()
            .iter()
            .map(|field| EntityParamTypeTemplate::from_entity_field(field, entity, config))
            .collect::<Result<_>>()
            .context(format!(
                "Failed templating entity fields of entity: {}",
                entity.name
            ))?;

        let mut params_lookup: HashMap<String, EntityParamTypeTemplate> = HashMap::new();

        entity.get_fields().iter().for_each(|field| {
            let entity_param_template =
                EntityParamTypeTemplate::from_entity_field(field, entity, config)
                    .with_context(|| {
                        format!(
                            "Failed templating field '{}' of entity '{}'",
                            field.name, entity.name
                        )
                    })
                    .unwrap();

            params_lookup.insert(field.name.clone(), entity_param_template);
        });

        // Collect relational type templates
        let entity_relational_types_templates = entity
            .get_related_entities(&config.schema)
            .context(format!(
                "Failed getting relational fields of entity: {}",
                entity.name
            ))?
            .iter()
            .map(|(field, related_entity)| {
                EntityRelationalTypesTemplate::from_config_entity(
                    field,
                    related_entity,
                    &config.schema,
                )
            })
            .collect::<Result<Vec<_>>>()
            .context(format!(
                "Failed constructing relational params of entity {}",
                entity.name
            ))?;

        let relational_params = FilteredTemplateLists::new(entity_relational_types_templates);
        let filtered_params = FilteredTemplateLists::new(params.clone());

        let index_groups: Vec<EntityIndexParamGroup> = entity
            .multi_field_indexes
            .iter()
            .filter_map(MultiFieldIndex::get_multi_field_index)
            .map(|multi_field_index| EntityIndexParamGroup {
                params: multi_field_index
                    .get_field_names()
                    .iter()
                    .map(|param_name| {
                        params_lookup
                            .get(param_name)
                            .cloned()
                            .expect("param name should be in lookup")
                    })
                    .collect(),
            })
            .collect();

        let postgres_fields = entity
            .get_fields()
            .iter()
            .map(|gql_field| gql_field.get_postgres_field(&config.schema, entity))
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .filter_map(|opt| opt)
            .collect();

        let derived_fields = entity
            .get_fields()
            .iter()
            .filter_map(|gql_field| gql_field.get_derived_from_field())
            .collect();

        let composite_indices = entity.get_composite_indices();

        Ok(EntityRecordTypeTemplate {
            name: entity.name.to_capitalized_options(),
            postgres_fields,
            derived_fields,
            composite_indices,
            params,
            index_groups,
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
    pub is_async: bool,
    pub topic0: String,
}

impl EventTemplate {
    pub fn from_config_event(
        config_event: &system_config::Event,
        contract_name: &String,
    ) -> Result<Self> {
        let name = config_event
            .get_event()
            .name
            .to_owned()
            .to_capitalized_options();
        let params = config_event
            .get_event()
            .inputs
            .iter()
            .map(|input| {
                let type_rescript = abi_to_rescript_type(&input.into());

                EventParamTypeTemplate {
                    param_name: input.name.to_capitalized_options(),
                    default_value_rescript: type_rescript.get_default_value_rescript(),
                    default_value_non_rescript: type_rescript.get_default_value_non_rescript(),
                    type_rescript: type_rescript.to_string(),
                    type_rescript_schema: type_rescript.to_rescript_schema(),
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

        let topic0 = event_selector(&config_event.get_event());

        Ok(EventTemplate {
            name,
            event_type: EventType::new(
                contract_name.clone(),
                config_event.get_event().name.clone(),
            ),
            params,
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
    ) -> Result<Self> {
        let name = contract.name.to_capitalized_options();
        let handler = HandlerPathsTemplate::from_contract(contract, project_paths)
            .context("Failed building handler paths template")?;
        let codegen_events = contract
            .events
            .iter()
            .map(|event| EventTemplate::from_config_event(event, &contract.name))
            .collect::<Result<_>>()?;
        Ok(ContractTemplate {
            name,
            handler,
            codegen_events,
            abi: contract.abi.raw.clone(),
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

#[derive(Debug, Serialize, PartialEq, Clone)]
struct NetworkTemplate {
    pub id: u64,
    rpc_config: Option<RpcConfig>,
    skar_server_url: Option<ServerUrl>,
    confirmed_block_threshold: i32,
    start_block: i32,
    end_block: Option<i32>,
}

impl NetworkTemplate {
    fn from_config_network(network: &system_config::Network) -> Self {
        NetworkTemplate {
            id: network.id,
            rpc_config: network.get_rpc_config().map(|c| c.into()),
            skar_server_url: network.get_skar_url(),
            confirmed_block_threshold: network.confirmed_block_threshold,
            start_block: network.start_block,
            end_block: network.end_block,
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
    gql_enums: Vec<GraphQlEnumTypeTemplate>,
    chain_configs: Vec<NetworkConfigTemplate>,
    codegen_out_path: String,
    persisted_state: PersistedStateJsonString,
    is_unordered_multichain_mode: bool,
    should_use_hypersync_client_decoder: bool,
    should_rollback_on_reorg: bool,
    should_save_full_history: bool,
    //Used for the package.json reference to handlers in generated
    relative_path_to_root_from_generated: String,
    has_multiple_events: bool,
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
            .map(|cfg_contract| ContractTemplate::from_config_contract(cfg_contract, project_paths))
            .collect::<Result<_>>()
            .context("Failed generating contract template types")?;

        let entities: Vec<EntityRecordTypeTemplate> = cfg
            .get_entities()
            .iter()
            .map(|entity| EntityRecordTypeTemplate::from_config_entity(entity, cfg))
            .collect::<Result<_>>()
            .context("Failed generating entity template types")?;

        let gql_enums: Vec<GraphQlEnumTypeTemplate> = cfg
            .get_gql_enums()
            .iter()
            .map(|gql_enum| GraphQlEnumTypeTemplate::from_config_gql_enum(gql_enum))
            .collect::<Result<_>>()
            .context("Failed generating enum template types")?;

        let chain_configs: Vec<NetworkConfigTemplate> = cfg
            .get_networks()
            .iter()
            .map(|network| NetworkConfigTemplate::from_config_network(network, cfg))
            .collect::<Result<_>>()
            .context("Failed generating chain configs template")?;

        let persisted_state = PersistedState::get_current_state(cfg)
            .context("Failed creating default persisted state")?
            .into();
        let total_number_of_events: usize = codegen_contracts
            .iter()
            .map(|contract| contract.codegen_events.len())
            .sum();
        let has_multiple_events = total_number_of_events > 1;
        let should_use_hypersync_client_decoder =
            cfg.event_decoder == EventDecoder::HypersyncClient;

        //Take the absolute paths of  project root and generated, diff them to get
        //relative path from generated to root and add a trailing dot. So in a default project, if your
        //generated folder is at ./generated. Then this should output ../.
        //OR say for instance its at artifacts/generated. This should output ../../.
        //Generated path on construction has to be inside the root directory
        //Used for the package.json reference to handlers in generated
        let diff_from_current = |path: &PathBuf, base: &PathBuf| -> Result<String> {
            Ok(add_trailing_relative_dot(
                diff_paths(path, base)
                    .ok_or_else(|| anyhow!("Failed to diffing paths {:?} and {:?}", path, base))?,
            )
            .to_str()
            .ok_or_else(|| anyhow!("Failed converting path to str"))?
            .to_string())
        };
        let relative_path_to_root_from_generated =
            diff_from_current(&project_paths.project_root, &project_paths.generated)
                .context("Failed to diff generated to root path")?;

        Ok(ProjectTemplate {
            project_name: cfg.name.clone(),
            codegen_contracts,
            entities,
            gql_enums,
            chain_configs,
            codegen_out_path: gitignore_path_str,
            persisted_state,
            is_unordered_multichain_mode: cfg.unordered_multichain_mode,
            should_use_hypersync_client_decoder,
            should_rollback_on_reorg: cfg.rollback_on_reorg,
            should_save_full_history: cfg.save_full_history,
            //Used for the package.json reference to handlers in generated
            relative_path_to_root_from_generated,
            has_multiple_events,
        })
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        capitalization::Capitalize,
        config_parsing::{
            entity_parsing::RescriptType,
            human_config,
            system_config::{RpcConfig, SystemConfig},
        },
        project_paths::ParsedProjectPaths,
    };
    use pretty_assertions::assert_eq;

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

        let config = SystemConfig::parse_from_human_config(yaml_config, &project_paths)
            .expect("Deserialized yml config should be parseable");

        let project_template = super::ProjectTemplate::from_config(&config, &project_paths)
            .expect("should be able to get project template");
        project_template
    }

    #[test]
    fn chain_configs_parsed_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let rpc_config1 = RpcConfig {
            url: "https://eth.com".to_string(),
            sync_config: system_config::SyncConfig::default(),
        };

        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1),
            skar_server_url: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
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
            project_template.relative_path_to_root_from_generated,
            "../.".to_string()
        );

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

        let rpc_config1 = RpcConfig {
            url: "https://eth.com".to_string(),
            sync_config: system_config::SyncConfig::default(),
        };
        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1.clone()),
            skar_server_url: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let network2 = super::NetworkTemplate {
            id: 2,
            rpc_config: Some(rpc_config1),
            skar_server_url: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
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
            end_block: None,
            confirmed_block_threshold: 200,
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
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let network2 = super::NetworkTemplate {
            id: 5,
            rpc_config: None,
            skar_server_url: Some("https://goerli.hypersync.xyz".to_string()),
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
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
                type_rescript_schema: res_type.to_rescript_schema(),
                default_value_rescript: res_type.get_default_value_rescript(),
                default_value_non_rescript: res_type.get_default_value_non_rescript(),
                is_eth_address: res_type == RESCRIPT_ADDRESS_TYPE,
                is_indexed: false,
                type_rescript_skar_decoded_param: res_type.to_string_decoded_skar(),
            }
        }
    }

    fn make_expected_event_template(topic0: String) -> EventTemplate {
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
            is_async: false,
        }
    }

    #[test]
    fn abi_event_to_record_1() {
        let project_template = get_project_template_helper("config1.yaml");

        let new_gavatar_event_template =
            project_template.codegen_contracts[0].codegen_events[0].clone();

        let expected_event_template =
            make_expected_event_template(new_gavatar_event_template.topic0.clone());

        assert_eq!(expected_event_template, new_gavatar_event_template);
    }

    #[test]
    fn abi_event_to_record_2() {
        let project_template = get_project_template_helper("gravatar-with-required-entities.yaml");

        let new_gavatar_event_template = &project_template.codegen_contracts[0].codegen_events[0];
        let expected_event_template =
            make_expected_event_template(new_gavatar_event_template.topic0.clone());

        assert_eq!(&expected_event_template, new_gavatar_event_template);
    }
}
