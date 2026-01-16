use std::{
    collections::BTreeSet,
    fmt::{Display, Write},
    path::PathBuf,
    vec,
};

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::{
    config_parsing::{
        chain_helpers::Network,
        entity_parsing::{Entity, Field, GraphQLEnum},
        event_parsing::{abi_to_rescript_type, EthereumEventParam},
        field_types,
        human_config::{
            evm::{For, Rpc, RpcSyncConfig},
            HumanConfig,
        },
        system_config::{
            self, get_envio_version, Abi, Ecosystem, EventKind, FuelEventKind, MainEvmDataSource,
            SelectedField, SystemConfig,
        },
    },
    persisted_state::{PersistedState, PersistedStateJsonString},
    project_paths::{
        path_utils::{add_leading_relative_dot, add_trailing_relative_dot},
        ParsedProjectPaths,
    },
    template_dirs::TemplateDirs,
    type_schema::{RecordField, SchemaMode, TypeExpr, TypeIdent},
    utils::text::{Capitalize, CapitalizedOptions, CaseOptions},
};
use anyhow::{anyhow, Context, Result};
use convert_case::{Case, Casing};
use pathdiff::diff_paths;

use crate::config_parsing::abi_compat::EventParam;
use serde::Serialize;

// ============== Internal Config JSON Types ==============

fn is_true(v: &bool) -> bool {
    *v
}

