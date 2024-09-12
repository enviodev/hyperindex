use std::{collections::HashMap, fmt::Display, path::PathBuf, vec};

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    config_parsing::{
        entity_parsing::{Entity, Field, GraphQLEnum, MultiFieldIndex, Schema},
        event_parsing::{abi_to_rescript_type, EthereumEventParam},
        postgres_types,
        system_config::{
            self, Abi, Ecosystem, EventPayload, HyperfuelConfig, HypersyncConfig, RpcConfig,
            SelectedField, SystemConfig,
        },
    },
    persisted_state::{PersistedState, PersistedStateJsonString},
    project_paths::{
        handler_paths::HandlerPathsTemplate, path_utils::add_trailing_relative_dot,
        ParsedProjectPaths,
    },
    rescript_types::{RescriptRecordField, RescriptTypeExpr, RescriptTypeIdent},
    template_dirs::TemplateDirs,
    utils::text::{Capitalize, CapitalizedOptions, CaseOptions},
};
use anyhow::{anyhow, Context, Result};
use ethers::abi::EventParam;
use pathdiff::diff_paths;
use serde::Serialize;

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventParamTypeTemplate {
    pub res_name: String,
    pub js_name: String,
    pub res_type: String,
    pub default_value_rescript: String,
    pub default_value_non_rescript: String,
    pub is_eth_address: bool,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EventParamTypeTemplate>,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct GraphQlEnumTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<CapitalizedOptions>,
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
        Ok(GraphQlEnumTypeTemplate {
            name: gql_enum.name.to_capitalized_options(),
            params,
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
    pub res_type: RescriptTypeIdent,
    pub res_schema_code: String,
    pub type_pg: String,
    pub is_entity_field: bool,
    ///Used in template to tell whether it is a field looked up from another table or a value in
    ///the table
    pub is_derived_from: bool,
    pub is_indexed_field: bool,
    ///Used to determine if you can run a where
    ///query on this field.
    pub is_queryable_field: bool,
}

impl HasIsDerivedFrom for EntityParamTypeTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.is_derived_from
    }
}

