use std::{collections::HashMap, collections::HashSet, path::PathBuf, vec};

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    config_parsing::{
        entity_parsing::{Entity, Field, GraphQLEnum, MultiFieldIndex, Schema},
        event_parsing::{abi_to_rescript_type, EthereumEventParam},
        postgres_types,
        system_config::{
            self, Abi, Ecosystem, EventKind, FuelEventKind, HyperfuelConfig, HypersyncConfig,
            RpcConfig, SelectedField, SystemConfig,
        },
    },
    persisted_state::{PersistedState, PersistedStateJsonString},
    project_paths::{
        handler_paths::HandlerPathsTemplate, path_utils::add_trailing_relative_dot,
        ParsedProjectPaths,
    },
    rescript_types::{
        RescriptRecordField, RescriptSchemaMode, RescriptTypeExpr, RescriptTypeIdent,
    },
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

        let is_entity_field = field.field_type.is_entity_field(schema)?;
        let is_indexed_field = field.is_indexed_field(entity);
        let is_derived_lookup_field = field.is_derived_lookup_field(entity, schema);

        //Both of these cases have indexes on them and should exist
        let is_queryable_field = is_indexed_field || is_derived_lookup_field;

        Ok(EntityParamTypeTemplate {
            field_name: field.name.to_capitalized_options(),
            res_schema_code: res_type.to_rescript_schema(&RescriptSchemaMode::ForDb),
            res_type,
            is_derived_from,
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

#[derive(Debug, PartialEq, Clone)]
pub struct EventMod {
    pub sighash: String,
    pub topic_count: usize,
    pub event_name: String,
    pub data_type: String,
    pub params_raw_event_schema: String,
    pub convert_hyper_sync_event_args_code: String,
    pub event_filter_type: String,
    pub get_topic_selection_code: String,
    pub custom_field_selection: Option<system_config::FieldSelection>,
    pub fuel_event_kind: Option<FuelEventKind>,
}

impl EventMod {
    fn to_string(&self) -> String {
        let sighash = &self.sighash;
        let topic_count = &self.topic_count;
        let event_name = &self.event_name;
        let data_type = &self.data_type;
        let params_raw_event_schema = &self.params_raw_event_schema;
        let convert_hyper_sync_event_args_code = &self.convert_hyper_sync_event_args_code;
        let event_filter_type = &self.event_filter_type;
        let get_topic_selection_code = &self.get_topic_selection_code;

        let fuel_event_kind_code = match self.fuel_event_kind {
            None => None,
            Some(FuelEventKind::Mint) => Some("Mint".to_string()),
            Some(FuelEventKind::Burn) => Some("Burn".to_string()),
            Some(FuelEventKind::Call) => Some("Call".to_string()),
            Some(FuelEventKind::Transfer) => Some("Transfer".to_string()),
            Some(FuelEventKind::LogData(_)) => Some(format!(
                r#"LogData({{
  logId: sighash,
  decode: Fuel.Receipt.getLogDataDecoder(~abi, ~logId=sighash),
}})"#
            )),
        };

        let (block_type, block_schema, transaction_type, transaction_schema) =
            match self.custom_field_selection {
                Some(ref field_selection) => {
                    let field_selection = FieldSelection::new(FieldSelectionOptions {
                        transaction_fields: field_selection.transaction_fields.clone(),
                        block_fields: field_selection.block_fields.clone(),
                        transaction_type_name: "transaction".to_string(),
                        block_type_name: "block".to_string(),
                    });
                    (
                        field_selection.block_type,
                        field_selection.block_schema,
                        field_selection.transaction_type,
                        field_selection.transaction_schema,
                    )
                }
                None => (
                    "Block.t".to_string(),
                    "Block.schema".to_string(),
                    "Transaction.t".to_string(),
                    "Transaction.schema".to_string(),
                ),
            };

        let non_event_mod_code = match fuel_event_kind_code {
            None => "".to_string(),
            Some(fuel_event_kind_code) => format!(
                r#"
let register = (): Internal.fuelEventConfig => {{
  name,
  kind: {fuel_event_kind_code},
  isWildcard: (handlerRegister->HandlerTypes.Register.getEventOptions).isWildcard,
  loader: handlerRegister->HandlerTypes.Register.getLoader,
  handler: handlerRegister->HandlerTypes.Register.getHandler,
  contractRegister: handlerRegister->HandlerTypes.Register.getContractRegister,
  paramsRawEventSchema: paramsRawEventSchema->(Utils.magic: S.t<eventArgs> => S.t<Internal.eventParams>),
}}"#
            ),
        };

        format!(
            r#"
let sighash = "{sighash}"
let topicCount = {topic_count}
let name = "{event_name}"
let contractName = contractName

@genType
type eventArgs = {data_type}
@genType
type block = {block_type}
@genType
type transaction = {transaction_type}

@genType
type event = Internal.genericEvent<eventArgs, block, transaction>
@genType
type loader<'loaderReturn> = Internal.genericLoader<Internal.genericLoaderArgs<event, loaderContext>, 'loaderReturn>
@genType
type handler<'loaderReturn> = Internal.genericHandler<Internal.genericHandlerArgs<event, handlerContext, 'loaderReturn>>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = {params_raw_event_schema}
let blockSchema = {block_schema}
let transactionSchema = {transaction_schema}

let convertHyperSyncEventArgs = {convert_hyper_sync_event_args_code}

let handlerRegister: HandlerTypes.Register.t = HandlerTypes.Register.make(
  ~topic0=sighash->EvmTypes.Hex.fromStringUnsafe,
  ~contractName,
  ~eventName=name,
)

@genType
type eventFilter = {event_filter_type}

let getTopicSelection = {get_topic_selection_code}
{non_event_mod_code}"#
        )
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventTemplate {
    pub name: String,
    pub module_code: String,
    pub params: Vec<EventParamTypeTemplate>,
}

impl EventTemplate {
    const GET_TOPIC_SELECTION_CODE_STUB: &'static str =
        "_ => [LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.\
         fromStringUnsafe])->Utils.unwrapResultExn]";

    const EVENT_FILTER_TYPE_STUB: &'static str = "{}";
    const CONVERT_HYPER_SYNC_EVENT_ARGS_NOOP: &'static str =
        "(Utils.magic: HyperSyncClient.Decoder.decodedEvent => eventArgs)";

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
            return Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NOOP.to_string();
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

    pub fn from_fuel_supply_event(
        config_event: &system_config::Event,
        fuel_event_kind: FuelEventKind,
    ) -> Self {
        let event_name = config_event.name.capitalize();
        let event_mod = EventMod {
            sighash: config_event.sighash.to_string(),
            topic_count: 0, //Default to 0 for fuel,
            event_name: event_name.clone(),
            data_type: "Internal.fuelSupplyParams".to_string(),
            params_raw_event_schema: "Internal.fuelSupplyParamsSchema".to_string(),
            convert_hyper_sync_event_args_code: Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NOOP
                .to_string(),
            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
            get_topic_selection_code: Self::GET_TOPIC_SELECTION_CODE_STUB.to_string(),
            custom_field_selection: config_event.field_selection.clone(),
            fuel_event_kind: Some(fuel_event_kind),
        };
        EventTemplate {
            name: event_name,
            module_code: event_mod.to_string(),
            params: vec![],
        }
    }

    pub fn from_fuel_transfer_event(
        config_event: &system_config::Event,
        fuel_event_kind: FuelEventKind,
    ) -> Self {
        let event_name = config_event.name.capitalize();
        let event_mod = EventMod {
            sighash: config_event.sighash.to_string(),
            topic_count: 0, //Default to 0 for fuel,
            event_name: event_name.clone(),
            data_type: "Internal.fuelTransferParams".to_string(),
            params_raw_event_schema: "Internal.fuelTransferParamsSchema".to_string(),
            convert_hyper_sync_event_args_code: Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NOOP
                .to_string(),
            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
            get_topic_selection_code: Self::GET_TOPIC_SELECTION_CODE_STUB.to_string(),
            custom_field_selection: config_event.field_selection.clone(),
            fuel_event_kind: Some(fuel_event_kind),
        };
        EventTemplate {
            name: event_name,
            module_code: event_mod.to_string(),
            params: vec![],
        }
    }

    pub fn from_config_event(config_event: &system_config::Event) -> Result<Self> {
        let event_name = config_event.name.capitalize();
        match &config_event.kind {
            EventKind::Params(params) => {
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

                let event_mod = EventMod {
                    sighash: config_event.sighash.to_string(),
                    topic_count: params
                        .iter()
                        .fold(1, |acc, param| if param.indexed { acc + 1 } else { acc }),
                    event_name: event_name.clone(),
                    data_type: data_type_expr.to_string(),
                    params_raw_event_schema: data_type_expr
                        .to_rescript_schema(&"eventArgs".to_string(), &RescriptSchemaMode::ForDb),
                    convert_hyper_sync_event_args_code:
                        Self::generate_convert_hyper_sync_event_args_code(params),
                    event_filter_type: Self::generate_event_filter_type(params),
                    get_topic_selection_code: Self::generate_get_topic_selection_code(params),
                    custom_field_selection: config_event.field_selection.clone(),
                    fuel_event_kind: None,
                };

                Ok(EventTemplate {
                    name: event_name,
                    module_code: event_mod.to_string(),
                    params: template_params,
                })
            }
            EventKind::Fuel(fuel_event_kind) => {
                let fuel_event_kind = fuel_event_kind.clone();
                match &fuel_event_kind {
                    FuelEventKind::LogData(type_indent) => {
                        let event_mod = EventMod {
                            sighash: config_event.sighash.to_string(),
                            topic_count: 0, //Default to 0 for fuel,
                            event_name: event_name.clone(),
                            data_type: type_indent.to_string(),
                            params_raw_event_schema: format!(
                                "{}->Utils.Schema.coerceToJsonPgType",
                                type_indent.to_rescript_schema(&RescriptSchemaMode::ForDb)
                            ),
                            convert_hyper_sync_event_args_code:
                                Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NOOP.to_string(),
                            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
                            get_topic_selection_code: Self::GET_TOPIC_SELECTION_CODE_STUB
                                .to_string(),
                            custom_field_selection: config_event.field_selection.clone(),
                            fuel_event_kind: Some(fuel_event_kind),
                        };

                        Ok(EventTemplate {
                            name: event_name,
                            module_code: event_mod.to_string(),
                            params: vec![],
                        })
                    }
                    FuelEventKind::Mint | FuelEventKind::Burn => {
                        Ok(Self::from_fuel_supply_event(config_event, fuel_event_kind))
                    }
                    FuelEventKind::Call | FuelEventKind::Transfer => Ok(
                        Self::from_fuel_transfer_event(config_event, fuel_event_kind),
                    ),
                }
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
                    all_abi_type_declarations.to_rescript_schema(&RescriptSchemaMode::ForDb)
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
    pub name: String,
}

impl PerNetworkContractEventTemplate {
    fn new(event_name: String) -> Self {
        PerNetworkContractEventTemplate {
            name: event_name.capitalize(),
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
    start_block: u64,
    end_block: Option<u64>,
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
    transaction_type: String,
    transaction_schema: String,
    block_type: String,
    block_schema: String,
}

struct FieldSelectionOptions {
    transaction_fields: Vec<SelectedField>,
    block_fields: Vec<SelectedField>,
    transaction_type_name: String,
    block_type_name: String,
}

impl FieldSelection {
    fn new(options: FieldSelectionOptions) -> Self {
        let mut block_field_templates = vec![];
        let mut all_block_fields = vec![];
        for field in options.block_fields.into_iter() {
            let name: CaseOptions = field.name.into();

            block_field_templates.push(SelectedFieldTemplate {
                name: name.clone(),
                default_value_rescript: field.data_type.get_default_value_rescript(),
                res_type: field.data_type.to_string(),
            });

            let record_field = RescriptRecordField::new(name.camel, field.data_type);
            all_block_fields.push(record_field.clone());
        }

        let mut transaction_field_templates = vec![];
        let mut all_transaction_fields = vec![];
        for field in options.transaction_fields.into_iter() {
            let name: CaseOptions = field.name.into();

            transaction_field_templates.push(SelectedFieldTemplate {
                name: name.clone(),
                default_value_rescript: field.data_type.get_default_value_rescript(),
                res_type: field.data_type.to_string(),
            });

            let record_field = RescriptRecordField::new(name.camel, field.data_type);
            all_transaction_fields.push(record_field);
        }

        let block_expr = RescriptTypeExpr::Record(all_block_fields);
        let transaction_expr = RescriptTypeExpr::Record(all_transaction_fields);

        Self {
            transaction_fields: transaction_field_templates,
            block_fields: block_field_templates,
            transaction_type: transaction_expr.to_string(),
            transaction_schema: transaction_expr.to_rescript_schema(
                &options.transaction_type_name,
                &RescriptSchemaMode::ForFieldSelection,
            ),
            block_type: block_expr.to_string(),
            block_schema: block_expr.to_rescript_schema(
                &options.block_type_name,
                &RescriptSchemaMode::ForFieldSelection,
            ),
        }
    }

    fn global_selection(cfg: &system_config::FieldSelection) -> Self {
        Self::new(FieldSelectionOptions {
            transaction_fields: cfg.transaction_fields.clone(),
            block_fields: cfg.block_fields.clone(),
            transaction_type_name: "t".to_string(),
            block_type_name: "t".to_string(),
        })
    }

    fn aggregated_selection(cfg: &system_config::SystemConfig) -> Self {
        let mut transaction_fields: HashSet<_> = cfg
            .field_selection
            .transaction_fields
            .iter()
            .cloned()
            .collect();
        let mut block_fields: HashSet<_> =
            cfg.field_selection.block_fields.iter().cloned().collect();

        cfg.contracts.iter().for_each(|(_name, contract)| {
            contract.events.iter().for_each(|event| {
                if let Some(field_selection) = &event.field_selection {
                    field_selection.transaction_fields.iter().for_each(|field| {
                        transaction_fields.insert(field.clone());
                    });
                    field_selection.block_fields.iter().for_each(|field| {
                        block_fields.insert(field.clone());
                    });
                }
            });
        });

        Self::new(FieldSelectionOptions {
            transaction_fields: transaction_fields.into_iter().collect::<Vec<_>>(),
            block_fields: block_fields.into_iter().collect::<Vec<_>>(),
            transaction_type_name: "t".to_string(),
            block_type_name: "t".to_string(),
        })
    }
}

#[derive(Serialize)]
struct SelectedFieldTemplate {
    name: CaseOptions,
    res_type: String,
    default_value_rescript: String,
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
    aggregated_field_selection: FieldSelection,
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

        let global_field_selection = FieldSelection::global_selection(&cfg.field_selection);
        let aggregated_field_selection = FieldSelection::aggregated_selection(&cfg);

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
            field_selection: global_field_selection,
            aggregated_field_selection,
            is_evm_ecosystem: cfg.get_ecosystem() == Ecosystem::Evm,
            is_fuel_ecosystem: cfg.get_ecosystem() == Ecosystem::Fuel,
            //Used for the package.json reference to handlers in generated
            relative_path_to_root_from_generated,
        })
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        config_parsing::system_config::{RpcConfig, SystemConfig},
        project_paths::ParsedProjectPaths,
        utils::text::Capitalize,
    };
    use pretty_assertions::assert_eq;
    use std::vec;
    use system_config::FieldSelection;

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

    impl Default for NetworkTemplate {
        fn default() -> Self {
            Self {
                id: 0,
                rpc_config: None,
                hypersync_config: None,
                hyperfuel_config: None,
                confirmed_block_threshold: 200,
                start_block: 0,
                end_block: None,
            }
        }
    }

    #[test]
    fn chain_configs_parsed_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let rpc_config1 = RpcConfig {
            urls: vec!["https://eth.com".to_string()],
            sync_config: system_config::SyncConfig {
                acceleration_additive: 2_000,
                ..system_config::SyncConfig::default()
            },
        };

        let network1 = NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1),
            ..NetworkTemplate::default()
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
            sync_config: system_config::SyncConfig {
                acceleration_additive: 2_000,
                ..system_config::SyncConfig::default()
            },
        };
        let network1 = NetworkTemplate {
            id: 1,
            rpc_config: Some(rpc_config1.clone()),
            ..NetworkTemplate::default()
        };

        let rpc_config2 = RpcConfig {
            urls: vec![
                "https://eth.com".to_string(),
                // Should support fallback urls
                "https://eth.com/fallback".to_string(),
            ],
            sync_config: system_config::SyncConfig {
                acceleration_additive: 2_000,
                ..system_config::SyncConfig::default()
            },
        };

        let network2 = NetworkTemplate {
            id: 2,
            rpc_config: Some(rpc_config2),
            ..NetworkTemplate::default()
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

        let network1 = NetworkTemplate {
            id: 1,
            hypersync_config: Some(HypersyncConfig {
                endpoint_url: "https://1.hypersync.xyz".to_string(),
                is_client_decoder: true,
            }),
            ..NetworkTemplate::default()
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
        let network1 = NetworkTemplate {
            id: 1,
            hypersync_config: Some(HypersyncConfig {
                endpoint_url: "https://myskar.com".to_string(),
                is_client_decoder: true,
            }),
            ..NetworkTemplate::default()
        };

        let network2 = NetworkTemplate {
            id: 137,
            hypersync_config: Some(HypersyncConfig {
                endpoint_url: "https://137.hypersync.xyz".to_string(),
                is_client_decoder: true,
            }),
            ..NetworkTemplate::default()
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
            name: "NewGravatar".to_string(),
            params,
            module_code: format!(
                r#"
let sighash = "{sighash}"
let topicCount = 1
let name = "NewGravatar"
let contractName = contractName

@genType
type eventArgs = {{id: bigint, owner: Address.t, displayName: string, imageUrl: string}}
@genType
type block = Block.t
@genType
type transaction = Transaction.t

@genType
type event = Internal.genericEvent<eventArgs, block, transaction>
@genType
type loader<'loaderReturn> = Internal.genericLoader<Internal.genericLoaderArgs<event, loaderContext>, 'loaderReturn>
@genType
type handler<'loaderReturn> = Internal.genericHandler<Internal.genericHandlerArgs<event, handlerContext, 'loaderReturn>>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = S.object((s): eventArgs => {{id: s.field("id", BigInt.schema), owner: s.field("owner", Address.schema), displayName: s.field("displayName", S.string), imageUrl: s.field("imageUrl", S.string)}})
let blockSchema = Block.schema
let transactionSchema = Transaction.schema

let convertHyperSyncEventArgs = (decodedEvent: HyperSyncClient.Decoder.decodedEvent): eventArgs => {{
      {{
        id: decodedEvent.body->Js.Array2.unsafe_get(0)->HyperSyncClient.Decoder.toUnderlying->Utils.magic,
        owner: decodedEvent.body->Js.Array2.unsafe_get(1)->HyperSyncClient.Decoder.toUnderlying->Utils.magic,
        displayName: decodedEvent.body->Js.Array2.unsafe_get(2)->HyperSyncClient.Decoder.toUnderlying->Utils.magic,
        imageUrl: decodedEvent.body->Js.Array2.unsafe_get(3)->HyperSyncClient.Decoder.toUnderlying->Utils.magic,
      }}
    }}

let handlerRegister: HandlerTypes.Register.t = HandlerTypes.Register.make(
  ~topic0=sighash->EvmTypes.Hex.fromStringUnsafe,
  ~contractName,
  ~eventName=name,
)

@genType
type eventFilter = {{  }}

let getTopicSelection = (eventFilters) => eventFilters->SingleOrMultiple.normalizeOrThrow->Belt.Array.map(_eventFilter => LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.fromStringUnsafe], )->Utils.unwrapResultExn)
"#
            ),
        }
    }

    #[test]
    fn event_template_with_empty_params() {
        let event_template = EventTemplate::from_config_event(&system_config::Event {
            name: "NewGravatar".to_string(),
            kind: system_config::EventKind::Params(vec![]),
            sighash: "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
                .to_string(),
            field_selection: None,
        })
        .unwrap();

        assert_eq!(
            event_template,
            EventTemplate {
                name: "NewGravatar".to_string(),
                params: vec![],
                module_code: format!(
                    r#"
let sighash = "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
let topicCount = 1
let name = "NewGravatar"
let contractName = contractName

@genType
type eventArgs = unit
@genType
type block = Block.t
@genType
type transaction = Transaction.t

@genType
type event = Internal.genericEvent<eventArgs, block, transaction>
@genType
type loader<'loaderReturn> = Internal.genericLoader<Internal.genericLoaderArgs<event, loaderContext>, 'loaderReturn>
@genType
type handler<'loaderReturn> = Internal.genericHandler<Internal.genericHandlerArgs<event, handlerContext, 'loaderReturn>>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = S.literal(%raw(`null`))->S.variant(_ => ())
let blockSchema = Block.schema
let transactionSchema = Transaction.schema

let convertHyperSyncEventArgs = (Utils.magic: HyperSyncClient.Decoder.decodedEvent => eventArgs)

let handlerRegister: HandlerTypes.Register.t = HandlerTypes.Register.make(
  ~topic0=sighash->EvmTypes.Hex.fromStringUnsafe,
  ~contractName,
  ~eventName=name,
)

@genType
type eventFilter = {{  }}

let getTopicSelection = (eventFilters) => eventFilters->SingleOrMultiple.normalizeOrThrow->Belt.Array.map(_eventFilter => LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.fromStringUnsafe], )->Utils.unwrapResultExn)
"#
                ),
            }
        );
    }

    #[test]
    fn event_template_with_custom_field_selection() {
        let event_template = EventTemplate::from_config_event(&system_config::Event {
            name: "NewGravatar".to_string(),
            kind: system_config::EventKind::Params(vec![]),
            sighash: "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
                .to_string(),
            field_selection: Some(FieldSelection {
                block_fields: vec![],
                transaction_fields: vec![SelectedField {
                    name: "from".to_string(),
                    data_type: RescriptTypeIdent::option(RescriptTypeIdent::Address),
                }],
            }),
        })
        .unwrap();

        assert_eq!(
            event_template,
            EventTemplate {
                name: "NewGravatar".to_string(),
                params: vec![],
                module_code: format!(
                    r#"
let sighash = "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
let topicCount = 1
let name = "NewGravatar"
let contractName = contractName

@genType
type eventArgs = unit
@genType
type block = {{}}
@genType
type transaction = {{from: option<Address.t>}}

@genType
type event = Internal.genericEvent<eventArgs, block, transaction>
@genType
type loader<'loaderReturn> = Internal.genericLoader<Internal.genericLoaderArgs<event, loaderContext>, 'loaderReturn>
@genType
type handler<'loaderReturn> = Internal.genericHandler<Internal.genericHandlerArgs<event, handlerContext, 'loaderReturn>>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = S.literal(%raw(`null`))->S.variant(_ => ())
let blockSchema = S.object((_): block => {{}})
let transactionSchema = S.object((s): transaction => {{from: s.field("from", S.option(Address.schema))}})

let convertHyperSyncEventArgs = (Utils.magic: HyperSyncClient.Decoder.decodedEvent => eventArgs)

let handlerRegister: HandlerTypes.Register.t = HandlerTypes.Register.make(
  ~topic0=sighash->EvmTypes.Hex.fromStringUnsafe,
  ~contractName,
  ~eventName=name,
)

@genType
type eventFilter = {{  }}

let getTopicSelection = (eventFilters) => eventFilters->SingleOrMultiple.normalizeOrThrow->Belt.Array.map(_eventFilter => LogSelection.makeTopicSelection(~topic0=[sighash->EvmTypes.Hex.fromStringUnsafe], )->Utils.unwrapResultExn)
"#
                ),
            }
        );
    }

    #[test]
    fn abi_event_to_record_1() {
        let project_template = get_project_template_helper("config1.yaml");

        let new_gavatar_event_template =
            project_template.codegen_contracts[0].codegen_events[0].clone();

        let expected_event_template = make_expected_event_template(
            "0x9ab3aefb2ba6dc12910ac1bce4692cf5c3c0d06cff16327c64a3ef78228b130b".to_string(),
        );

        assert_eq!(expected_event_template, new_gavatar_event_template);
    }

    #[test]
    fn abi_event_to_record_2() {
        let project_template = get_project_template_helper("gravatar-with-required-entities.yaml");

        let new_gavatar_event_template = &project_template.codegen_contracts[0].codegen_events[0];
        let expected_event_template = make_expected_event_template(
            "0x9ab3aefb2ba6dc12910ac1bce4692cf5c3c0d06cff16327c64a3ef78228b130b".to_string(),
        );

        assert_eq!(&expected_event_template, new_gavatar_event_template);
    }
}