fn is_false(v: &bool) -> bool {
    !v
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct InternalConfigJson<'a> {
    name: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    handlers: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    multichain: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    full_batch_size: Option<u64>,
    #[serde(skip_serializing_if = "is_true")]
    rollback_on_reorg: bool,
    #[serde(skip_serializing_if = "is_false")]
    save_full_history: bool,
    #[serde(skip_serializing_if = "is_false")]
    raw_events: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    evm: Option<InternalEvmConfig<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fuel: Option<InternalFuelConfig<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    svm: Option<InternalSvmConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct InternalEvmConfig<'a> {
    chains: std::collections::BTreeMap<String, InternalChainConfig>,
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    contracts: std::collections::BTreeMap<&'a str, InternalContractConfig>,
    address_format: &'a str,
    event_decoder: &'a str,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct InternalFuelConfig<'a> {
    chains: std::collections::BTreeMap<String, InternalChainConfig>,
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    contracts: std::collections::BTreeMap<&'a str, InternalContractConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct InternalSvmConfig {
    chains: std::collections::BTreeMap<String, InternalChainConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct InternalChainConfig {
    id: u64,
    start_block: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    end_block: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_reorg_depth: Option<i32>,
}

#[derive(Serialize, Debug)]
struct InternalContractConfig {
    abi: Box<serde_json::value::RawValue>,
}

// ============== Template Types ==============

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
pub struct EntityParamTypeTemplate {
    pub field_name: CapitalizedOptions,
    pub res_type: TypeIdent,
    pub is_entity_field: bool,
    pub is_indexed_field: bool,
    ///Used to determine if you can run a where
    ///query on this field.
    pub is_queryable_field: bool,
}

impl EntityParamTypeTemplate {
    fn from_entity_field(field: &Field, entity: &Entity, config: &SystemConfig) -> Result<Self> {
        let res_type: TypeIdent = field
            .field_type
            .to_rescript_type(&config.schema)
            .context("Failed getting rescript type")?;

        let schema = &config.schema;

        let is_entity_field = field.field_type.is_entity_field(schema)?;
        let is_indexed_field = field.is_indexed_field(entity);
        let is_derived_lookup_field = field.is_derived_lookup_field(entity, schema);

        //Both of these cases have indexes on them and should exist
        let is_queryable_field = is_indexed_field || is_derived_lookup_field;

        Ok(EntityParamTypeTemplate {
            field_name: field.name.to_capitalized_options(),
            res_type,
            is_entity_field,
            is_indexed_field,
            is_queryable_field,
        })
    }
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
    pub type_code: String,
    pub schema_code: String,
    pub postgres_fields: Vec<field_types::Field>,
    pub composite_indices: Vec<Vec<String>>,
    pub derived_fields: Vec<DerivedFieldTemplate>,
    pub params: Vec<EntityParamTypeTemplate>,
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

        // Build record fields for type/schema generation
        let record_fields: Vec<RecordField> = entity
            .get_fields()
            .iter()
            .filter(|f| !f.field_type.is_derived_from())
            .map(|field| {
                let is_entity = field.field_type.is_entity_field(&config.schema)?;
                let field_name = if is_entity {
                    format!("{}_id", field.name.uncapitalize())
                } else {
                    field.name.uncapitalize()
                };
                let res_type = field.field_type.to_rescript_type(&config.schema)?;
                Ok(RecordField::new(field_name, res_type))
            })
            .collect::<Result<_>>()
            .context(format!(
                "Failed building record fields for entity: {}",
                entity.name
            ))?;

        let type_expr = TypeExpr::Record(record_fields);
        let type_code = type_expr.to_string();
        let schema_code = type_expr.to_rescript_schema(&"t".to_string(), &SchemaMode::ForDb);

        let postgres_fields = entity
            .get_fields()
            .iter()
            .map(|gql_field| gql_field.get_postgres_field(&config.schema, entity))
            .collect::<Result<Vec<_>>>()?
            .into_iter()
            .flatten()
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
            type_code,
            schema_code,
            derived_fields,
            composite_indices,
            params,
        })
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct EventMod {
    pub sighash: String,
    pub topic_count: usize,
    pub event_name: String,
    pub data_type: String,
    pub parse_event_filters_code: String,
    pub params_raw_event_schema: String,
    pub convert_hyper_sync_event_args_code: String,
    pub event_filter_type: String,
    pub custom_field_selection: Option<system_config::FieldSelection>,
    pub fuel_event_kind: Option<FuelEventKind>,
}

impl Display for EventMod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

impl EventMod {
    fn to_string_internal(&self) -> String {
        let sighash = &self.sighash;
        let topic_count = &self.topic_count;
        let event_name = &self.event_name;
        let data_type = &self.data_type;
        let params_raw_event_schema = &self.params_raw_event_schema;
        let convert_hyper_sync_event_args_code = &self.convert_hyper_sync_event_args_code;
        let event_filter_type = &self.event_filter_type;
        let parse_event_filters_code = &self.parse_event_filters_code;

        let event_filters_type_code = match self.event_filter_type.as_str() {
            "{}" => "@genType type eventFilters = Internal.noEventFilters".to_string(),
            _ => "@genType type eventFiltersArgs = {/** The unique identifier of the blockchain \
                network where this event occurred. */ chainId: chainId, /** Addresses of the \
                contracts indexing the event. */ addresses: array<Address.t>}\n
@genType @unboxed type eventFiltersDefinition = Single(eventFilter) | \
                Multiple(array<eventFilter>) | @as(false) Skip | @as(true) Keep\n
@genType @unboxed type eventFilters = | ...eventFiltersDefinition | Dynamic(eventFiltersArgs => \
                eventFiltersDefinition)"
                .to_string(),
        };

        let fuel_event_kind_code = match self.fuel_event_kind {
            None => None,
            Some(FuelEventKind::Mint) => Some("Mint".to_string()),
            Some(FuelEventKind::Burn) => Some("Burn".to_string()),
            Some(FuelEventKind::Call) => Some("Call".to_string()),
            Some(FuelEventKind::Transfer) => Some("Transfer".to_string()),
            Some(FuelEventKind::LogData(_)) => Some(
                r#"LogData({
logId: sighash,
decode: FuelSDK.Receipt.getLogDataDecoder(~abi, ~logId=sighash),
})"#
                .to_string(),
            ),
        };

        let event_id = match self.fuel_event_kind {
            None => format!("{sighash}_{topic_count}"),
            Some(FuelEventKind::Mint) => "mint".to_string(),
            Some(FuelEventKind::Burn) => "burn".to_string(),
            Some(FuelEventKind::Call) => "call".to_string(),
            Some(FuelEventKind::Transfer) => "transfer".to_string(),
            Some(FuelEventKind::LogData(_)) => sighash.to_string(),
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

        let base_event_config_code = r#"id,
name,
contractName,
isWildcard: (handlerRegister->EventRegister.isWildcard),
handler: handlerRegister->EventRegister.getHandler,
contractRegister: handlerRegister->EventRegister.getContractRegister,
paramsRawEventSchema: paramsRawEventSchema->(Utils.magic: S.t<eventArgs> => S.t<Internal.eventParams>),"#.to_string();

        let non_event_mod_code = match fuel_event_kind_code {
            None => format!(
                r#"
let register = (): Internal.evmEventConfig => {{
let {{getEventFiltersOrThrow, filterByAddresses}} = {parse_event_filters_code}
{{
  getEventFiltersOrThrow,
  filterByAddresses,
  dependsOnAddresses: !(handlerRegister->EventRegister.isWildcard) || filterByAddresses,
  blockSchema: blockSchema->(Utils.magic: S.t<block> => S.t<Internal.eventBlock>),
  transactionSchema: transactionSchema->(Utils.magic: S.t<transaction> => S.t<Internal.eventTransaction>),
  convertHyperSyncEventArgs: {convert_hyper_sync_event_args_code},
  {base_event_config_code}
}}
}}"#
            ),
            Some(fuel_event_kind_code) => format!(
                r#"
let register = (): Internal.fuelEventConfig => {{
kind: {fuel_event_kind_code},
filterByAddresses: false,
dependsOnAddresses: !(handlerRegister->EventRegister.isWildcard),
{base_event_config_code}
}}"#
            ),
        };

        let types_code =
          r#"@genType
type handlerArgs = Internal.genericHandlerArgs<event, handlerContext>
@genType
type handler = Internal.genericHandler<handlerArgs>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>"#.to_string();

        format!(
            r#"
let id = "{event_id}"
let sighash = "{sighash}"
let name = "{event_name}"
let contractName = contractName

@genType
type eventArgs = {data_type}
@genType
type block = {block_type}
@genType
type transaction = {transaction_type}

@genType
type event = {{
/** The parameters or arguments associated with this event. */
params: eventArgs,
/** The unique identifier of the blockchain network where this event occurred. */
chainId: chainId,
/** The address of the contract that emitted this event. */
srcAddress: Address.t,
/** The index of this event's log within the block. */
logIndex: int,
/** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
transaction: transaction,
/** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
block: block,
}}

{types_code}

let paramsRawEventSchema = {params_raw_event_schema}
let blockSchema = {block_schema}
let transactionSchema = {transaction_schema}

let handlerRegister: EventRegister.t = EventRegister.make(
~contractName,
~eventName=name,
)

@genType
type eventFilter = {event_filter_type}

{event_filters_type_code}
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
    const EVENT_FILTER_TYPE_STUB: &'static str = "{}";
    const CONVERT_HYPER_SYNC_EVENT_ARGS_NOOP: &'static str =
        "_ => ()->(Utils.magic: eventArgs => Internal.eventParams)";
    const CONVERT_HYPER_SYNC_EVENT_ARGS_NEVER: &'static str =
        "_ => Js.Exn.raiseError(\"Not implemented\")";

    pub fn generate_event_filter_type(params: &[EventParam]) -> String {
        let field_rows = params
            .iter()
            .filter(|param| param.indexed)
            .map(|param| {
                format!(
                    "@as(\"{}\") {}?: SingleOrMultiple.t<{}>",
                    param.name,
                    RecordField::to_valid_rescript_name(&param.name),
                    abi_to_rescript_type(&param.into())
                )
            })
            .collect::<Vec<_>>()
            .join(", ");

        format!("{{{field_rows}}}")
    }

    pub fn generate_parse_event_filters_code(params: &[EventParam]) -> String {
        let indexed_params = params.iter().filter(|param| param.indexed);

        //Prefixed with underscore for cases where it is not used to avoid compiler warnings
        let event_filter_arg = "_eventFilter";
        let mut params_code = "".to_string();

        let topic_filter_calls =
            indexed_params
                .enumerate()
                .fold(String::new(), |mut output, (i, param)| {
                    let param = EthereumEventParam::from(param);
                    let topic_number = i + 1;
                    let param_name = RecordField::to_valid_rescript_name(param.name);
                    let topic_encoder = param.get_topic_encoder();
                    let nested_type_flags = match param.get_nested_type_depth() {
                        depth if depth > 0 => format!("(~nestedArrayDepth={depth})"),
                        _ => "".to_string(),
                    };
                    params_code = format!("{params_code}\"{param_name}\",");
                    let _ = write!(
                        output,
                        ", ~topic{topic_number}=({event_filter_arg}) => \
                       {event_filter_arg}->Utils.Dict.dangerouslyGetNonOption(\"{param_name}\"\
                       )->Belt.Option.mapWithDefault([], topicFilters => \
                       topicFilters->Obj.magic->SingleOrMultiple.\
                       normalizeOrThrow{nested_type_flags}->Belt.Array.map({topic_encoder}))"
                    );
                    output
                });

        format!(
            "LogSelection.parseEventFiltersOrThrow(~eventFilters=handlerRegister->EventRegister.\
           getEventFilters, ~sighash, ~params=[{params_code}]{topic_filter_calls})"
        )
    }

    pub fn generate_convert_hyper_sync_event_args_code(params: &[EventParam]) -> String {
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

        let mut code = String::from("(decodedEvent: HyperSyncClient.Decoder.decodedEvent) => {");

        for (index, param) in indexed_params.into_iter().enumerate() {
            code.push_str(&format!(
                "{}: decodedEvent.indexed->Js.Array2.unsafe_get({})->HyperSyncClient.Decoder.\
               toUnderlying->Utils.magic, ",
                RecordField::to_valid_rescript_name(&param.name),
                index
            ));
        }

        for (index, param) in body_params.into_iter().enumerate() {
            code.push_str(&format!(
                "{}: decodedEvent.body->Js.Array2.unsafe_get({})->HyperSyncClient.Decoder.\
               toUnderlying->Utils.magic, ",
                RecordField::to_valid_rescript_name(&param.name),
                index
            ));
        }

        code.push_str("}->(Utils.magic: eventArgs => Internal.eventParams)");

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
            parse_event_filters_code: "".to_string(),
            data_type: "Internal.fuelSupplyParams".to_string(),
            params_raw_event_schema: "Internal.fuelSupplyParamsSchema".to_string(),
            convert_hyper_sync_event_args_code: Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NEVER
                .to_string(),
            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
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
            parse_event_filters_code: "".to_string(),
            data_type: "Internal.fuelTransferParams".to_string(),
            params_raw_event_schema: "Internal.fuelTransferParamsSchema".to_string(),
            convert_hyper_sync_event_args_code: Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NEVER
                .to_string(),
            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
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
                            res_name: RecordField::to_valid_rescript_name(&js_name),
                            js_name,
                            default_value_rescript: res_type.get_default_value_rescript(),
                            default_value_non_rescript: res_type.get_default_value_non_rescript(),
                            res_type: res_type.to_string(),
                            is_eth_address: res_type == TypeIdent::Address,
                        }
                    })
                    .collect::<Vec<_>>();

                let data_type_expr = if params.is_empty() {
                    TypeExpr::Identifier(TypeIdent::Unit)
                } else {
                    TypeExpr::Record(
                        params
                            .iter()
                            .map(|p| {
                                RecordField::new(
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
                    parse_event_filters_code: Self::generate_parse_event_filters_code(params),
                    params_raw_event_schema: data_type_expr
                        .to_rescript_schema(&"eventArgs".to_string(), &SchemaMode::ForDb),
                    convert_hyper_sync_event_args_code:
                        Self::generate_convert_hyper_sync_event_args_code(params),
                    event_filter_type: Self::generate_event_filter_type(params),
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
                            parse_event_filters_code: "".to_string(),
                            data_type: type_indent.to_string(),
                            params_raw_event_schema: format!(
                                "{}->Utils.Schema.coerceToJsonPgType",
                                type_indent.to_rescript_schema(&SchemaMode::ForDb)
                            ),
                            convert_hyper_sync_event_args_code:
                                Self::CONVERT_HYPER_SYNC_EVENT_ARGS_NEVER.to_string(),
                            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
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
    pub module_code: String,
    pub handler: Option<String>,
}

impl ContractTemplate {
    fn from_config_contract(
        contract: &system_config::Contract,
        config: &SystemConfig,
    ) -> Result<Self> {
        let name = contract.name.to_capitalized_options();
        let handler = contract.handler_path.clone();
        let codegen_events = contract
            .events
            .iter()
            .map(EventTemplate::from_config_event)
            .collect::<Result<_>>()?;

        let chain_ids = contract.get_chain_ids(config);

        let chain_id_type_code = {
            let chain_id_type = if chain_ids.is_empty() {
                "int".to_string()
            } else {
                format!(
                    "[{}]",
                    chain_ids
                        .iter()
                        .map(|chain_id| format!("#{chain_id}"))
                        .collect::<Vec<_>>()
                        .join(" | ")
                )
            };
            format!("@genType type chainId = {chain_id_type}")
        };

        let module_code = match &contract.abi {
            Abi::Evm(abi) => {
                let signatures = abi.get_event_signatures();

                format!(
                    r#"let abi = (%raw(`{}`): EvmTypes.Abi.t)
let eventSignatures = [{}]
{chain_id_type_code}"#,
                    abi.raw,
                    signatures
                        .iter()
                        .map(|w| format!("\"{}\"", w))
                        .collect::<Vec<_>>()
                        .join(", ")
                )
            }
            Abi::Fuel(abi) => {
                let all_abi_type_declarations = abi.to_type_decl_multi().context(format!(
                    "Failed getting types from the '{}' contract ABI",
                    contract.name
                ))?;

                format!(
                  "let abi = FuelSDK.transpileAbi((await Utils.importPathWithJson(`../${{Path.\
                   relativePathToRootFromGenerated}}/{}`))[\"default\"])\n{}\n{}\n{chain_id_type_code}",
                  // If we decide to inline the abi, instead of using require
                  // we need to remember that abi might contain ` and we should escape it
                  abi.path_buf.to_string_lossy(),
                    all_abi_type_declarations,
                    all_abi_type_declarations.to_rescript_schema(&SchemaMode::ForDb)
                )
            }
        };

        Ok(ContractTemplate {
            name,
            handler,
            codegen_events,
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
    start_block: Option<u64>,
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
            start_block: network_contract.start_block,
        })
    }
}

type EthAddress = String;

#[derive(Debug, Serialize, PartialEq, Clone, Default)]
struct NetworkTemplate {
    pub id: u64,
    max_reorg_depth: Option<i32>,
    start_block: u64,
    end_block: Option<u64>,
}

impl NetworkTemplate {
    fn from_config_network(network: &system_config::Network) -> Self {
        NetworkTemplate {
            id: network.id,
            max_reorg_depth: network.max_reorg_depth,
            start_block: network.start_block,
            end_block: network.end_block,
        }
    }
}

#[derive(Debug, Serialize, PartialEq, Clone)]
pub struct NetworkConfigTemplate {
    network_config: NetworkTemplate,
    codegen_contracts: Vec<PerNetworkContractTemplate>,
    sources_code: String,
    // event_decoder: Option<String>,
}

impl NetworkConfigTemplate {
    fn from_config_network(
        network: &system_config::Network,
        config: &SystemConfig,
    ) -> Result<Self> {
        let network_config = NetworkTemplate::from_config_network(network);
        let codegen_contracts: Vec<PerNetworkContractTemplate> = config
            .get_contracts()
            .iter()
            .map(|contract| {
                // Check if this contract is defined on the current network
                let network_contract = network.contracts.iter().find(|nc| nc.name == contract.name);

                match network_contract {
                    Some(nc) => {
                        // Contract is defined on this network, use its addresses
                        PerNetworkContractTemplate::from_config_network_contract(nc, config)
                    }
                    None => {
                        // Contract is not defined on this network, create with empty addresses
                        let events = contract
                            .events
                            .iter()
                            .map(|event| PerNetworkContractEventTemplate::new(event.name.clone()))
                            .collect();

                        Ok(PerNetworkContractTemplate {
                            name: contract.name.to_capitalized_options(),
                            addresses: vec![],
                            events,
                            start_block: None,
                        })
                    }
                }
            })
            .collect::<Result<_>>()
            .context("Failed mapping network contracts")?;

        let contracts_code: String = codegen_contracts
            .iter()
            .map(|contract| {
                let events_code: String = contract
                    .events
                    .iter()
                    .map(|event| {
                        format!(
                            "Types.{}.{}.register()",
                            contract.name.capitalized, event.name
                        )
                    })
                    .collect::<Vec<String>>()
                    .join(", ");

                let ecosystem_fields = match &network.sync_source {
                    system_config::DataSource::Evm { .. } => {
                        format!(",abi: Types.{}.abi", contract.name.capitalized)
                    }
                    system_config::DataSource::Fuel { .. }
                    | system_config::DataSource::Svm { .. } => "".to_string(),
                };

                format!(
                    "{{name: \"{}\",events: [{}]{ecosystem_fields}}}",
                    contract.name.capitalized, events_code
                )
            })
            .collect::<Vec<String>>()
            .join(", ");

        let sources_code = match &network.sync_source {
            system_config::DataSource::Fuel {
                hypersync_endpoint_url,
            } => format!(
                "[HyperFuelSource.make({{chain, endpointUrl: \
                   \"{hypersync_endpoint_url}\"}})]",
            ),
            system_config::DataSource::Svm { rpc } => {
                format!("[Svm.makeRPCSource(~chain, ~rpc=\"{rpc}\")]",)
            }
            system_config::DataSource::Evm { main, rpcs } => {
                let all_event_signatures = codegen_contracts
                    .iter()
                    .map(|contract| format!("Types.{}.eventSignatures", contract.name.capitalized))
                    .collect::<Vec<String>>()
                    .join(", ");

                let hyper_sync_code = match main {
                    MainEvmDataSource::HyperSync {
                        hypersync_endpoint_url,
                    } => format!("Some(\"{hypersync_endpoint_url}\")"),
                    MainEvmDataSource::Rpc(_) => "None".to_string(),
                };

                let rpc_to_sync_config_options = |rpc: &Rpc| match rpc.sync_config {
                    None => "{}".to_string(),
                    Some(RpcSyncConfig {
                        acceleration_additive,
                        initial_block_interval,
                        backoff_multiplicative,
                        interval_ceiling,
                        backoff_millis,
                        fallback_stall_timeout,
                        query_timeout_millis,
                    }) => {
                        let mut code = String::from("{");
                        if let Some(acceleration_additive) = acceleration_additive {
                            code.push_str(&format!(
                                "accelerationAdditive: {},",
                                acceleration_additive
                            ));
                        }
                        if let Some(initial_block_interval) = initial_block_interval {
                            code.push_str(&format!(
                                "initialBlockInterval: {},",
                                initial_block_interval
                            ));
                        }
                        if let Some(backoff_multiplicative) = backoff_multiplicative {
                            code.push_str(&format!(
                                "backoffMultiplicative: {},",
                                backoff_multiplicative
                            ));
                        }
                        if let Some(interval_ceiling) = interval_ceiling {
                            code.push_str(&format!("intervalCeiling: {},", interval_ceiling));
                        }
                        if let Some(backoff_millis) = backoff_millis {
                            code.push_str(&format!("backoffMillis: {},", backoff_millis));
                        }
                        if let Some(fallback_stall_timeout) = fallback_stall_timeout {
                            code.push_str(&format!(
                                "fallbackStallTimeout: {},",
                                fallback_stall_timeout
                            ));
                        }
                        if let Some(query_timeout_millis) = query_timeout_millis {
                            code.push_str(&format!(
                                "queryTimeoutMillis: {},",
                                query_timeout_millis
                            ));
                        }
                        code.push('}');
                        code
                    }
                };

                let rpcs = rpcs
                    .iter()
                    .map(|rpc| {
                        format!(
                            "{{url: \"{}\", sourceFor: {}, syncConfig: {}}}",
                            rpc.url,
                            match rpc.source_for {
                                For::Sync => "Sync",
                                For::Fallback => "Fallback",
                                For::Live => "Live",
                            },
                            rpc_to_sync_config_options(rpc)
                        )
                    })
                    .collect::<Vec<String>>()
                    .join(", ");

                format!(
                    "EvmChain.makeSources(~chain, ~contracts=[{contracts_code}], \
                       ~hyperSync={hyper_sync_code}, \
                       ~allEventSignatures=[{all_event_signatures}]->Belt.Array.concatMany, \
                       ~rpcs=[{rpcs}], \
                       ~lowercaseAddresses={})",
                    if config.lowercase_addresses {
                        "true"
                    } else {
                        "false"
                    }
                )
            }
        };

        Ok(NetworkConfigTemplate {
            network_config,
            codegen_contracts,
            sources_code,
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
            let res_name = RecordField::to_valid_rescript_name(&field.name);
            let name: CaseOptions = field.name.into();

            block_field_templates.push(SelectedFieldTemplate {
                name: name.clone(),
                res_name,
                default_value_rescript: field.data_type.get_default_value_rescript(),
                res_type: field.data_type.to_string(),
            });

            let record_field = RecordField::new(name.camel, field.data_type);
            all_block_fields.push(record_field.clone());
        }

        let mut transaction_field_templates = vec![];
        let mut all_transaction_fields = vec![];
        for field in options.transaction_fields.into_iter() {
            let res_name = RecordField::to_valid_rescript_name(&field.name);
            let name: CaseOptions = field.name.into();

            transaction_field_templates.push(SelectedFieldTemplate {
                name: name.clone(),
                res_name,
                default_value_rescript: field.data_type.get_default_value_rescript(),
                res_type: field.data_type.to_string(),
            });

            let record_field = RecordField::new(name.camel, field.data_type);
            all_transaction_fields.push(record_field);
        }

        let block_expr = TypeExpr::Record(all_block_fields);
        let transaction_expr = TypeExpr::Record(all_transaction_fields);

        Self {
            transaction_fields: transaction_field_templates,
            block_fields: block_field_templates,
            transaction_type: transaction_expr.to_string(),
            transaction_schema: transaction_expr.to_rescript_schema(
                &options.transaction_type_name,
                &SchemaMode::ForFieldSelection,
            ),
            block_type: block_expr.to_string(),
            block_schema: block_expr
                .to_rescript_schema(&options.block_type_name, &SchemaMode::ForFieldSelection),
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
        let mut transaction_fields: BTreeSet<_> = cfg
            .field_selection
            .transaction_fields
            .iter()
            .cloned()
            .collect();
        let mut block_fields: BTreeSet<_> =
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
    res_name: String,
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
    persisted_state: PersistedStateJsonString,
    has_multiple_events: bool,
    field_selection: FieldSelection,
    aggregated_field_selection: FieldSelection,
    is_evm_ecosystem: bool,
    is_fuel_ecosystem: bool,
    is_svm_ecosystem: bool,

    envio_version: String,
    indexer_code: String,
    internal_config_json_code: String,
    envio_dts_code: String,
    //Used for the package.json reference to handlers in generated
    relative_path_to_root_from_generated: String,
    relative_path_to_generated_from_root: String,
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

    pub fn from_config(cfg: &SystemConfig) -> Result<Self> {
        let project_paths = &cfg.parsed_project_paths;

        let codegen_contracts: Vec<ContractTemplate> = cfg
            .get_contracts()
            .iter()
            .map(|cfg_contract| ContractTemplate::from_config_contract(cfg_contract, cfg))
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
            .get_chains()
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
                .context("Failed to get relative path from output directory to project root")?;

        let relative_path_to_generated_from_root = add_leading_relative_dot(
            diff_paths(&project_paths.generated, &project_paths.project_root).ok_or_else(|| {
                anyhow!("Failed to diff paths for relative_path_to_generated_from_root")
            })?,
        )
        .to_str()
        .ok_or_else(|| anyhow!("Failed converting path to str"))?
        .to_string();

        let global_field_selection = FieldSelection::global_selection(&cfg.field_selection);
        // TODO: Remove schemas for aggreaged, since they are not used in runtime
        let aggregated_field_selection = FieldSelection::aggregated_selection(cfg);

        let chain_id_cases = match &cfg.human_config {
            HumanConfig::Svm(hcfg) => hcfg
                .chains
                .iter()
                .enumerate()
                .map(|(idx, _chain)| idx.to_string())
                .collect::<Vec<_>>(),
            HumanConfig::Fuel(hcfg) => hcfg
                .chains
                .iter()
                .map(|chain| chain.id.to_string())
                .collect::<Vec<_>>(),
            HumanConfig::Evm(hcfg) => hcfg
                .chains
                .iter()
                .map(|chain| chain.id.to_string())
                .collect::<Vec<_>>(),
        };

        // Generate contract modules with event registration
        let contract_modules = codegen_contracts
            .iter()
            .map(|contract| {
                let event_modules = contract
                    .codegen_events
                    .iter()
                    .map(|event| {
                        format!(
                            "  module {} = Types.MakeRegister(Types.{}.{})",
                            event.name, contract.name.capitalized, event.name
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                format!(
                    "@genType\nmodule {} = {{\n{}\n}}",
                    contract.name.capitalized, event_modules
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");

        // Generate onBlock function with ecosystem-specific types
        let on_block_handler_type = match cfg.get_ecosystem() {
            Ecosystem::Evm => {
                "Envio.onBlockArgs<Envio.blockEvent, Types.handlerContext> => promise<unit>"
            }
            Ecosystem::Fuel => {
                "Envio.onBlockArgs<Envio.fuelBlockEvent, Types.handlerContext> => promise<unit>"
            }
            Ecosystem::Svm => "Envio.svmOnBlockArgs<Types.handlerContext> => promise<unit>",
        };

        // Generate chainId type with ecosystem-specific import from Types.ts
        let chain_id_import_name = match cfg.get_ecosystem() {
            Ecosystem::Evm => "EvmChainId",
            Ecosystem::Fuel => "FuelChainId",
            Ecosystem::Svm => "SvmChainId",
        };
        let chain_id_type = format!(
            r#"@genType.import(("./Types.ts", "{chain_id_import_name}"))
type chainId = [{}]"#,
            chain_id_cases
                .iter()
                .map(|chain_id_case| format!("#{}", chain_id_case))
                .collect::<Vec<_>>()
                .join(" | "),
        );

        let on_block_code = format!(
            r#"@genType /** Register a Block Handler. It'll be called for every block by default. */
let onBlock: (
Envio.onBlockOptions<chainId>,
{},
) => unit = (
EventRegister.onBlock: (unknown, Internal.onBlockArgs => promise<unit>) => unit
)->Utils.magic"#,
            on_block_handler_type
        );

        // Generate indexer types and value
        let indexer_contract_type = r#"/** Contract configuration with name and ABI. */
type indexerContract = {
  /** The contract name. */
  name: string,
  /** The contract ABI. */
  abi: unknown,
  /** The contract addresses. */
  addresses: array<Address.t>,
}"#;

        // Collect all unique contract names across chains
        let mut all_contract_names = BTreeSet::new();
        for chain_config in &chain_configs {
            for contract in &chain_config.codegen_contracts {
                all_contract_names.insert(contract.name.original.clone());
            }
        }

        // Generate contract fields - use quoted names to avoid ReScript naming issues
        let contract_fields = if all_contract_names.is_empty() {
            String::new()
        } else {
            all_contract_names
                .iter()
                .map(|contract_name| format!("\n  \\\"{}\": indexerContract,", contract_name))
                .collect::<Vec<String>>()
                .join("")
        };

        // Generate indexer chain type with contract fields
        let indexer_chain_type = format!(
            r#"/** Per-chain configuration for the indexer. */
type indexerChain = {{
  /** The chain ID. */
  id: chainId,
  /** The chain name. */
  name: string,
  /** The block number to start indexing from. */
  startBlock: int,
  /** The block number to stop indexing at (if specified). */
  endBlock: option<int>,
  /** Whether the chain has completed initial sync and is processing live events. */
  isLive: bool,{contract_fields}
}}"#
        );

        // Generate indexerChains type with fields for each chain
        let indexer_chains_fields = chain_configs
            .iter()
            .map(|chain| {
                let id = chain.network_config.id;
                let id_field = format!("  @as(\"{}\") chain{}: indexerChain,", id, id);
                // Add name-based field only for known networks
                if let Ok(network) = Network::from_network_id(id) {
                    let name = network.to_string().to_case(Case::Camel);
                    format!("{}\n  {}: indexerChain,", id_field, name)
                } else {
                    id_field
                }
            })
            .collect::<Vec<_>>()
            .join("\n");

        let indexer_chains_type = format!(
            r#"/** Strongly-typed record of chain configurations keyed by chain ID. */
type indexerChains = {{
{}
}}"#,
            indexer_chains_fields
        );

        let indexer_type = r#"/** Metadata and configuration for the indexer. */
type indexer = {
  /** The name of the indexer from config.yaml. */
  name: string,
  /** The description of the indexer from config.yaml. */
  description: option<string>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
}"#;

        // Generate indexer value using Main.getGlobalIndexer
        let indexer_value = r#"let indexer: indexer = Main.getGlobalIndexer(~config=Generated.configWithoutRegistrations)"#;

        // Generate getChainById function
        let get_chain_by_id_cases = chain_configs
            .iter()
            .map(|chain| {
                format!(
                    "  | #{} => indexer.chains.chain{}",
                    chain.network_config.id, chain.network_config.id
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        let get_chain_by_id = format!(
            r#"/** Get chain configuration by chain ID with exhaustive pattern matching. */
let getChainById = (indexer: indexer, chainId: chainId): indexerChain => {{
switch chainId {{
{}
}}
}}"#,
            get_chain_by_id_cases
        );

        // Combine all parts into indexer_code
        let indexer_code = format!(
            "{}\n\n{}\n\n{}\n\n{}\n\n{}\n\n{}\n\n{}\n\n{}",
            contract_modules,
            chain_id_type,
            indexer_contract_type,
            indexer_chain_type,
            indexer_chains_type,
            indexer_type,
            indexer_value,
            get_chain_by_id,
        );

        // Add onBlock at the end
        let indexer_code = format!("{}\n\n{}", indexer_code, on_block_code);

        // Generate testIndexer types and createTestIndexer
        let test_indexer_chains_fields = chain_configs
            .iter()
            .map(|chain| {
                let id = chain.network_config.id;
                format!("  @as(\"{}\") chain{}?: TestIndexer.chainConfig,", id, id)
            })
            .collect::<Vec<_>>()
            .join("\n");

        let test_indexer_code = format!(
            r#"type testIndexerProcessConfigChains = {{
{}
}}

type testIndexerProcessConfig = {{
  chains: testIndexerProcessConfigChains,
}}

let createTestIndexer: unit => TestIndexer.t<testIndexerProcessConfig> = TestIndexer.makeCreateTestIndexer(~config=Generated.configWithoutRegistrations, ~workerPath=NodeJs.Path.join(NodeJs.Path.dirname(NodeJs.Url.fileURLToPath(NodeJs.ImportMeta.importMeta.url)), "TestIndexerWorker.res.mjs")->NodeJs.Path.toString, ~allEntities=Generated.codegenPersistence.allEntities)"#,
            test_indexer_chains_fields
        );

        let indexer_code = format!("{}\n\n{}", indexer_code, test_indexer_code);

        // Helper function to convert kebab-case to camelCase
        let kebab_to_camel = |s: &str| -> String { s.to_case(Case::Camel) };

        // Helper function to convert chain ID to chain name
        let chain_id_to_name = |chain_id: u64, ecosystem: &Ecosystem| -> String {
            match ecosystem {
                Ecosystem::Evm => Network::from_repr(chain_id)
                    .map(|n| kebab_to_camel(&n.to_string()))
                    .unwrap_or_else(|| chain_id.to_string()),
                Ecosystem::Fuel => {
                    // For Fuel, use chain ID directly when no proper name exists
                    chain_id.to_string()
                }
                Ecosystem::Svm => {
                    // For SVM, use chain ID directly when no proper name exists
                    chain_id.to_string()
                }
            }
        };

        // Generate internal.config.json content using serde
        let internal_config_json_code = {
            // Build chains map
            let chains: std::collections::BTreeMap<String, InternalChainConfig> = chain_configs
                .iter()
                .map(|chain_config| {
                    let chain_name =
                        chain_id_to_name(chain_config.network_config.id, &cfg.get_ecosystem());
                    (
                        chain_name,
                        InternalChainConfig {
                            id: chain_config.network_config.id,
                            start_block: chain_config.network_config.start_block,
                            end_block: chain_config.network_config.end_block,
                            max_reorg_depth: chain_config.network_config.max_reorg_depth,
                        },
                    )
                })
                .collect();

            // Build contracts map
            let contracts: std::collections::BTreeMap<&str, InternalContractConfig> = cfg
                .contracts
                .values()
                .map(|contract| -> Result<(&str, InternalContractConfig)> {
                    // Parse and re-serialize compactly to ensure one-liner format
                    let abi_str = match &contract.abi {
                        Abi::Evm(abi) => &abi.raw,
                        Abi::Fuel(abi) => &abi.raw,
                    };
                    let abi_value: serde_json::Value = serde_json::from_str(abi_str)?;
                    let abi_compact = serde_json::to_string(&abi_value)?;
                    let abi_raw = serde_json::value::RawValue::from_string(abi_compact)?;
                    Ok((
                        contract.name.as_str(),
                        InternalContractConfig { abi: abi_raw },
                    ))
                })
                .collect::<Result<_>>()?;

            // Build ecosystem config
            let (evm, fuel, svm) = match cfg.get_ecosystem() {
                Ecosystem::Evm => (
                    Some(InternalEvmConfig {
                        chains,
                        contracts,
                        address_format: if cfg.lowercase_addresses {
                            "lowercase"
                        } else {
                            "checksum"
                        },
                        event_decoder: "hypersync",
                    }),
                    None,
                    None,
                ),
                Ecosystem::Fuel => (None, Some(InternalFuelConfig { chains, contracts }), None),
                Ecosystem::Svm => (None, None, Some(InternalSvmConfig { chains })),
            };

            // Build multichain value
            let multichain = match cfg.multichain {
                crate::config_parsing::human_config::evm::Multichain::Ordered => Some("ordered"),
                crate::config_parsing::human_config::evm::Multichain::Unordered => None,
            };

            let config = InternalConfigJson {
                name: &cfg.name,
                description: cfg.human_config.get_base_config().description.as_deref(),
                handlers: cfg.handlers.as_deref(),
                multichain,
                full_batch_size: cfg.human_config.get_base_config().full_batch_size,
                rollback_on_reorg: cfg.rollback_on_reorg,
                save_full_history: cfg.save_full_history,
                raw_events: cfg.enable_raw_events,
                evm,
                fuel,
                svm,
            };

            serde_json::to_string_pretty(&config)? + "\n"
        };

        // Generate envio.d.ts content (type declarations only)
        // Always export all ecosystem types, even when empty
        let envio_dts_code = {
            let mut parts = Vec::new();

            // Generate EvmChains type
            let evm_chains_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Evm {
                chain_configs
                    .iter()
                    .map(|chain_config| {
                        let chain_name =
                            chain_id_to_name(chain_config.network_config.id, &Ecosystem::Evm);
                        format!(
                            "  \"{}\": {{ id: {} }};",
                            chain_name, chain_config.network_config.id
                        )
                    })
                    .collect()
            } else {
                vec![]
            };
            parts.push(if evm_chains_entries.is_empty() {
                "export type EvmChains = {};".to_string()
            } else {
                format!(
                    "export type EvmChains = {{\n{}\n}};",
                    evm_chains_entries.join("\n")
                )
            });

            // Generate EvmContracts type
            let evm_contracts_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Evm {
                cfg.contracts
                    .keys()
                    .map(|name| format!("  \"{}\": {{}};", name))
                    .collect()
            } else {
                vec![]
            };
            parts.push(if evm_contracts_entries.is_empty() {
                "export type EvmContracts = {};".to_string()
            } else {
                format!(
                    "export type EvmContracts = {{\n{}\n}};",
                    evm_contracts_entries.join("\n")
                )
            });

            // Generate FuelChains type
            let fuel_chains_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Fuel {
                chain_configs
                    .iter()
                    .map(|chain_config| {
                        let chain_name =
                            chain_id_to_name(chain_config.network_config.id, &Ecosystem::Fuel);
                        format!(
                            "  \"{}\": {{ id: {} }};",
                            chain_name, chain_config.network_config.id
                        )
                    })
                    .collect()
            } else {
                vec![]
            };
            parts.push(if fuel_chains_entries.is_empty() {
                "export type FuelChains = {};".to_string()
            } else {
                format!(
                    "export type FuelChains = {{\n{}\n}};",
                    fuel_chains_entries.join("\n")
                )
            });

            // Generate FuelContracts type
            let fuel_contracts_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Fuel {
                cfg.contracts
                    .keys()
                    .map(|name| format!("  \"{}\": {{}};", name))
                    .collect()
            } else {
                vec![]
            };
            parts.push(if fuel_contracts_entries.is_empty() {
                "export type FuelContracts = {};".to_string()
            } else {
                format!(
                    "export type FuelContracts = {{\n{}\n}};",
                    fuel_contracts_entries.join("\n")
                )
            });

            // Generate SvmChains type
            let svm_chains_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Svm {
                chain_configs
                    .iter()
                    .map(|chain_config| {
                        let chain_name =
                            chain_id_to_name(chain_config.network_config.id, &Ecosystem::Svm);
                        format!(
                            "  \"{}\": {{ id: {} }};",
                            chain_name, chain_config.network_config.id
                        )
                    })
                    .collect()
            } else {
                vec![]
            };
            parts.push(if svm_chains_entries.is_empty() {
                "export type SvmChains = {};".to_string()
            } else {
                format!(
                    "export type SvmChains = {{\n{}\n}};",
                    svm_chains_entries.join("\n")
                )
            });

            parts.join("\n")
        };

        Ok(ProjectTemplate {
            project_name: cfg.name.clone(),
            codegen_contracts,
            entities,
            gql_enums,
            chain_configs,
            persisted_state,
            has_multiple_events,
            field_selection: global_field_selection,
            aggregated_field_selection,
            is_evm_ecosystem: cfg.get_ecosystem() == Ecosystem::Evm,
            is_fuel_ecosystem: cfg.get_ecosystem() == Ecosystem::Fuel,
            is_svm_ecosystem: cfg.get_ecosystem() == Ecosystem::Svm,
            envio_version: get_envio_version()?,
            indexer_code,
            internal_config_json_code,
            envio_dts_code,
            //Used for the package.json reference to handlers in generated
            relative_path_to_root_from_generated,
            relative_path_to_generated_from_root,
        })
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::{
        config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths,
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

        super::ProjectTemplate::from_config(&config)
            .expect("should be able to get project template")
    }

    #[test]
    fn chain_configs_parsed_case_fuel() {
        let address1 =
            String::from("0x4a2ce054e3e94155f7092f7365b212f7f45105b74819c623744ebcc5d065c6ac");

        let network1 = NetworkTemplate {
            id: 0,
            ..NetworkTemplate::default()
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGreeting", "ClearGreeting"]);
        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Greeter").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
            start_block: None,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
          network_config: network1,
          codegen_contracts: vec![contract1],
          sources_code: "[HyperFuelSource.make({chain, endpointUrl: \"https://fuel-testnet.hypersync.xyz\"})]".to_string(),
      };

        let expected_chain_configs = vec![chain_config_1];

        let project_template = get_project_template_helper("fuel-config.yaml");

        assert_eq!(
            project_template.relative_path_to_root_from_generated,
            "../.".to_string()
        );
        assert_eq!(
          project_template.relative_path_to_generated_from_root,
          "./generated".to_string(),
          "relative_path_to_generated_from_root should start with ./ for Node.js module resolution"
      );

        assert_eq!(
            expected_chain_configs[0].network_config,
            project_template.chain_configs[0].network_config
        );
        assert_eq!(expected_chain_configs, project_template.chain_configs,);
    }

    #[test]
    fn chain_configs_parsed_case_1() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let network1 = NetworkTemplate {
            id: 1,
            ..NetworkTemplate::default()
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);
        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
            start_block: None,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
          network_config: network1,
          codegen_contracts: vec![contract1],
          sources_code: "EvmChain.makeSources(~chain, ~contracts=[{name: \"Contract1\",events: [Types.Contract1.NewGravatar.register(), Types.Contract1.UpdatedGravatar.register()],abi: Types.Contract1.abi}], ~hyperSync=None, ~allEventSignatures=[Types.Contract1.eventSignatures]->Belt.Array.concatMany, ~rpcs=[{url: \"https://eth.com\", sourceFor: Sync, syncConfig: {accelerationAdditive: 2000,initialBlockInterval: 10000,backoffMultiplicative: 0.8,intervalCeiling: 10000,backoffMillis: 5000,queryTimeoutMillis: 20000,}}], ~lowercaseAddresses=false)".to_string(),
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
        assert_eq!(expected_chain_configs, project_template.chain_configs);
    }

    #[tokio::test]
    async fn chain_configs_parsed_case_2() {
        let address1 = String::from("0x2E645469f354BB4F5c8a05B3b30A929361cf77eC");
        let address2 = String::from("0x1E645469f354BB4F5c8a05B3b30A929361cf77eC");

        let network1 = NetworkTemplate {
            id: 1,
            ..NetworkTemplate::default()
        };

        let network2 = NetworkTemplate {
            id: 2,
            ..NetworkTemplate::default()
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);
        let contract1_on_chain1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events: events.clone(),
            start_block: None,
        };

        let contract2_on_chain1 = super::PerNetworkContractTemplate {
            name: String::from("Contract2").to_capitalized_options(),
            addresses: vec![],
            events: events.clone(),
            start_block: None,
        };

        let contract1_on_chain2 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![],
            events: events.clone(),
            start_block: None,
        };

        let contract2_on_chain2 = super::PerNetworkContractTemplate {
            name: String::from("Contract2").to_capitalized_options(),
            addresses: vec![address2.clone()],
            events: events.clone(),
            start_block: None,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
          network_config: network1,
          codegen_contracts: vec![contract1_on_chain1, contract2_on_chain1],
          sources_code: "EvmChain.makeSources(~chain, ~contracts=[{name: \"Contract1\",events: [Types.Contract1.NewGravatar.register(), Types.Contract1.UpdatedGravatar.register()],abi: Types.Contract1.abi}, {name: \"Contract2\",events: [Types.Contract2.NewGravatar.register(), Types.Contract2.UpdatedGravatar.register()],abi: Types.Contract2.abi}], ~hyperSync=None, ~allEventSignatures=[Types.Contract1.eventSignatures, Types.Contract2.eventSignatures]->Belt.Array.concatMany, ~rpcs=[{url: \"https://eth.com\", sourceFor: Sync, syncConfig: {accelerationAdditive: 2000,initialBlockInterval: 10000,backoffMultiplicative: 0.8,intervalCeiling: 10000,backoffMillis: 5000,queryTimeoutMillis: 20000,}}], ~lowercaseAddresses=false)".to_string(),
      };
        let chain_config_2 = super::NetworkConfigTemplate {
          network_config: network2,
          codegen_contracts: vec![contract1_on_chain2, contract2_on_chain2],
          sources_code: "EvmChain.makeSources(~chain, ~contracts=[{name: \"Contract1\",events: [Types.Contract1.NewGravatar.register(), Types.Contract1.UpdatedGravatar.register()],abi: Types.Contract1.abi}, {name: \"Contract2\",events: [Types.Contract2.NewGravatar.register(), Types.Contract2.UpdatedGravatar.register()],abi: Types.Contract2.abi}], ~hyperSync=None, ~allEventSignatures=[Types.Contract1.eventSignatures, Types.Contract2.eventSignatures]->Belt.Array.concatMany, ~rpcs=[{url: \"https://eth.com\", sourceFor: Sync, syncConfig: {accelerationAdditive: 2000,initialBlockInterval: 10000,backoffMultiplicative: 0.8,intervalCeiling: 10000,backoffMillis: 5000,queryTimeoutMillis: 20000,}}, {url: \"https://eth.com/fallback\", sourceFor: Sync, syncConfig: {accelerationAdditive: 2000,initialBlockInterval: 10000,backoffMultiplicative: 0.8,intervalCeiling: 10000,backoffMillis: 5000,queryTimeoutMillis: 20000,}}], ~lowercaseAddresses=false)".to_string(),
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
            ..NetworkTemplate::default()
        };

        let events = get_per_contract_events_vec_helper(vec!["NewGravatar", "UpdatedGravatar"]);

        let contract1 = super::PerNetworkContractTemplate {
            name: String::from("Contract1").to_capitalized_options(),
            addresses: vec![address1.clone()],
            events,
            start_block: None,
        };

        let chain_config_1 = super::NetworkConfigTemplate {
          network_config: network1,
          codegen_contracts: vec![contract1],
          sources_code: "EvmChain.makeSources(~chain, ~contracts=[{name: \"Contract1\",events: [Types.Contract1.NewGravatar.register(), Types.Contract1.UpdatedGravatar.register()],abi: Types.Contract1.abi}], ~hyperSync=Some(\"https://1.hypersync.xyz\"), ~allEventSignatures=[Types.Contract1.eventSignatures]->Belt.Array.concatMany, ~rpcs=[{url: \"https://fallback.eth.com\", sourceFor: Fallback, syncConfig: {}}], ~lowercaseAddresses=false)".to_string(),
      };

        let expected_chain_configs = vec![chain_config_1];

        let project_template = get_project_template_helper("config3.yaml");

        assert_eq!(expected_chain_configs, project_template.chain_configs);
    }

    #[test]
    fn convert_to_chain_configs_case_4() {
        let network1 = NetworkTemplate {
            id: 1,
            ..NetworkTemplate::default()
        };

        let network2 = NetworkTemplate {
            id: 137,
            ..NetworkTemplate::default()
        };

        let chain_config_1 = super::NetworkConfigTemplate {
          network_config: network1,
          codegen_contracts: vec![],
          sources_code: "EvmChain.makeSources(~chain, ~contracts=[], ~hyperSync=Some(\"https://myskar.com\"), \
               ~allEventSignatures=[]->Belt.Array.concatMany, \
               ~rpcs=[], ~lowercaseAddresses=false)".to_string(),
      };

        let chain_config_2 = super::NetworkConfigTemplate {
          network_config: network2,
          codegen_contracts: vec![],
          sources_code: "EvmChain.makeSources(~chain, ~contracts=[], ~hyperSync=Some(\"https://137.hypersync.xyz\"), ~allEventSignatures=[]->Belt.Array.concatMany, ~rpcs=[], ~lowercaseAddresses=false)".to_string(),
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

    const RESCRIPT_BIG_INT_TYPE: TypeIdent = TypeIdent::BigInt;
    const RESCRIPT_ADDRESS_TYPE: TypeIdent = TypeIdent::Address;
    const RESCRIPT_STRING_TYPE: TypeIdent = TypeIdent::String;

    impl EventParamTypeTemplate {
        fn new(name: &str, res_type: TypeIdent) -> Self {
            let js_name = name.to_string();
            Self {
                res_name: RecordField::to_valid_rescript_name(&js_name),
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
let id = "{sighash}_1"
let sighash = "{sighash}"
let name = "NewGravatar"
let contractName = contractName

@genType
type eventArgs = {{id: bigint, owner: Address.t, displayName: string, imageUrl: string}}
@genType
type block = Block.t
@genType
type transaction = Transaction.t

@genType
type event = {{
/** The parameters or arguments associated with this event. */
params: eventArgs,
/** The unique identifier of the blockchain network where this event occurred. */
chainId: chainId,
/** The address of the contract that emitted this event. */
srcAddress: Address.t,
/** The index of this event's log within the block. */
logIndex: int,
/** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
transaction: transaction,
/** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
block: block,
}}

@genType
type handlerArgs = Internal.genericHandlerArgs<event, handlerContext>
@genType
type handler = Internal.genericHandler<handlerArgs>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = S.object((s): eventArgs => {{id: s.field("id", BigInt.schema), owner: s.field("owner", Address.schema), displayName: s.field("displayName", S.string), imageUrl: s.field("imageUrl", S.string)}})
let blockSchema = Block.schema
let transactionSchema = Transaction.schema

let handlerRegister: EventRegister.t = EventRegister.make(
~contractName,
~eventName=name,
)

@genType
type eventFilter = {{}}

@genType type eventFilters = Internal.noEventFilters

let register = (): Internal.evmEventConfig => {{
let {{getEventFiltersOrThrow, filterByAddresses}} = LogSelection.parseEventFiltersOrThrow(~eventFilters=handlerRegister->EventRegister.getEventFilters, ~sighash, ~params=[])
{{
  getEventFiltersOrThrow,
  filterByAddresses,
  dependsOnAddresses: !(handlerRegister->EventRegister.isWildcard) || filterByAddresses,
  blockSchema: blockSchema->(Utils.magic: S.t<block> => S.t<Internal.eventBlock>),
  transactionSchema: transactionSchema->(Utils.magic: S.t<transaction> => S.t<Internal.eventTransaction>),
  convertHyperSyncEventArgs: (decodedEvent: HyperSyncClient.Decoder.decodedEvent) => {{id: decodedEvent.body->Js.Array2.unsafe_get(0)->HyperSyncClient.Decoder.toUnderlying->Utils.magic, owner: decodedEvent.body->Js.Array2.unsafe_get(1)->HyperSyncClient.Decoder.toUnderlying->Utils.magic, displayName: decodedEvent.body->Js.Array2.unsafe_get(2)->HyperSyncClient.Decoder.toUnderlying->Utils.magic, imageUrl: decodedEvent.body->Js.Array2.unsafe_get(3)->HyperSyncClient.Decoder.toUnderlying->Utils.magic, }}->(Utils.magic: eventArgs => Internal.eventParams),
  id,
name,
contractName,
isWildcard: (handlerRegister->EventRegister.isWildcard),
handler: handlerRegister->EventRegister.getHandler,
contractRegister: handlerRegister->EventRegister.getContractRegister,
paramsRawEventSchema: paramsRawEventSchema->(Utils.magic: S.t<eventArgs> => S.t<Internal.eventParams>),
}}
}}"#
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
              module_code: r#"
let id = "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363_1"
let sighash = "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
let name = "NewGravatar"
let contractName = contractName

@genType
type eventArgs = unit
@genType
type block = Block.t
@genType
type transaction = Transaction.t

@genType
type event = {
/** The parameters or arguments associated with this event. */
params: eventArgs,
/** The unique identifier of the blockchain network where this event occurred. */
chainId: chainId,
/** The address of the contract that emitted this event. */
srcAddress: Address.t,
/** The index of this event's log within the block. */
logIndex: int,
/** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
transaction: transaction,
/** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
block: block,
}

@genType
type handlerArgs = Internal.genericHandlerArgs<event, handlerContext>
@genType
type handler = Internal.genericHandler<handlerArgs>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = S.literal(%raw(`null`))->S.shape(_ => ())
let blockSchema = Block.schema
let transactionSchema = Transaction.schema

let handlerRegister: EventRegister.t = EventRegister.make(
~contractName,
~eventName=name,
)

@genType
type eventFilter = {}

@genType type eventFilters = Internal.noEventFilters

let register = (): Internal.evmEventConfig => {
let {getEventFiltersOrThrow, filterByAddresses} = LogSelection.parseEventFiltersOrThrow(~eventFilters=handlerRegister->EventRegister.getEventFilters, ~sighash, ~params=[])
{
  getEventFiltersOrThrow,
  filterByAddresses,
  dependsOnAddresses: !(handlerRegister->EventRegister.isWildcard) || filterByAddresses,
  blockSchema: blockSchema->(Utils.magic: S.t<block> => S.t<Internal.eventBlock>),
  transactionSchema: transactionSchema->(Utils.magic: S.t<transaction> => S.t<Internal.eventTransaction>),
  convertHyperSyncEventArgs: _ => ()->(Utils.magic: eventArgs => Internal.eventParams),
  id,
name,
contractName,
isWildcard: (handlerRegister->EventRegister.isWildcard),
handler: handlerRegister->EventRegister.getHandler,
contractRegister: handlerRegister->EventRegister.getContractRegister,
paramsRawEventSchema: paramsRawEventSchema->(Utils.magic: S.t<eventArgs> => S.t<Internal.eventParams>),
}
}"#.to_string(),
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
                    data_type: TypeIdent::option(TypeIdent::Address),
                }],
            }),
        })
        .unwrap();

        assert_eq!(
          event_template,
          EventTemplate {
              name: "NewGravatar".to_string(),
              params: vec![],
              module_code: r#"
let id = "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363_1"
let sighash = "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
let name = "NewGravatar"
let contractName = contractName

@genType
type eventArgs = unit
@genType
type block = {}
@genType
type transaction = {from: option<Address.t>}

@genType
type event = {
/** The parameters or arguments associated with this event. */
params: eventArgs,
/** The unique identifier of the blockchain network where this event occurred. */
chainId: chainId,
/** The address of the contract that emitted this event. */
srcAddress: Address.t,
/** The index of this event's log within the block. */
logIndex: int,
/** The transaction that triggered this event. Configurable in `config.yaml` via the `field_selection` option. */
transaction: transaction,
/** The block in which this event was recorded. Configurable in `config.yaml` via the `field_selection` option. */
block: block,
}

@genType
type handlerArgs = Internal.genericHandlerArgs<event, handlerContext>
@genType
type handler = Internal.genericHandler<handlerArgs>
@genType
type contractRegister = Internal.genericContractRegister<Internal.genericContractRegisterArgs<event, contractRegistrations>>

let paramsRawEventSchema = S.literal(%raw(`null`))->S.shape(_ => ())
let blockSchema = S.object((_): block => {})
let transactionSchema = S.object((s): transaction => {from: s.field("from", S.nullable(Address.schema))})

let handlerRegister: EventRegister.t = EventRegister.make(
~contractName,
~eventName=name,
)

@genType
type eventFilter = {}

@genType type eventFilters = Internal.noEventFilters

let register = (): Internal.evmEventConfig => {
let {getEventFiltersOrThrow, filterByAddresses} = LogSelection.parseEventFiltersOrThrow(~eventFilters=handlerRegister->EventRegister.getEventFilters, ~sighash, ~params=[])
{
  getEventFiltersOrThrow,
  filterByAddresses,
  dependsOnAddresses: !(handlerRegister->EventRegister.isWildcard) || filterByAddresses,
  blockSchema: blockSchema->(Utils.magic: S.t<block> => S.t<Internal.eventBlock>),
  transactionSchema: transactionSchema->(Utils.magic: S.t<transaction> => S.t<Internal.eventTransaction>),
  convertHyperSyncEventArgs: _ => ()->(Utils.magic: eventArgs => Internal.eventParams),
  id,
name,
contractName,
isWildcard: (handlerRegister->EventRegister.isWildcard),
handler: handlerRegister->EventRegister.getHandler,
contractRegister: handlerRegister->EventRegister.getContractRegister,
paramsRawEventSchema: paramsRawEventSchema->(Utils.magic: S.t<eventArgs> => S.t<Internal.eventParams>),
}
}"#.to_string(),
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

    #[test]
    fn internal_config_json_code_generated_for_evm() {
        let project_template = get_project_template_helper("config1.yaml");
        insta::assert_snapshot!(project_template.internal_config_json_code);
    }

    #[test]
    fn internal_config_json_code_generated_for_fuel() {
        let project_template = get_project_template_helper("fuel-config.yaml");
        // Note: Fuel defaults to rollback_on_reorg: false in system_config.rs,
        // which differs from the runtime default of true, so it's included
        insta::assert_snapshot!(project_template.internal_config_json_code);
    }

    #[test]
    fn internal_config_json_code_with_all_options() {
        let project_template = get_project_template_helper("config-with-all-options.yaml");
        insta::assert_snapshot!(project_template.internal_config_json_code);
    }

    #[test]
    fn internal_config_json_code_omits_default_values() {
        let project_template = get_project_template_helper("config1.yaml");
        insta::assert_snapshot!(project_template.internal_config_json_code);
    }

    #[test]
    fn envio_dts_code_generated_for_evm() {
        let project_template = get_project_template_helper("config1.yaml");
        insta::assert_snapshot!(project_template.envio_dts_code);
    }

    #[test]
    fn envio_dts_code_generated_for_fuel() {
        let project_template = get_project_template_helper("fuel-config.yaml");
        insta::assert_snapshot!(project_template.envio_dts_code);
    }

    #[test]
    fn internal_config_json_code_with_no_contracts() {
        // config4.yaml has empty contracts array - tests that comma is properly
        // placed before addressFormat when contracts section is omitted
        let project_template = get_project_template_helper("config4.yaml");
        insta::assert_snapshot!(project_template.internal_config_json_code);
    }

    #[test]
    fn internal_config_json_code_with_multiple_contracts() {
        // config2.yaml has two contracts - tests comma separation between contracts
        let project_template = get_project_template_helper("config2.yaml");
        insta::assert_snapshot!(project_template.internal_config_json_code);
    }

    #[test]
    fn indexer_code_generates_correct_types_and_values() {
        let project_template = get_project_template_helper("config1.yaml");
        insta::assert_snapshot!(project_template.indexer_code);
    }

    #[test]
    fn indexer_code_multiple_chains() {
        // config2.yaml has chain IDs 1 (known: ethereum-mainnet) and 2 (unknown)
        let project_template = get_project_template_helper("config2.yaml");
        insta::assert_snapshot!(project_template.indexer_code);
    }
}