impl EntityParamTypeTemplate {
    fn from_entity_field(field: &Field, entity: &Entity, config: &SystemConfig) -> Result<Self> {
        let res_type: RescriptTypeIdent = field
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
        let is_derived_lookup_field = field.is_derived_lookup_field(entity, schema);

        //Both of these cases have indexes on them and should exist
        let is_queryable_field = is_indexed_field || is_derived_lookup_field;

        Ok(EntityParamTypeTemplate {
            field_name: field.name.to_capitalized_options(),
            res_schema_code: res_type.to_rescript_schema(),
            res_type,
            is_derived_from,
            type_pg,
            is_entity_field,
            is_indexed_field,
            is_queryable_field,
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

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EventParamTypeTemplate>,
    pub sighash: String,
    pub decode_hyper_fuel_data_code: String,
    pub convert_hyper_sync_event_args_code: String,
    pub data_type: String,
    pub data_schema_code: String,
    pub get_topic_selection_code: String,
    pub event_filter_type: String,
}

impl EventTemplate {
    const DECODE_HYPER_FUEL_DATA_CODE: &'static str =
        "(_) => Js.Exn.raiseError(\"HyperFuel decoder not implemented\")";

    const GET_TOPIC_SELECTION_CODE_STUB: &'static str =
        "_ => [LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.\
         fromStringUnsafe])->Utils.unwrapResultExn]";

    const EVENT_FILTER_TYPE_STUB: &'static str = "{}";

    pub fn generate_event_filter_type(params: &Vec<EventParam>) -> String {
        let field_rows = params
            .iter()
            .filter(|param| param.indexed)
            .map(|param| {
                format!(
                    "@as(\"{}\") {}?: SingleOrMultiple.t<{}>",
                    param.name,
                    RescriptRecordField::to_valid_res_name(&param.name),
                    abi_to_rescript_type(&param.into())
                )
            })
            .collect::<Vec<_>>()
            .join(", ");

        format!("{{ {field_rows} }}")
    }

    pub fn generate_get_topic_selection_code(params: &Vec<EventParam>) -> String {
        let indexed_params = params.iter().filter(|param| param.indexed);

        //Prefixed with underscore for cases where it is not used to avoid compiler warnings
        let event_filter_arg = "_eventFilter";

        let topic_filter_calls = indexed_params
            .enumerate()
            .map(|(i, param)| {
                let param = EthereumEventParam::from(param);
                let topic_number = i + 1;
                let param_name = RescriptRecordField::to_valid_res_name(param.name);
                let topic_encoder = param.get_topic_encoder();
                let nested_type_flags = match param.get_nested_type_depth() {
                    depth if depth > 0 => format!("(~nestedArrayDepth={depth})"),
                    _ => "".to_string(),
                };
                format!(
                    "~topic{topic_number}=?{event_filter_arg}.{param_name}->Belt.Option.\
                     map(topicFilters => \
                     topicFilters->SingleOrMultiple.normalizeOrThrow{nested_type_flags}->Belt.\
                     Array.map({topic_encoder})), "
                )
            })
            .collect::<String>();

        format!(
            "(eventFilters) => \
             eventFilters->SingleOrMultiple.normalizeOrThrow->Belt.Array.map({event_filter_arg} \
             => LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.fromStringUnsafe], \
             {topic_filter_calls})->Utils.unwrapResultExn)"
        )
    }

    pub fn generate_convert_hyper_sync_event_args_code(params: &Vec<EventParam>) -> String {
        if params.is_empty() {
            return "(Utils.magic: HyperSyncClient.Decoder.decodedEvent => eventArgs)".to_string();
        }
        let indexed_params = params
            .iter()
            .filter(|param| param.indexed)
            .collect::<Vec<_>>();

        let body_params = params
            .iter()
            .filter(|param| !param.indexed)
            .collect::<Vec<_>>();

        let mut code = String::from(
            "(decodedEvent: HyperSyncClient.Decoder.decodedEvent): eventArgs => {\n      {\n",
        );

        for (index, param) in indexed_params.into_iter().enumerate() {
            code.push_str(&format!(
                "        {}: \
                 decodedEvent.indexed->Js.Array2.unsafe_get({})->HyperSyncClient.Decoder.\
                 toUnderlying->Utils.magic,\n",
                RescriptRecordField::to_valid_res_name(&param.name),
                index
            ));
        }

        for (index, param) in body_params.into_iter().enumerate() {
            code.push_str(&format!(
                "        {}: \
                 decodedEvent.body->Js.Array2.unsafe_get({})->HyperSyncClient.Decoder.\
                 toUnderlying->Utils.magic,\n",
                RescriptRecordField::to_valid_res_name(&param.name),
                index
            ));
        }

        code.push_str("      }\n    }");

        code
    }

    pub fn from_config_event(config_event: &system_config::Event) -> Result<Self> {
        let name = config_event.name.to_capitalized_options();
        match &config_event.payload {
            EventPayload::Params(params) => {
                let template_params = params
                    .iter()
                    .map(|input| {
                        let res_type = abi_to_rescript_type(&input.into());
                        let js_name = input.name.to_string();
                        EventParamTypeTemplate {
                            res_name: RescriptRecordField::to_valid_res_name(&js_name),
                            js_name,
                            default_value_rescript: res_type.get_default_value_rescript(),
                            default_value_non_rescript: res_type.get_default_value_non_rescript(),
                            res_type: res_type.to_string(),
                            is_eth_address: res_type == RescriptTypeIdent::Address,
                        }
                    })
                    .collect::<Vec<_>>();

                let data_type_expr = if params.is_empty() {
                    RescriptTypeExpr::Identifier(RescriptTypeIdent::Unit)
                } else {
                    RescriptTypeExpr::Record(
                        params
                            .iter()
                            .map(|p| {
                                RescriptRecordField::new(
                                    p.name.to_string(),
                                    abi_to_rescript_type(&p.into()),
                                )
                            })
                            .collect(),
                    )
                };

                Ok(EventTemplate {
                    name,
                    params: template_params,
                    data_type: data_type_expr.to_string(),
                    data_schema_code: data_type_expr.to_rescript_schema(&"eventArgs".to_string()),
                    sighash: config_event.sighash.to_string(),
                    convert_hyper_sync_event_args_code:
                        Self::generate_convert_hyper_sync_event_args_code(params),
                    decode_hyper_fuel_data_code: Self::DECODE_HYPER_FUEL_DATA_CODE.to_string(),
                    event_filter_type: Self::generate_event_filter_type(params),
                    get_topic_selection_code: Self::generate_get_topic_selection_code(params),
                })
            }
            EventPayload::Data(type_indent) => {
                // TODO: A special decoder for Unit type_indent
                // let data_decoder = match config_event.log.logged_type.rescript_type_decl.type_expr {
                //     rescript_types::RescriptTypeExpr::Identifier(
                //         rescript_types::RescriptTypeIdent::Unit,
                //     ) => "Fuel.Receipt.unitDecoder".to_string(),
                //     _ => format!(
                //         "Fuel.Receipt.getLogDataDecoder(~abi, ~logId=\"{}\")",
                //         config_event.sighash
                //     ),
                // };
                let decode_hyper_fuel_data_code = format!(
                    "Fuel.Receipt.getLogDataDecoder(~abi, ~logId=\"{}\")",
                    config_event.sighash
                );
                Ok(EventTemplate {
                    name,
                    params: vec![],
                    data_type: type_indent.to_string(),
                    data_schema_code: type_indent.to_rescript_schema(),
                    sighash: config_event.sighash.to_string(),
                    convert_hyper_sync_event_args_code: "(Utils.magic: \
                                                     HyperSyncClient.Decoder.decodedEvent => \
                                                     eventArgs)"
                        .to_string(),
                    decode_hyper_fuel_data_code,
                    event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
                    get_topic_selection_code: Self::GET_TOPIC_SELECTION_CODE_STUB.to_string(),
                })
            }
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct ContractTemplate {
    pub name: CapitalizedOptions,
    pub codegen_events: Vec<EventTemplate>,
    pub chain_ids: Vec<u64>,
    pub module_code: String,
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
            .map(|event| EventTemplate::from_config_event(event))
            .collect::<Result<_>>()?;

        let module_code = match &contract.abi {
            Abi::Evm(abi) => {
                let signatures = abi.get_event_signatures();

                format!(
                    r#"let abi = Ethers.makeAbi((%raw(`{}`): Js.Json.t))
let eventSignatures = [{}]"#,
                    abi.raw,
                    signatures
                        .iter()
                        .map(|w| format!("\"{}\"", w))
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            }
            Abi::Fuel(abi) => {
                let all_abi_type_declarations =
                    abi.to_rescript_type_decl_multi().context(format!(
                        "Failed getting types from the '{}' contract ABI",
                        contract.name
                    ))?;

                format!(
                    "let abi = Fuel.transpileAbi(%raw(`require(\"../../{}\")`))\n{}\n{}",
                    // If we decide to inline the abi, instead of using require
                    // we need to remember that abi might contain ` and we should escape it
                    abi.path_buf.to_string_lossy(),
                    all_abi_type_declarations.to_string(),
                    all_abi_type_declarations.to_rescript_schema()
                )
            }
        };

        let chain_ids = contract.get_chain_ids(config);

        Ok(ContractTemplate {
            name,
            handler,
            codegen_events,
            chain_ids,
            module_code,
        })
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct PerNetworkContractEventTemplate {
    pub name: CapitalizedOptions,
}

impl PerNetworkContractEventTemplate {
    fn new(event_name: String) -> Self {
        PerNetworkContractEventTemplate {
            name: event_name.to_capitalized_options(),
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
            .events
            .iter()
            .map(|event| PerNetworkContractEventTemplate::new(event.name.clone()))
            .collect();

        Ok(PerNetworkContractTemplate {
            name: network_contract.name.to_capitalized_options(),
            addresses: network_contract.addresses.clone(),
            events,
        })
    }
}

type EthAddress = String;

#[derive(Debug, Serialize, PartialEq, Clone)]
struct NetworkTemplate {
    pub id: u64,
    rpc_config: Option<RpcConfig>,
    hypersync_config: Option<HypersyncConfig>,
    hyperfuel_config: Option<HyperfuelConfig>,
    confirmed_block_threshold: i32,
    start_block: i32,
    end_block: Option<i32>,
}

impl NetworkTemplate {
    fn from_config_network(network: &system_config::Network) -> Self {
        NetworkTemplate {
            id: network.id,
            rpc_config: match &network.sync_source {
                system_config::SyncSource::RpcConfig(rpc_config) => Some(rpc_config.clone()),
                _ => None,
            },
            hypersync_config: match &network.sync_source {
                system_config::SyncSource::HypersyncConfig(hypersync_config) => {
                    Some(hypersync_config.clone())
                }
                _ => None,
            },
            hyperfuel_config: match &network.sync_source {
                system_config::SyncSource::HyperfuelConfig(hyperfuel_config) => {
                    Some(hyperfuel_config.clone())
                }
                _ => None,
            },
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
struct FieldSelection {
    transaction_fields: Vec<SelectedFieldTemplate>,
    block_fields: Vec<SelectedFieldTemplate>,
    block_type: String,
    block_schema: String,
    block_raw_events_type: String,
    block_raw_events_schema: String,
}

impl FieldSelection {
    fn new(
        transaction_fields: Vec<SelectedFieldTemplate>,
        block_fields: &Vec<SelectedField>,
    ) -> Self {
        let mut block_field_templates = vec![];
        let mut all_block_fields = vec![];
        let mut raw_events_block_fields = vec![];

        for field in block_fields.iter().cloned() {
            let name: CaseOptions = field.name.into();
            let is_optional = field.data_type.is_option();

            block_field_templates.push(SelectedFieldTemplate {
                name: name.clone(),
                res_schema_code: field.data_type.to_rescript_schema(),
                default_value_rescript: field.data_type.get_default_value_rescript(),
                res_type: field.data_type.clone(),
                is_optional,
            });

            let record_field = RescriptRecordField::new(name.camel, field.data_type);
            all_block_fields.push(record_field.clone());
            if field.skip_raw_events {
                raw_events_block_fields.push(record_field);
            }
        }
        let block_expr = RescriptTypeExpr::Record(all_block_fields);
        let block_raw_events_expr = RescriptTypeExpr::Record(raw_events_block_fields);
        Self {
            transaction_fields,
            block_fields: block_field_templates,
            block_type: block_expr.to_string(),
            block_schema: block_expr.to_rescript_schema(&"t".to_string()),
            block_raw_events_schema: block_raw_events_expr
                .to_rescript_schema(&"rawEventFields".to_string()),
            block_raw_events_type: block_raw_events_expr.to_string(),
        }
    }

    fn from_config_field_selection(cfg: &system_config::FieldSelection) -> Self {
        Self::new(
            cfg.transaction_fields
                .iter()
                .cloned()
                .map(|field| SelectedFieldTemplate::from(field))
                .collect(),
            &cfg.block_fields,
        )
    }
}

#[derive(Serialize)]
struct SelectedFieldTemplate {
    name: CaseOptions,
    res_type: RescriptTypeIdent,
    res_schema_code: String,
    default_value_rescript: String,
    is_optional: bool,
}

impl SelectedFieldTemplate {
    fn from<T>(value: T) -> Self
    where
        T: Display + Into<RescriptTypeIdent>,
    {
        let name = value.to_string().into();
        let res_type: RescriptTypeIdent = value.into();
        let is_optional = res_type.is_option();
        Self {
            name,
            res_schema_code: res_type.to_rescript_schema(),
            default_value_rescript: res_type.get_default_value_rescript(),
            res_type,
            is_optional,
        }
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
    should_rollback_on_reorg: bool,
    should_save_full_history: bool,
    enable_raw_events: bool,
    has_multiple_events: bool,
    field_selection: FieldSelection,
    is_evm_ecosystem: bool,
    is_fuel_ecosystem: bool,
    //Used for the package.json reference to handlers in generated
    relative_path_to_root_from_generated: String,
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

        let field_selection = FieldSelection::from_config_field_selection(&cfg.field_selection);

        Ok(ProjectTemplate {
            project_name: cfg.name.clone(),
            codegen_contracts,
            entities,
            gql_enums,
            chain_configs,
            codegen_out_path: gitignore_path_str,
            persisted_state,
            is_unordered_multichain_mode: cfg.unordered_multichain_mode,
            should_rollback_on_reorg: cfg.rollback_on_reorg,
            should_save_full_history: cfg.save_full_history,
            enable_raw_events: cfg.enable_raw_events,
            has_multiple_events,
            field_selection,
            is_evm_ecosystem: cfg.ecosystem == Ecosystem::Evm,
            is_fuel_ecosystem: cfg.ecosystem == Ecosystem::Fuel,
            //Used for the package.json reference to handlers in generated
            relative_path_to_root_from_generated,
        })
    }
}

#[cfg(test)]
mod test {
    use std::vec;

    use super::*;
    use crate::{
        config_parsing::system_config::{RpcConfig, SystemConfig},
        project_paths::ParsedProjectPaths,
        utils::text::Capitalize,
    };
    use pretty_assertions::assert_eq;

    fn get_per_contract_events_vec_helper(
        event_names: Vec<&str>,
    ) -> Vec<PerNetworkContractEventTemplate> {
        event_names
            .into_iter()
            .map(|n| PerNetworkContractEventTemplate::new(n.to_string()))
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

        let config = SystemConfig::parse_from_project_files(&project_paths)
            .expect("Deserialized yml config should be parseable");

        let project_template = super::ProjectTemplate::from_config(&config, &project_paths)
            .expect("should be able to get project template");
        project_template
    }

    #[test]
    fn chain_configs_parsed_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let rpc_config1 = RpcConfig {
            urls: vec!["https://eth.com".to_string()],
            sync_config: system_config::SyncConfig::default(),
        };

        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1),
            hypersync_config: None,
            hyperfuel_config: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);
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
            urls: vec!["https://eth.com".to_string()],
            sync_config: system_config::SyncConfig::default(),
        };
        let network1 = super::NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1.clone()),
            hypersync_config: None,
            hyperfuel_config: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let rpc_config2 = RpcConfig {
            urls: vec![
                "https://eth.com".to_string(),
                // Should support fallback urls
                "https://eth.com/fallback".to_string(),
            ],
            sync_config: system_config::SyncConfig::default(),
        };
        let network2 = super::NetworkTemplate {
            id: 2,
            rpc_config: Some(rpc_config2),
            hypersync_config: None,
            hyperfuel_config: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);
        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);
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
            hypersync_config: Some(HypersyncConfig {
                endpoint_url: "https://1.hypersync.xyz".to_string(),
                is_client_decoder: true,
            }),
            hyperfuel_config: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);

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
            hypersync_config: Some(HypersyncConfig {
                endpoint_url: "https://myskar.com".to_string(),
                is_client_decoder: true,
            }),
            hyperfuel_config: None,
            start_block: 0,
            end_block: None,
            confirmed_block_threshold: 200,
        };

        let network2 = super::NetworkTemplate {
            id: 5,
            rpc_config: None,
            hypersync_config: Some(HypersyncConfig {
                endpoint_url: "https://5.hypersync.xyz".to_string(),
                is_client_decoder: true,
            }),
            hyperfuel_config: None,
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

    const RESCRIPT_BIG_INT_TYPE: RescriptTypeIdent = RescriptTypeIdent::BigInt;
    const RESCRIPT_ADDRESS_TYPE: RescriptTypeIdent = RescriptTypeIdent::Address;
    const RESCRIPT_STRING_TYPE: RescriptTypeIdent = RescriptTypeIdent::String;

    impl EventParamTypeTemplate {
        fn new(name: &str, res_type: RescriptTypeIdent) -> Self {
            let js_name = name.to_string();
            Self {
                res_name: RescriptRecordField::to_valid_res_name(&js_name),
                js_name,
                res_type: res_type.to_string(),
                default_value_rescript: res_type.get_default_value_rescript(),
                default_value_non_rescript: res_type.get_default_value_non_rescript(),
                is_eth_address: res_type == RESCRIPT_ADDRESS_TYPE,
            }
        }
    }

    fn make_expected_event_template(sighash: String) -> EventTemplate {
        let params = vec![
            EventParamTypeTemplate::new("id", RESCRIPT_BIG_INT_TYPE),
            EventParamTypeTemplate::new("owner", RESCRIPT_ADDRESS_TYPE),
            EventParamTypeTemplate::new("displayName", RESCRIPT_STRING_TYPE),
            EventParamTypeTemplate::new("imageUrl", RESCRIPT_STRING_TYPE),
        ];

        EventTemplate {
            name: "NewGravatar".to_string().to_capitalized_options(),
            sighash,
            params,
            data_type: "{id: bigint, owner: Address.t, displayName: string, imageUrl: string}"
                .to_string(),
            convert_hyper_sync_event_args_code: "(decodedEvent: \
                                                 HyperSyncClient.Decoder.decodedEvent): eventArgs \
                                                 => {\n      {\n        id: \
                                                 decodedEvent.body->Js.Array2.\
                                                 unsafe_get(0)->HyperSyncClient.Decoder.\
                                                 toUnderlying->Utils.magic,\n        owner: \
                                                 decodedEvent.body->Js.Array2.\
                                                 unsafe_get(1)->HyperSyncClient.Decoder.\
                                                 toUnderlying->Utils.magic,\n        displayName: \
                                                 decodedEvent.body->Js.Array2.\
                                                 unsafe_get(2)->HyperSyncClient.Decoder.\
                                                 toUnderlying->Utils.magic,\n        imageUrl: \
                                                 decodedEvent.body->Js.Array2.\
                                                 unsafe_get(3)->HyperSyncClient.Decoder.\
                                                 toUnderlying->Utils.magic,\n      }\n    }"
                .to_string(),
            decode_hyper_fuel_data_code: "(_) => Js.Exn.raiseError(\"HyperFuel decoder not \
                                          implemented\")"
                .to_string(),
            data_schema_code:
                "S.object((s): eventArgs => {id: s.field(\"id\", BigInt.schema), owner: \
                               s.field(\"owner\", Address.schema), displayName: \
                               s.field(\"displayName\", S.string), imageUrl: \
                               s.field(\"imageUrl\", S.string)})"
                    .to_string(),
            get_topic_selection_code: "(eventFilters) => \
                                       eventFilters->SingleOrMultiple.normalizeOrThrow->Belt.\
                                       Array.map(_eventFilter => \
                                       LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.\
                                       Hex.fromStringUnsafe], )->Utils.unwrapResultExn)"
                .to_string(),
            event_filter_type: "{  }".to_string(),
        }
    }

    #[test]
    fn event_template_with_empty_params() {
        let event_template = EventTemplate::from_config_event(&system_config::Event {
            name: "NewGravatar".to_string(),
            payload: system_config::EventPayload::Params(vec![]),
            sighash: "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
                .to_string(),
        })
        .unwrap();

        assert_eq!(
            event_template,
            EventTemplate {
                name: "NewGravatar".to_string().to_capitalized_options(),
                sighash: "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
                    .to_string(),
                params: vec![],
                data_type: "unit".to_string(),
                convert_hyper_sync_event_args_code: "(Utils.magic: \
                                                     HyperSyncClient.Decoder.decodedEvent => \
                                                     eventArgs)"
                    .to_string(),
                decode_hyper_fuel_data_code: "(_) => Js.Exn.raiseError(\"HyperFuel decoder not \
                                              implemented\")"
                    .to_string(),
                data_schema_code: "S.literal(%raw(`null`))->S.variant(_ => ())".to_string(),
                get_topic_selection_code: "(eventFilters) => \
                                           eventFilters->SingleOrMultiple.normalizeOrThrow->Belt.\
                                           Array.map(_eventFilter => \
                                           LogSelection.\
                                           makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.\
                                           fromStringUnsafe], )->Utils.unwrapResultExn)"
                    .to_string(),
                event_filter_type: "{  }".to_string(),
            }
        );
    }

    #[test]
    fn abi_event_to_record_1() {
        let project_template = get_project_template_helper("config1.yaml");

        let new_gavatar_event_template =
            project_template.codegen_contracts[0].codegen_events[0].clone();

        let expected_event_template =
            make_expected_event_template(new_gavatar_event_template.sighash.clone());

        assert_eq!(expected_event_template, new_gavatar_event_template);
    }

    #[test]
    fn abi_event_to_record_2() {
        let project_template = get_project_template_helper("gravatar-with-required-entities.yaml");

        let new_gavatar_event_template = &project_template.codegen_contracts[0].codegen_events[0];
        let expected_event_template =
            make_expected_event_template(new_gavatar_event_template.sighash.clone());

        assert_eq!(&expected_event_template, new_gavatar_event_template);
    }
}
