use std::{
    collections::BTreeSet,
    fmt::{Display, Write},
    vec,
};

use crate::{
    config_parsing::{
        chain_helpers::Network,
        entity_parsing::{Entity, Field, GraphQLEnum, IndexField, IndexFieldDirection},
        event_parsing::abi_to_rescript_type,
        field_types,
        human_config::HumanConfig,
        system_config::{
            self, Abi, Ecosystem, EventKind, FuelEventKind, SelectedField, SystemConfig,
        },
    },
    constants::project_paths::{ENVIO_ENV_DTS_FILE, ENVIO_TYPES_FILE},
    project_paths::ParsedProjectPaths,
    type_schema::{RecordField, TypeExpr, TypeIdent},
    utils::text::{Capitalize, CapitalizedOptions, CaseOptions},
};
use anyhow::{Context, Result};
use convert_case::{Case, Casing};

use crate::config_parsing::abi_compat::EventParam;
use serde::Serialize;

fn indent(code: &str) -> String {
    code.lines()
        .map(|line| {
            if line.is_empty() {
                String::new()
            } else {
                format!("  {}", line)
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// ============== Template Types ==============

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

fn generate_enums_code(gql_enums: &[GraphQlEnumTypeTemplate]) -> String {
    let mut code = String::new();

    for gql_enum in gql_enums {
        writeln!(code, "module {} = {{", gql_enum.name.capitalized).unwrap();
        writeln!(code, "  type t =").unwrap();
        for param in &gql_enum.params {
            writeln!(
                code,
                "    | @as(\"{}\") {}",
                param.original, param.capitalized
            )
            .unwrap();
        }
        writeln!(code, "}}").unwrap();
    }

    code
}

fn generate_entities_code(entities: &[EntityRecordTypeTemplate]) -> String {
    let mut code = String::new();

    writeln!(code, "type id = string").unwrap();

    for entity in entities {
        writeln!(code).unwrap();
        writeln!(code, "module {} = {{", entity.name.capitalized).unwrap();
        writeln!(code, "  type t = {}", entity.type_code).unwrap();
        writeln!(code).unwrap();
        writeln!(
            code,
            "  type getWhereFilter = {}",
            entity.get_where_filter_code
        )
        .unwrap();
        writeln!(code, "}}").unwrap();
    }

    if !entities.is_empty() {
        writeln!(code).unwrap();
        writeln!(code, "type rec name<'entity> =").unwrap();
        for entity in entities {
            writeln!(
                code,
                "  | @as(\"{0}\") {0}: name<{0}.t>",
                entity.name.capitalized
            )
            .unwrap();
        }
    }

    code
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityParamTypeTemplate {
    pub field_name: CapitalizedOptions,
    #[serde(rename = "res_type")]
    pub field_type: TypeIdent,
    pub is_entity_field: bool,
    pub is_indexed_field: bool,
    ///Used to determine if you can run a where
    ///query on this field.
    pub is_queryable_field: bool,
    /// Whether this field is derived from another entity (not stored in DB).
    pub is_derived_field: bool,
}

impl EntityParamTypeTemplate {
    fn from_entity_field(field: &Field, entity: &Entity, config: &SystemConfig) -> Result<Self> {
        let field_type: TypeIdent = field
            .field_type
            .to_rescript_type(&config.schema)
            .context("Failed getting rescript type")?;

        let schema = &config.schema;

        let is_entity_field = field.field_type.is_entity_field(schema)?;
        let is_indexed_field = field.is_indexed_field(entity);
        let is_derived_lookup_field = field.is_derived_lookup_field(entity, schema);
        let is_derived_field = field.field_type.is_derived_from();

        //Both of these cases have indexes on them and should exist
        let is_queryable_field = is_indexed_field || is_derived_lookup_field;

        Ok(EntityParamTypeTemplate {
            field_name: field.name.to_capitalized_options(),
            field_type,
            is_entity_field,
            is_indexed_field,
            is_queryable_field,
            is_derived_field,
        })
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct DerivedFieldTemplate {
    pub field_name: String,
    pub derived_from_entity: String,
    pub derived_from_field: String,
    pub description: Option<String>,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct CompositeIndexFieldTemplate {
    pub field_name: String,
    pub direction: String,
}

impl CompositeIndexFieldTemplate {
    fn from_index_field(index_field: &IndexField) -> Self {
        Self {
            field_name: index_field.name.clone(),
            direction: match index_field.direction {
                IndexFieldDirection::Asc => "Asc".to_string(),
                IndexFieldDirection::Desc => "Desc".to_string(),
            },
        }
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub type_code: String,
    pub get_where_filter_code: String,
    pub postgres_fields: Vec<field_types::Field>,
    pub composite_indices: Vec<Vec<CompositeIndexFieldTemplate>>,
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

        let type_code = TypeExpr::Record(record_fields).to_string();

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

        let composite_indices = entity
            .get_composite_indices()
            .into_iter()
            .map(|fields| {
                fields
                    .iter()
                    .map(CompositeIndexFieldTemplate::from_index_field)
                    .collect()
            })
            .collect();

        // Generate getWhereFilter type code for ReScript (all non-derived fields)
        // Non-indexed fields will throw a user-friendly error at runtime
        // Entity fields use original name (e.g. "owner") with @as("owner_id") to avoid
        // name collision with entity record type t which uses "owner_id" as field name
        let get_where_filter_fields: Vec<String> = params
            .iter()
            .filter(|p| !p.is_derived_field)
            .map(|p| {
                let field_name = RecordField::to_valid_rescript_name(&p.field_name.uncapitalized);
                let as_name = if p.is_entity_field {
                    format!("{}_id", p.field_name.original)
                } else {
                    p.field_name.original.clone()
                };
                format!(
                    "@as(\"{}\") {}?: Envio.whereOperator<{}>",
                    as_name, field_name, p.field_type
                )
            })
            .collect();
        let get_where_filter_code = format!("{{{}}}", get_where_filter_fields.join(", "));

        Ok(EntityRecordTypeTemplate {
            name: entity.name.to_capitalized_options(),
            postgres_fields,
            type_code,
            get_where_filter_code,
            derived_fields,
            composite_indices,
            params,
        })
    }
}

#[derive(Debug, PartialEq, Clone)]
pub struct EventMod {
    pub event_name: String,
    pub data_type: String,
    pub event_filter_type: String,
    pub custom_field_selection: Option<system_config::FieldSelection>,
    pub all_ecosystem_fields: Option<FieldSelection>,
    pub params_constructor_type: String,
    pub contract_name: CapitalizedOptions,
}

impl Display for EventMod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.to_string_internal())
    }
}

impl EventMod {
    fn to_string_internal(&self) -> String {
        let event_name = &self.event_name;
        let data_type = &self.data_type;
        let where_params_type = &self.event_filter_type;

        // The `where` option in ReScript is *always* a callback. The callback
        // receives the chain id and registered addresses and returns either a
        // `whereCondition` (filter to apply) or a boolean (`KeepAll` / `SkipAll`)
        // for per-invocation short-circuiting. OR semantics across multiple
        // filter shapes are expressed inside `params` itself via
        // `SingleOrMultiple` — there's no top-level `Multiple` constructor.
        //
        // The `block` sibling carries the per-event startBlock override
        // (`block.number._gte` → overrides contract `start_block`). Only
        // `_gte` is valid; `_lte` / `_every` are rejected at registration
        // time and aren't part of the generated type.
        //
        // - Events with no indexed params (Fuel, or EVM events without indexed
        //   fields) get the `Internal.noOnEventWhere` stub so the option field
        //   exists but cannot be populated.
        // - TypeScript additionally accepts the static object form (just the
        //   `whereCondition` directly) — see `OnEventWhere<P>` in
        //   `packages/envio/index.d.ts`. The runtime parser handles both shapes.
        let where_type_code = match self.event_filter_type.as_str() {
            "{}" => "type onEventWhere = Internal.noOnEventWhere".to_string(),
            _ => format!(
                "type onEventWhereBlockNumber = {{_gte?: int}}\n\
type onEventWhereBlock = {{number?: onEventWhereBlockNumber}}\n\
type onEventWhereFilter = {{params?: SingleOrMultiple.t<whereParams>, block?: onEventWhereBlock}}\n\
type onEventWhereChainContract = {{/** Addresses of the {contract_capitalized} contract on this chain. */ addresses: array<Address.t>}}\n\
type onEventWhereChain = {{/** The unique identifier of the blockchain network where this event occurred. */ id: chainId, \\\"{contract_capitalized}\": onEventWhereChainContract}}\n\
type onEventWhereArgs = {{chain: onEventWhereChain}}\n\
@unboxed type onEventWhereResult = Filter(onEventWhereFilter) | @as(false) SkipAll | @as(true) KeepAll\n\
type onEventWhere = onEventWhereArgs => onEventWhereResult",
                contract_capitalized = self.contract_name.capitalized,
            ),
        };

        // ReScript block/transaction types only include selected fields
        // (deprecated never fields only in TypeScript EvmBlock/EvmTransaction)
        let (block_type, transaction_type) =
            match (&self.custom_field_selection, &self.all_ecosystem_fields) {
                (Some(ref custom_fs), Some(ref all_fields)) => {
                    let selected = FieldSelection::new(FieldSelectionOptions {
                        transaction_fields: custom_fs.transaction_fields.clone(),
                        block_fields: custom_fs.block_fields.clone(),
                    });
                    (
                        ProjectTemplate::generate_rescript_all_fields_record(
                            &selected.block_fields,
                            &all_fields.block_fields,
                            "block_fields",
                            event_name,
                            "    ",
                        ),
                        ProjectTemplate::generate_rescript_all_fields_record(
                            &selected.transaction_fields,
                            &all_fields.transaction_fields,
                            "transaction_fields",
                            event_name,
                            "    ",
                        ),
                    )
                }
                (Some(ref custom_fs), None) => {
                    let selected = FieldSelection::new(FieldSelectionOptions {
                        transaction_fields: custom_fs.transaction_fields.clone(),
                        block_fields: custom_fs.block_fields.clone(),
                    });
                    (selected.block_type, selected.transaction_type)
                }
                _ => ("Block.t".to_string(), "Transaction.t".to_string()),
            };

        let params_constructor_type = &self.params_constructor_type;

        format!(
            r#"
let name = "{event_name}"
let contractName = contractName
type params = {data_type}
/** Event params with all fields optional. Missing fields use default values. */
type paramsConstructor = {params_constructor_type}
type block = {block_type}
type transaction = {transaction_type}

type event = {{
  /** The name of the contract that emitted this event. */
  contractName: string,
  /** The name of the event. */
  eventName: string,
  /** The parameters or arguments associated with this event. */
  params: params,
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

type whereParams = {where_params_type}

{where_type_code}"#
        )
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventTemplate {
    pub name: String,
    pub module_code: String,
}

impl EventTemplate {
    const EVENT_FILTER_TYPE_STUB: &'static str = "{}";

    pub fn generate_event_filter_type(params: &[EventParam]) -> String {
        let field_rows = params
            .iter()
            .filter(|param| param.indexed)
            .map(|param| {
                // ReScript forbids inline records inside generic type arguments
                // (`SingleOrMultiple.t<{...}>`), so we intentionally render
                // struct filters as positional tuples here. Indexed structs are
                // delivered as a keccak256 hash at runtime anyway, so losing the
                // component names has no runtime impact.
                format!(
                    "@as(\"{}\") {}?: SingleOrMultiple.t<{}>",
                    param.name,
                    RecordField::to_valid_rescript_name(&param.name),
                    crate::config_parsing::event_parsing::abi_to_rescript_type_positional(
                        &param.into()
                    )
                )
            })
            .collect::<Vec<_>>()
            .join(", ");

        format!("{{{field_rows}}}")
    }

    pub fn from_fuel_supply_event(
        config_event: &system_config::Event,
        all_ecosystem_fields: Option<FieldSelection>,
        contract_name: &CapitalizedOptions,
    ) -> Self {
        let event_name = config_event.name.capitalize();
        let event_mod = EventMod {
            event_name: event_name.clone(),
            data_type: "Internal.fuelSupplyParams".to_string(),
            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
            custom_field_selection: config_event.field_selection.clone(),
            all_ecosystem_fields: all_ecosystem_fields.clone(),
            params_constructor_type: "Internal.fuelSupplyParams".to_string(),
            contract_name: contract_name.clone(),
        };
        EventTemplate {
            name: event_name,
            module_code: event_mod.to_string(),
        }
    }

    pub fn from_fuel_transfer_event(
        config_event: &system_config::Event,
        all_ecosystem_fields: Option<FieldSelection>,
        contract_name: &CapitalizedOptions,
    ) -> Self {
        let event_name = config_event.name.capitalize();
        let event_mod = EventMod {
            event_name: event_name.clone(),
            data_type: "Internal.fuelTransferParams".to_string(),
            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
            custom_field_selection: config_event.field_selection.clone(),
            all_ecosystem_fields: all_ecosystem_fields.clone(),
            params_constructor_type: "Internal.fuelTransferParams".to_string(),
            contract_name: contract_name.clone(),
        };
        EventTemplate {
            name: event_name,
            module_code: event_mod.to_string(),
        }
    }

    pub fn from_config_event(
        config_event: &system_config::Event,
        all_ecosystem_fields: Option<FieldSelection>,
        contract_name: &CapitalizedOptions,
    ) -> Result<Self> {
        let event_name = config_event.name.capitalize();
        match &config_event.kind {
            EventKind::Params(params) => {
                // Solidity structs render as ReScript JS object types
                // (`{"funder": Address.t, ...}`) via `TypeIdent::Record`, which
                // IS inlinable inside a nominal record. The top-level `type
                // params` stays a nominal record so that handler code can do
                // `event.params.funder` on top-level fields; nested structs
                // fall back to JS-object field access (`event.params.foo["bar"]`).
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

                // Generate params_constructor_type (all fields optional).
                // ReScript forbids inline record types in optional record fields
                // (`field?: {...}`), so we render struct params as positional
                // tuples here. Users constructing simulate inputs via the
                // constructor therefore provide `(a, b, c)` for structs; the
                // full named-record shape is still exposed on `params` / `event.params`.
                let params_constructor_type = if params.is_empty() {
                    "unit".to_string()
                } else {
                    let fields = params
                        .iter()
                        .map(|p| {
                            let field = RecordField::new(
                                p.name.to_string(),
                                crate::config_parsing::event_parsing::abi_to_rescript_type_positional(&p.into()),
                            );
                            let as_prefix = field
                                .as_name
                                .as_ref()
                                .map_or("".to_string(), |s| format!("@as(\"{s}\") "));
                            format!("{}{}?: {}", as_prefix, field.name, field.type_ident)
                        })
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!("{{{}}}", fields)
                };

                let event_mod = EventMod {
                    event_name: event_name.clone(),
                    data_type: data_type_expr.to_string(),

                    event_filter_type: Self::generate_event_filter_type(params),
                    custom_field_selection: config_event.field_selection.clone(),
                    all_ecosystem_fields: all_ecosystem_fields.clone(),
                    params_constructor_type,
                    contract_name: contract_name.clone(),
                };

                Ok(EventTemplate {
                    name: event_name,
                    module_code: event_mod.to_string(),
                })
            }
            EventKind::Fuel(fuel_event_kind) => {
                let fuel_event_kind = fuel_event_kind.clone();
                match &fuel_event_kind {
                    FuelEventKind::LogData(type_indent) => {
                        let data_type_str = type_indent.to_string();
                        let event_mod = EventMod {
                            event_name: event_name.clone(),
                            data_type: data_type_str.clone(),
                            event_filter_type: Self::EVENT_FILTER_TYPE_STUB.to_string(),
                            custom_field_selection: config_event.field_selection.clone(),
                            all_ecosystem_fields: all_ecosystem_fields.clone(),
                            params_constructor_type: data_type_str,
                            contract_name: contract_name.clone(),
                        };

                        Ok(EventTemplate {
                            name: event_name,
                            module_code: event_mod.to_string(),
                        })
                    }
                    FuelEventKind::Mint | FuelEventKind::Burn => Ok(Self::from_fuel_supply_event(
                        config_event,
                        all_ecosystem_fields,
                        contract_name,
                    )),
                    FuelEventKind::Call | FuelEventKind::Transfer => {
                        Ok(Self::from_fuel_transfer_event(
                            config_event,
                            all_ecosystem_fields,
                            contract_name,
                        ))
                    }
                }
            }
            EventKind::Svm(_) => Ok(Self::from_svm_instruction_event(
                config_event,
                contract_name,
            )),
        }
    }

    /// Per-instruction ReScript module for SVM. Minimal surface for C1: enough
    /// shape so the GADT `eventIdentity<event, paramsConstructor, onEventWhere>`
    /// machinery still type-checks. Concrete `indexer.onInstruction(...)`
    /// registration arrives in C2 alongside dispatch.
    fn from_svm_instruction_event(
        config_event: &system_config::Event,
        _contract_name: &CapitalizedOptions,
    ) -> Self {
        let event_name = config_event.name.capitalize();
        let module_code = format!(
            r#"
let name = "{event_name}"
let contractName = contractName
type params = Envio.svmInstruction
type paramsConstructor = unit
type event = Envio.svmInstructionEvent
type onEventWhere = Internal.noOnEventWhere"#
        );
        EventTemplate {
            name: event_name,
            module_code,
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
        all_ecosystem_fields: Option<&FieldSelection>,
    ) -> Result<Self> {
        let name = contract.name.to_capitalized_options();
        let handler = contract.handler_path.clone();
        let codegen_events = contract
            .events
            .iter()
            .map(|event| {
                EventTemplate::from_config_event(event, all_ecosystem_fields.cloned(), &name)
            })
            .collect::<Result<_>>()?;

        let module_code = match &contract.abi {
            // EVM: abi and eventSignatures are already in internal.config.json
            Abi::Evm(_) => String::new(),
            Abi::Fuel(abi) => {
                let all_abi_type_declarations = abi.to_type_decl_multi().context(format!(
                    "Failed getting types from the '{}' contract ABI",
                    contract.name
                ))?;

                // Indexer.res lives at <project_root>/src/Indexer.res, so `../`
                // from the compiled .mjs reaches the project root.
                // Escape back-ticks just in case: the abi path is inside a
                // template literal.
                format!(
                    "let abi = FuelSDK.transpileAbi((await \
                     Utils.importPathWithJson(`../{}`))[\"default\"])\n{}",
                    abi.path_relative_to_root, all_abi_type_declarations,
                )
            }
            // Solana programs ship no ABI artifact today.
            Abi::Svm(_) => String::new(),
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
        network_contract: &system_config::ChainContract,
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
    max_reorg_depth: Option<u32>,
    block_lag: Option<u32>,
    start_block: u64,
    end_block: Option<u64>,
}

impl NetworkTemplate {
    fn from_config_network(network: &system_config::Chain) -> Self {
        NetworkTemplate {
            id: network.id,
            max_reorg_depth: network.max_reorg_depth,
            block_lag: network.block_lag,
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
    fn from_config_network(network: &system_config::Chain, config: &SystemConfig) -> Result<Self> {
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

        Ok(NetworkConfigTemplate {
            network_config,
            codegen_contracts,
        })
    }
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub(crate) struct FieldSelection {
    transaction_fields: Vec<SelectedFieldTemplate>,
    block_fields: Vec<SelectedFieldTemplate>,
    transaction_type: String,
    block_type: String,
    ts_transaction_type: String,
    ts_block_type: String,
}

struct FieldSelectionOptions {
    transaction_fields: Vec<SelectedField>,
    block_fields: Vec<SelectedField>,
}

impl FieldSelection {
    fn default_block_fields() -> Vec<SelectedField> {
        vec![
            SelectedField {
                name: "number".to_string(),
                data_type: TypeIdent::Int,
            },
            SelectedField {
                name: "timestamp".to_string(),
                data_type: TypeIdent::Int,
            },
            SelectedField {
                name: "hash".to_string(),
                data_type: TypeIdent::String,
            },
        ]
    }

    fn new(options: FieldSelectionOptions) -> Self {
        Self::new_with_default_block_fields(options, Self::default_block_fields())
    }

    fn new_without_defaults(options: FieldSelectionOptions) -> Self {
        Self::new_with_default_block_fields(options, vec![])
    }

    fn new_with_default_block_fields(
        options: FieldSelectionOptions,
        default_block_fields: Vec<SelectedField>,
    ) -> Self {
        let mut block_field_templates = vec![];
        let mut all_block_fields = vec![];
        let all_fields: Vec<_> = default_block_fields
            .into_iter()
            .chain(options.block_fields)
            .collect();
        for field in all_fields {
            let res_name = RecordField::to_valid_rescript_name(&field.name);
            let name: CaseOptions = field.name.into();

            block_field_templates.push(SelectedFieldTemplate {
                name: name.clone(),
                res_name,
                ts_type: field.data_type.to_ts_type_string(),
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
                ts_type: field.data_type.to_ts_type_string(),
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
            ts_transaction_type: transaction_expr.to_ts_type_string(),
            ts_block_type: block_expr.to_ts_type_string(),
            transaction_type: transaction_expr.to_string(),
            block_type: block_expr.to_string(),
        }
    }

    fn global_selection(cfg: &system_config::FieldSelection) -> Self {
        Self::new(FieldSelectionOptions {
            transaction_fields: cfg.transaction_fields.clone(),
            block_fields: cfg.block_fields.clone(),
        })
    }
}

#[derive(Serialize, Clone, Debug, PartialEq)]
struct SelectedFieldTemplate {
    name: CaseOptions,
    res_name: String,
    res_type: String,
    ts_type: String,
}

pub struct ProjectTemplate {
    /// Read by chain-config unit tests in this module. Not used by the
    /// production codegen flow, hence the dead-code allowance.
    #[allow(dead_code)]
    chain_configs: Vec<NetworkConfigTemplate>,
    is_rescript: bool,
    indexer_code: String,
    envio_types_dts: String,
}

/// Write `contents` to `path` only when it differs from what's on disk.
/// Saves an mtime bump on every codegen run when nothing has changed —
/// downstream watchers (rescript-legacy, tsc --watch) won't see spurious
/// invalidations.
fn write_if_changed(path: &std::path::Path, contents: &str) -> std::io::Result<()> {
    if let Ok(existing) = std::fs::read_to_string(path) {
        if existing == contents {
            return Ok(());
        }
    }
    std::fs::write(path, contents)
}

impl ProjectTemplate {
    pub fn generate_templates(&self, project_paths: &ParsedProjectPaths) -> Result<()> {
        // 1. `.envio/types.d.ts` — augments `envio` with project-derived
        //    chains/contracts/entities/enums.
        std::fs::create_dir_all(&project_paths.envio_dir)
            .context("Failed to create .envio directory")?;
        write_if_changed(&project_paths.envio_types_dts(), &self.envio_types_dts)
            .context("Failed writing .envio/types.d.ts")?;

        // 2. `.envio/.gitignore` — keeps `types.d.ts` out of git while leaving
        //    sibling artifacts (like cache/) tracked. Written once; never
        //    overwritten so users may add their own entries.
        let gitignore_path = project_paths.envio_dir.join(".gitignore");
        if !gitignore_path.exists() {
            std::fs::write(
                &gitignore_path,
                "# Ephemeral codegen output. Add other .envio entries here as needed.\n\
                 types.d.ts\n",
            )
            .context("Failed writing .envio/.gitignore")?;
        }

        // 3. `envio-env.d.ts` — committed glue file at the project root. Pulls
        //    `.envio/types.d.ts` into the TS program so the augmented `envio`
        //    module surface is visible to user handlers.
        let envio_env = format!(
            "/**\n \
             * This file is generated by HyperIndex codegen. Do not edit manually.\n \
             * It wires project-specific types from `.envio/types.d.ts` into the `envio` module.\n \
             * If your project's types look out of date, run `envio codegen`\n \
             * (or your package manager's `codegen` script, e.g. `pnpm codegen`).\n \
             */\n\
             /// <reference path=\"./{}/{}\" />\n",
            crate::constants::project_paths::ENVIO_DIR,
            ENVIO_TYPES_FILE,
        );
        write_if_changed(&project_paths.envio_env_dts(), &envio_env)
            .with_context(|| format!("Failed writing {ENVIO_ENV_DTS_FILE} to project root"))?;

        // 4. `src/Indexer.res` — bridges ReScript handlers to the runtime.
        if self.is_rescript {
            let src_dir = project_paths.project_root.join("src");
            std::fs::create_dir_all(&src_dir).context("Failed to create user src directory")?;
            write_if_changed(
                &src_dir.join("Indexer.res"),
                &format!("{}\n", self.indexer_code),
            )
            .context("Failed writing Indexer.res to user src directory")?;
        }

        Ok(())
    }

    /// Generate a ReScript record type with all fields. Selected fields get their actual type,
    /// unselected fields get `@deprecated("...") fieldName?: S.never` (optional so records can omit them).
    fn generate_rescript_all_fields_record(
        selected: &[SelectedFieldTemplate],
        all_fields: &[SelectedFieldTemplate],
        field_kind: &str,
        event_name: &str,
        indent: &str,
    ) -> String {
        let selected_names: std::collections::HashSet<&str> =
            selected.iter().map(|f| f.name.camel.as_str()).collect();

        let fields: Vec<String> = all_fields
            .iter()
            .map(|f| {
                if selected_names.contains(f.name.camel.as_str()) {
                    format!("{}{}: {},", indent, f.res_name, f.res_type)
                } else {
                    format!(
                        "{i}@deprecated(\"Not selected for this event. To enable, add to config.yaml:\\nevents:\\n  - event: {event}\\n    field_selection:\\n      {kind}:\\n        - {field}\")\n{i}{res_name}?: unit,",
                        i = indent,
                        event = event_name,
                        kind = field_kind,
                        field = f.name.camel,
                        res_name = f.res_name,
                    )
                }
            })
            .collect();

        format!("{{\n{}\n}}", fields.join("\n"))
    }

    /// Generate a TypeScript record type with all fields for envio.d.ts.
    /// Selected fields get their actual TS type, unselected get `never` with @deprecated.
    fn generate_ts_all_fields_record(
        selected: &[SelectedFieldTemplate],
        all_fields: &[SelectedFieldTemplate],
        field_kind: &str,
        event_name: &str,
        indent: &str,
    ) -> String {
        let selected_names: std::collections::HashSet<&str> =
            selected.iter().map(|f| f.name.camel.as_str()).collect();

        let fields: Vec<String> = all_fields
            .iter()
            .map(|f| {
                let ts_name = &f.name.camel;
                if selected_names.contains(ts_name.as_str()) {
                    format!(
                        "{}/** The {} field. */\n{}readonly {}: {};",
                        indent, ts_name, indent, ts_name,
                        Self::to_envio_dts_type(&f.ts_type)
                    )
                } else {
                    format!(
                        "{i}/**\n{i} * @deprecated Not selected for this event. To enable, add to config.yaml:\n{i} * ```yaml\n{i} * events:\n{i} *   - event: {event}\n{i} *     field_selection:\n{i} *       {kind}:\n{i} *         - {field}\n{i} * ```\n{i} */\n{i}readonly {field}: never;",
                        i = indent,
                        event = event_name,
                        kind = field_kind,
                        field = ts_name,
                    )
                }
            })
            .collect();

        format!(
            "{{\n{}\n{}}}",
            fields.join("\n"),
            &indent[..indent.len().saturating_sub(2)]
        )
    }

    /// Convert a TypeScript type string for use in envio.d.ts.
    /// AccessList/AuthorizationList are internal HyperSync types — use `unknown[]` in .d.ts.
    fn to_envio_dts_type(ts_type: &str) -> String {
        if ts_type.contains("HyperSyncClient") {
            ts_type
                .replace("HyperSyncClient.ResponseTypes.accessList", "unknown")
                .replace("HyperSyncClient.ResponseTypes.authorizationList", "unknown")
        } else {
            ts_type.to_string()
        }
    }

    /// Generate a full TypeScript event type for use in EvmContracts/FuelContracts.
    /// Produces a type with contractName, eventName, params, block, transaction, etc.
    /// Unselected block/transaction fields are typed as `never` with @deprecated guidance.
    fn generate_contract_event_ts_type(
        contract_name: &str,
        event: &system_config::Event,
        aggregated: &FieldSelection,
        chain_id_type_name: &str,
        global_block_type_name: &str,
        global_transaction_type_name: &str,
    ) -> String {
        // Build params TS type
        let params_ts = match &event.kind {
            system_config::EventKind::Params(params) if !params.is_empty() => {
                let fields: Vec<String> = params
                    .iter()
                    .map(|p| {
                        let ts_type = Self::to_envio_dts_type(
                            &abi_to_rescript_type(&p.into()).to_ts_type_string(),
                        );
                        format!("readonly {}: {}", p.name, ts_type)
                    })
                    .collect();
                format!("{{ {} }}", fields.join("; "))
            }
            system_config::EventKind::Fuel(system_config::FuelEventKind::Mint)
            | system_config::EventKind::Fuel(system_config::FuelEventKind::Burn) => {
                "{ readonly subId: string; readonly amount: bigint }".to_string()
            }
            system_config::EventKind::Fuel(system_config::FuelEventKind::Transfer)
            | system_config::EventKind::Fuel(system_config::FuelEventKind::Call) => {
                "{ readonly to: Address; readonly assetId: string; readonly amount: bigint }"
                    .to_string()
            }
            system_config::EventKind::Fuel(system_config::FuelEventKind::LogData(type_ident)) => {
                // Reference FuelTypes namespace for the contract's ABI type.
                // Use `to_ts_type_string_with_namespace` so nested type
                // parameters (e.g. `type4<type26>`) also get the namespace
                // prefix recursively.
                type_ident.to_ts_type_string_with_namespace(&format!("FuelTypes.{}", contract_name))
            }
            _ => "undefined".to_string(),
        };

        // For events without custom field_selection, use global type alias
        // For events with custom field_selection, generate inline type with all fields
        let (block_ts, tx_ts) = if let Some(event_fs) = &event.field_selection {
            let block_ts = Self::generate_ts_all_fields_record(
                &FieldSelection::new(FieldSelectionOptions {
                    block_fields: event_fs.block_fields.clone(),
                    transaction_fields: vec![],
                })
                .block_fields,
                &aggregated.block_fields,
                "block_fields",
                &event.name,
                "        ",
            );
            let tx_ts = Self::generate_ts_all_fields_record(
                &FieldSelection::new(FieldSelectionOptions {
                    block_fields: vec![],
                    transaction_fields: event_fs.transaction_fields.clone(),
                })
                .transaction_fields,
                &aggregated.transaction_fields,
                "transaction_fields",
                &event.name,
                "        ",
            );
            (block_ts, tx_ts)
        } else {
            (
                global_block_type_name.to_string(),
                global_transaction_type_name.to_string(),
            )
        };

        format!(
            r#"    "{}": {{
      /** The name of the event. */
      readonly eventName: "{}";
      /** The name of the contract that emitted this event. */
      readonly contractName: "{}";
      /** The unique identifier of the blockchain network where this event occurred. */
      readonly chainId: {};
      /** The parameters or arguments associated with this event. */
      readonly params: {};
      /** The block in which this event was recorded. Configurable via `field_selection` in config.yaml. */
      readonly block: {};
      /** The transaction that triggered this event. Configurable via `field_selection` in config.yaml. */
      readonly transaction: {};
      /** The index of this event's log within the block. */
      readonly logIndex: number;
      /** The address of the contract that emitted this event. */
      readonly srcAddress: Address;
    }};"#,
            event.name, event.name, contract_name, chain_id_type_name, params_ts, block_ts, tx_ts,
        )
    }

    /// Build the `where` filter TS type for an event — a record of indexed
    /// params wrapped in SingleOrMultiple, nested under a `params` key so
    /// future filter dimensions (block, transaction, …) can be added as
    /// siblings. Only EVM events have indexed filters; Fuel events produce
    /// an empty record. Mirrors `generate_event_filter_type` on the ReScript
    /// side, which intentionally renders indexed-struct filters as positional
    /// tuples — at runtime they're delivered as keccak256 topic hashes anyway.
    fn generate_event_where_ts(event: &system_config::Event) -> String {
        let params_ts = match &event.kind {
            system_config::EventKind::Params(params) => {
                let indexed_fields: Vec<String> = params
                    .iter()
                    .filter(|p| p.indexed)
                    .map(|p| {
                        let ts_type = Self::to_envio_dts_type(
                            &crate::config_parsing::event_parsing::abi_to_rescript_type_positional(
                                &p.into(),
                            )
                            .to_ts_type_string(),
                        );
                        format!("readonly {}?: SingleOrMultiple<{}>", p.name, ts_type)
                    })
                    .collect();
                if indexed_fields.is_empty() {
                    "{}".to_string()
                } else {
                    format!("{{ {} }}", indexed_fields.join("; "))
                }
            }
            _ => "{}".to_string(),
        };
        format!("{{ readonly params: {} }}", params_ts)
    }

    pub fn from_config(cfg: &SystemConfig) -> Result<Self> {
        // Compute all available fields for the ecosystem (EVM has all block/tx fields,
        // Fuel has fixed fields). Used for generating deprecated S.never markers.
        let all_ecosystem_fields = match cfg.get_ecosystem() {
            Ecosystem::Evm => {
                let all_evm = system_config::FieldSelection::all_evm();
                Some(FieldSelection::new(FieldSelectionOptions {
                    block_fields: all_evm.block_fields,
                    transaction_fields: all_evm.transaction_fields,
                }))
            }
            Ecosystem::Fuel => {
                let fuel_fs = system_config::FieldSelection::fuel();
                Some(FieldSelection::new_without_defaults(
                    FieldSelectionOptions {
                        block_fields: fuel_fs.block_fields,
                        transaction_fields: fuel_fs.transaction_fields,
                    },
                ))
            }
            Ecosystem::Svm => None,
        };

        let codegen_contracts: Vec<ContractTemplate> = cfg
            .get_contracts()
            .iter()
            .map(|cfg_contract| {
                ContractTemplate::from_config_contract(cfg_contract, all_ecosystem_fields.as_ref())
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
            .get_chains()
            .iter()
            .map(|network| NetworkConfigTemplate::from_config_network(network, cfg))
            .collect::<Result<_>>()
            .context("Failed generating chain configs template")?;

        let global_field_selection = FieldSelection::global_selection(&cfg.field_selection);

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

        // Generate onBlock handler signature with ecosystem-specific types.
        // Mirror the TypeScript surface in `packages/envio/index.d.ts`
        // (`EvmOnBlockHandlerArgs`, `FuelOnBlockHandlerArgs`,
        // `SvmOnSlotHandlerArgs`).
        let on_block_handler_type = match cfg.get_ecosystem() {
            Ecosystem::Evm => "Envio.evmOnBlockArgs<handlerContext> => promise<unit>",
            Ecosystem::Fuel => "Envio.fuelOnBlockArgs<handlerContext> => promise<unit>",
            Ecosystem::Svm => "Envio.svmOnSlotArgs<handlerContext> => promise<unit>",
        };

        let chain_id_type = format!(
            "type chainId = [{}]",
            chain_id_cases
                .iter()
                .map(|chain_id_case| format!("#{}", chain_id_case))
                .collect::<Vec<_>>()
                .join(" | "),
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
  /** Whether all chains have entered real-time indexing mode (caught up to head, or reached their configured endBlock for finite-range indexers). */
  isRealtime: bool,{contract_fields}
}}"#
        );

        // Generate indexerChains type with fields for each chain
        let indexer_chains_fields = chain_configs
            .iter()
            .map(|chain| {
                let id = chain.network_config.id;
                let id_field = format!("  \\\"{}\": indexerChain,", id);
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

        // Ecosystem-specific indexer surface. EVM/Fuel expose event + block
        // handlers; SVM has no event handlers and uses `onSlot` instead of
        // `onBlock`. Mirrors the TS typings in `packages/envio/index.d.ts`
        // and the ecosystem-specific key set in `Main.getGlobalIndexer`.
        let indexer_type = match cfg.get_ecosystem() {
            Ecosystem::Evm | Ecosystem::Fuel => format!(
                r#"/** Metadata and configuration for the indexer. */
type indexer = {{
  /** The name of the indexer from config.yaml. */
  name: string,
  /** The description of the indexer from config.yaml. */
  description: option<string>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
  /** Register an event handler. */
  onEvent: 'event 'paramsConstructor 'where. (
    onEventOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericHandler<Internal.genericHandlerArgs<'event, handlerContext>>,
  ) => unit,
  /** Register a contract register handler for dynamic contract indexing. */
  contractRegister: 'event 'paramsConstructor 'where. (
    onEventOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, contractRegisterContext>>,
  ) => unit,
  /** Register a Block Handler. Evaluates `where` once per configured chain at registration time. */
  onBlock: (
    Envio.onBlockOptions<indexerChain>,
    {on_block_handler_type},
  ) => unit,
}}"#
            ),
            Ecosystem::Svm => format!(
                r#"/** Metadata and configuration for the indexer. */
type indexer = {{
  /** The name of the indexer from config.yaml. */
  name: string,
  /** The description of the indexer from config.yaml. */
  description: option<string>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
  /** Register an instruction handler. */
  onInstruction: 'event 'paramsConstructor 'where. (
    onInstructionOptions<eventIdentity<'event, 'paramsConstructor, 'where>, 'where>,
    Internal.genericHandler<Internal.genericHandlerArgs<'event, handlerContext>>,
  ) => unit,
  /** Register a Slot Handler. Evaluates `where` once per configured chain at registration time. */
  onSlot: (
    Envio.onBlockOptions<indexerChain>,
    {on_block_handler_type},
  ) => unit,
}}"#
            ),
        };

        // Generate getChainById function
        let get_chain_by_id_cases = chain_configs
            .iter()
            .map(|chain| {
                format!(
                    "  | #{} => indexer.chains.\\\"{}\"",
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

        // Generate Enums and Entities modules
        let enums_module_code = indent(&generate_enums_code(&gql_enums));
        let entities_module_code = indent(&generate_entities_code(&entities));

        // Generate handlerContext types
        let handler_context_entity_fields = entities
            .iter()
            .map(|entity| {
                format!(
                    "  \\\"{}\": handlerEntityOperations<Entities.{}.t, Entities.{}.getWhereFilter>,",
                    entity.name.original,
                    entity.name.capitalized,
                    entity.name.capitalized,
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        let handler_context_code = format!(
            r#"type handlerEntityOperations<'entity, 'getWhereFilter> = {{
  get: string => promise<option<'entity>>,
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  getWhere: 'getWhereFilter => promise<array<'entity>>,
  getOrCreate: 'entity => promise<'entity>,
  set: 'entity => unit,
  deleteUnsafe: string => unit,
}}

type handlerContext = {{
  log: Envio.logger,
  effect: 'input 'output. (Envio.effect<'input, 'output>, 'input) => promise<'output>,
  isPreload: bool,
  chain: Internal.chainInfo,
{}
}}"#,
            handler_context_entity_fields
        );

        // Generate contract modules with event sub-modules
        let contract_modules_code = codegen_contracts
            .iter()
            .map(|contract| {
                let events_code = contract
                    .codegen_events
                    .iter()
                    .map(|event| {
                        let indented = event
                            .module_code
                            .lines()
                            .map(|l| {
                                if l.is_empty() {
                                    l.to_string()
                                } else {
                                    format!("    {l}")
                                }
                            })
                            .collect::<Vec<_>>()
                            .join("\n");
                        format!("  module {} = {{\n{}\n  }}", event.name, indented)
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n");

                // Generate per-contract eventIdentity GADT inside the contract module
                let event_identity = if contract.codegen_events.is_empty() {
                    String::new()
                } else {
                    let gadt_constructors = contract
                        .codegen_events
                        .iter()
                        .map(|event| {
                            format!(
                                "    | @as(\"{event_name}\") {event_name}: eventIdentity<\
                                 {event_name}.event, {event_name}.paramsConstructor, \
                                 {event_name}.onEventWhere>",
                                event_name = event.name,
                            )
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    format!(
                        "\n\n  type rec eventIdentity<'event, 'paramsConstructor, 'where> =\n{}",
                        gadt_constructors,
                    )
                };

                let module_header = if contract.module_code.is_empty() {
                    format!("let contractName = \"{}\"", contract.name.capitalized)
                } else {
                    format!(
                        "{}\nlet contractName = \"{}\"",
                        contract.module_code, contract.name.capitalized
                    )
                };
                format!(
                    "module {} = {{\n{}\n\n{}{}\n}}",
                    contract.name.capitalized, module_header, events_code, event_identity,
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");

        // Generate GADT event identifier types for type-safe simulate items.
        // For configs without any contract events (e.g. SVM-only or empty-contract
        // configs) we still emit an abstract `eventIdentity` type so the unconditional
        // `type indexer` definition below — which references it in onEvent /
        // contractRegister fields — type-checks. Such configs simply have no
        // constructors to pass in.
        let contracts_with_events: Vec<_> = codegen_contracts
            .iter()
            .filter(|c| !c.codegen_events.is_empty())
            .collect();

        let simulate_types_code = if contracts_with_events.is_empty() {
            "type eventIdentity<'event, 'paramsConstructor, 'where>".to_string()
        } else {
            let top_constructors = contracts_with_events
                .iter()
                .map(|c| {
                    let name = &c.name.capitalized;
                    format!("  | {name}({name}.eventIdentity<'event, 'paramsConstructor, 'where>)")
                })
                .collect::<Vec<_>>()
                .join("\n");

            let (
                params_optional,
                simulate_item_type,
                block_constructor_type,
                transaction_constructor_type,
            ) = match cfg.get_ecosystem() {
                Ecosystem::Fuel => (
                    "",
                    "Envio.fuelSimulateItem",
                    "Envio.fuelBlockInput",
                    "Envio.fuelTransactionInput",
                ),
                _ => (
                    "?",
                    "Envio.evmSimulateItem",
                    "Internal.evmBlockInput",
                    "Internal.evmTransactionInput",
                ),
            };

            format!(
                "@tag(\"contract\")\n\
                 type eventIdentity<'event, 'paramsConstructor, 'where> =\n\
                 {top_constructors}\n\n\
                 @tag(\"kind\")\n\
                 type simulateItemConstructor<'event, 'paramsConstructor, 'where> =\n\
                 \x20 | OnEvent({{\n\
                 \x20     event: eventIdentity<'event, 'paramsConstructor, 'where>,\n\
                 \x20     params{params_optional}: 'paramsConstructor,\n\
                 \x20     block?: {block_constructor_type},\n\
                 \x20     transaction?: {transaction_constructor_type},\n\
                 \x20   }})\n\n\
                 let makeSimulateItem = (\n\
                 \x20 constructor: simulateItemConstructor<'event, 'paramsConstructor, 'where>,\n\
                 ): {simulate_item_type} => {{\n\
                 \x20 event: (constructor->Utils.magic)[\"event\"][\"_0\"],\n\
                 \x20 contract: (constructor->Utils.magic)[\"event\"][\"contract\"],\n\
                 \x20 params: (constructor->Utils.magic)[\"params\"],\n\
                 \x20 block: (constructor->Utils.magic)[\"block\"],\n\
                 \x20 transaction: (constructor->Utils.magic)[\"transaction\"],\n\
                 }}"
            )
        };

        // Generate contractRegisterContext type with chain.ContractName.add() pattern
        let contract_register_chain_fields: String = codegen_contracts
            .iter()
            .map(|c| format!("  \\\"{}\": contractRegisterContract,", c.name.capitalized))
            .collect::<Vec<_>>()
            .join("\n");

        // Block and Transaction module types with deprecated fields for unselected
        let block_module_type = if let Some(ref all_fs) = all_ecosystem_fields {
            Self::generate_rescript_all_fields_record(
                &global_field_selection.block_fields,
                &all_fs.block_fields,
                "block_fields",
                "global",
                "    ",
            )
        } else {
            global_field_selection.block_type.clone()
        };

        let transaction_module_type = if let Some(ref all_fs) = all_ecosystem_fields {
            Self::generate_rescript_all_fields_record(
                &global_field_selection.transaction_fields,
                &all_fs.transaction_fields,
                "transaction_fields",
                "global",
                "    ",
            )
        } else {
            global_field_selection.transaction_type.clone()
        };

        // Combine all parts into indexer_code — includes everything from the template
        let indexer_code = format!(
            r#"/**
 * This file is generated by HyperIndex codegen from config.yaml and schema.graphql.
 * Do not edit manually.
 * If your project's types look out of date, run `envio codegen`
 * (or your package manager's `codegen` script, e.g. `pnpm codegen`).
 */

module Transaction = {{
  type t = {transaction_module_type}
}}

module Block = {{
  type t = {block_module_type}
}}

module SingleOrMultiple: {{
  type t<'a>
  let normalizeOrThrow: (t<'a>, ~nestedArrayDepth: int=?) => array<'a>
  let single: 'a => t<'a>
  let multiple: array<'a> => t<'a>
}} = {{
  type t<'a> = JSON.t

  external single: 'a => t<'a> = "%identity"
  external multiple: array<'a> => t<'a> = "%identity"
  external castMultiple: t<'a> => array<'a> = "%identity"
  external castSingle: t<'a> => 'a = "%identity"

  exception AmbiguousEmptyNestedArray

  let rec isMultiple = (t: t<'a>, ~nestedArrayDepth): bool =>
    if !Array.isArray(t) {{
      false
    }} else {{
      let arr = t->(Utils.magic: t<'a> => array<t<'a>>)
      if nestedArrayDepth == 0 {{
        true
      }} else if arr->Array.length == 0 {{
        AmbiguousEmptyNestedArray->ErrorHandling.mkLogAndRaise(
          ~msg="The given empty array could be interpreted as a flat array (value) or nested array. Since it's ambiguous,
          please pass in a nested empty array if the intention is to provide an empty array as a value",
        )
      }} else {{
        arr->Utils.Array.firstUnsafe->isMultiple(~nestedArrayDepth=nestedArrayDepth - 1)
      }}
    }}

  let normalizeOrThrow = (t: t<'a>, ~nestedArrayDepth=0): array<'a> => {{
    if t->isMultiple(~nestedArrayDepth) {{
      t->castMultiple
    }} else {{
      [t->castSingle]
    }}
  }}
}}

/** Options for onEvent / contractRegister. */
type onEventOptions<'eventIdentity, 'where> = {{
  event: 'eventIdentity,
  wildcard?: bool,
  where?: 'where,
}}

/** Options for `indexer.onInstruction` (SVM). */
type onInstructionOptions<'eventIdentity, 'where> = {{
  instruction: 'eventIdentity,
  where?: 'where,
}}

module Enums = {{
{enums_module_code}
}}

module Entities = {{
{entities_module_code}
}}

{handler_context_code}

{chain_id_type}

type contractRegisterContract = {{ add: Address.t => unit }}

type contractRegisterChain = {{
  id: chainId,
{contract_register_chain_fields}
}}

type contractRegisterContext = {{
  log: Envio.logger,
  chain: contractRegisterChain,
}}

{contract_modules_code}

{indexer_contract_type}

{indexer_chain_type}

{indexer_chains_type}

{simulate_types_code}

{indexer_type}

{get_chain_by_id}"#
        );

        // Generate testIndexer types and createTestIndexer
        let chain_config_type = match cfg.get_ecosystem() {
            Ecosystem::Evm => "TestIndexer.evmChainConfig",
            Ecosystem::Fuel => "TestIndexer.fuelChainConfig",
            Ecosystem::Svm => "TestIndexer.chainConfig",
        };
        let test_indexer_chains_fields = chain_configs
            .iter()
            .map(|chain| {
                let id = chain.network_config.id;
                format!("  \\\"{}\"?: {},", id, chain_config_type)
            })
            .collect::<Vec<_>>()
            .join("\n");

        // Generate entity ops fields for the testIndexer type
        let test_indexer_entity_ops_type = r#"/** Entity operations for direct access outside handlers. */
type testIndexerEntityOperations<'entity> = {
  /** Get an entity by ID. */
  get: string => promise<option<'entity>>,
  /** Get all entities. */
  getAll: unit => promise<array<'entity>>,
  /** Get an entity by ID or throw if not found. */
  getOrThrow: (string, ~message: string=?) => promise<'entity>,
  /** Set (create or update) an entity. */
  set: 'entity => unit,
}"#;

        let test_indexer_entity_fields = entities
            .iter()
            .map(|entity| {
                format!(
                    "  \\\"{}\": testIndexerEntityOperations<Entities.{}.t>,",
                    entity.name.original, entity.name.capitalized,
                )
            })
            .collect::<Vec<_>>()
            .join("\n");

        let test_indexer_types = format!(
            r#"type testIndexerProcessConfigChains = {{
{}
}}

type testIndexerProcessConfig = {{
  chains: testIndexerProcessConfigChains,
}}

{test_indexer_entity_ops_type}

/** Test indexer type with process method, entity access, and chain info. */
type testIndexer = {{
  /** Process blocks for the specified chains and return progress with changes. */
  process: testIndexerProcessConfig => promise<TestIndexer.processResult>,
  /** Array of all chain IDs this indexer operates on. */
  chainIds: array<chainId>,
  /** Per-chain configuration keyed by chain ID. */
  chains: indexerChains,
{}
}}"#,
            test_indexer_chains_fields, test_indexer_entity_fields,
        );

        let mut indexer_code = format!("{}\n\n{}", indexer_code, test_indexer_types);

        // Generate getTestIndexerEntityOperations external binding
        // The GADT name value compiles to a string at runtime via @as decorators,
        // so @get_index can use Entities.name directly as a dictionary key
        if !entities.is_empty() {
            let get_entity_operations = r#"@get_index external getTestIndexerEntityOperations: (testIndexer, Entities.name<'entity>) => testIndexerEntityOperations<'entity> = """#;

            indexer_code = format!("{}\n\n{}", indexer_code, get_entity_operations);
        }

        let generated_top_level_bindings =
            r#"@module("envio") external indexer: indexer = "indexer"

@module("envio") external createTestIndexer: unit => testIndexer = "createTestIndexer""#
                .to_string();

        indexer_code = format!("{}\n\n{}", indexer_code, generated_top_level_bindings);

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

        // Generate envio.d.ts content. Two outputs:
        //   - `lookup_tables`: file-level named types (`EvmBlock`, `Entities`,
        //     etc.) that are shared across events / referenced by entity
        //     fields. None of these names collide with `envio`'s exports or
        //     internal generics, so no prefix is needed.
        //   - body strings (`evm_chains_body`, `evm_contracts_body`, …):
        //     inlined directly into `Global.config` by
        //     `wrap_envio_module_augmentation`. Names that *would* collide
        //     with envio's internal generics (`EvmContracts<Config>` etc.)
        //     are avoided by inlining instead of naming.
        let envio_dts_code;
        let evm_chains_body: String;
        let evm_contracts_body: String;
        let evm_event_filters_body: String;
        let fuel_chains_body: String;
        let fuel_contracts_body: String;
        let fuel_event_filters_body: String;
        let svm_chains_body: String;
        let entities_body: String;
        let enums_body: String;
        {
            let mut parts = Vec::new();

            // EVM chain table (inlined into Global.config.evm.chains).
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
            evm_chains_body = if evm_chains_entries.is_empty() {
                "{}".to_string()
            } else {
                format!("{{\n{}\n      }}", evm_chains_entries.join("\n"))
            };
            // Inline chainId union for event payloads. Empty ecosystem →
            // error string so users see a useful message in tsc errors.
            let evm_chain_id_inline: String = if evm_chains_entries.is_empty() {
                "\"EvmChainId is not available. Configure EVM chains in config.yaml and run 'envio codegen'\"".to_string()
            } else {
                chain_configs
                    .iter()
                    .map(|c| c.network_config.id.to_string())
                    .collect::<Vec<_>>()
                    .join(" | ")
            };

            // File-level shared block / transaction types (EVM).
            if cfg.get_ecosystem() == Ecosystem::Evm {
                if let Some(ref all_fs) = all_ecosystem_fields {
                    let evm_block_type = Self::generate_ts_all_fields_record(
                        &global_field_selection.block_fields,
                        &all_fs.block_fields,
                        "block_fields",
                        "global",
                        "  ",
                    );
                    parts.push(format!("type EvmBlock = {};", evm_block_type));
                    let evm_tx_type = Self::generate_ts_all_fields_record(
                        &global_field_selection.transaction_fields,
                        &all_fs.transaction_fields,
                        "transaction_fields",
                        "global",
                        "  ",
                    );
                    parts.push(format!("type EvmTransaction = {};", evm_tx_type));
                }
            }

            // EVM contracts table (inlined). Uses inline chainId union and
            // file-level `EvmBlock` / `EvmTransaction`.
            let evm_contracts_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Evm {
                let all_evm = system_config::FieldSelection::all_evm();
                let all_fields = FieldSelection::new(FieldSelectionOptions {
                    block_fields: all_evm.block_fields,
                    transaction_fields: all_evm.transaction_fields,
                });
                cfg.contracts
                    .iter()
                    .map(|(name, contract)| {
                        let event_entries: Vec<String> = contract
                            .events
                            .iter()
                            .map(|event| {
                                Self::generate_contract_event_ts_type(
                                    name,
                                    event,
                                    &all_fields,
                                    &evm_chain_id_inline,
                                    "EvmBlock",
                                    "EvmTransaction",
                                )
                            })
                            .collect();
                        format!("  \"{}\": {{\n{}\n  }};", name, event_entries.join("\n"))
                    })
                    .collect()
            } else {
                vec![]
            };
            evm_contracts_body = if evm_contracts_entries.is_empty() {
                "{}".to_string()
            } else {
                format!("{{\n{}\n      }}", evm_contracts_entries.join("\n"))
            };

            // EVM event filters table (inlined).
            let evm_event_filters_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Evm {
                cfg.contracts
                    .iter()
                    .map(|(name, contract)| {
                        let event_entries: Vec<String> = contract
                            .events
                            .iter()
                            .map(|event| {
                                format!(
                                    "    \"{}\": {};",
                                    event.name,
                                    Self::generate_event_where_ts(event)
                                )
                            })
                            .collect();
                        format!("  \"{}\": {{\n{}\n  }};", name, event_entries.join("\n"))
                    })
                    .collect()
            } else {
                vec![]
            };
            evm_event_filters_body = if evm_event_filters_entries.is_empty() {
                "{}".to_string()
            } else {
                format!("{{\n{}\n      }}", evm_event_filters_entries.join("\n"))
            };

            // Fuel chain table (inlined).
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
            fuel_chains_body = if fuel_chains_entries.is_empty() {
                "{}".to_string()
            } else {
                format!("{{\n{}\n      }}", fuel_chains_entries.join("\n"))
            };
            let fuel_chain_id_inline: String = if fuel_chains_entries.is_empty() {
                "\"FuelChainId is not available. Configure Fuel chains in config.yaml and run 'envio codegen'\"".to_string()
            } else {
                chain_configs
                    .iter()
                    .map(|c| c.network_config.id.to_string())
                    .collect::<Vec<_>>()
                    .join(" | ")
            };

            // File-level Fuel block / transaction types.
            if cfg.get_ecosystem() == Ecosystem::Fuel {
                let fuel_fs_for_types = system_config::FieldSelection::fuel();
                let fuel_all = FieldSelection::new_without_defaults(FieldSelectionOptions {
                    block_fields: fuel_fs_for_types.block_fields.clone(),
                    transaction_fields: fuel_fs_for_types.transaction_fields.clone(),
                });
                parts.push(format!("type FuelBlock = {};", fuel_all.ts_block_type));
                parts.push(format!(
                    "type FuelTransaction = {};",
                    fuel_all.ts_transaction_type
                ));
            }

            // Fuel contracts table (inlined). Fuel events have no indexed-param
            // filters, so the eventFilters body is always `{}`.
            let fuel_contracts_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Fuel {
                let fuel_fs = system_config::FieldSelection::fuel();
                let aggregated = FieldSelection::new_without_defaults(FieldSelectionOptions {
                    block_fields: fuel_fs.block_fields,
                    transaction_fields: fuel_fs.transaction_fields,
                });
                cfg.contracts
                    .iter()
                    .map(|(name, contract)| {
                        let event_entries: Vec<String> = contract
                            .events
                            .iter()
                            .map(|event| {
                                Self::generate_contract_event_ts_type(
                                    name,
                                    event,
                                    &aggregated,
                                    &fuel_chain_id_inline,
                                    "FuelBlock",
                                    "FuelTransaction",
                                )
                            })
                            .collect();
                        format!("  \"{}\": {{\n{}\n  }};", name, event_entries.join("\n"))
                    })
                    .collect()
            } else {
                vec![]
            };
            fuel_contracts_body = if fuel_contracts_entries.is_empty() {
                "{}".to_string()
            } else {
                format!("{{\n{}\n      }}", fuel_contracts_entries.join("\n"))
            };
            fuel_event_filters_body = "{}".to_string();

            // FuelTypes namespace at file scope (referenced by Fuel event
            // payloads). No prefix — doesn't collide with envio.
            let fuel_types_entries: Vec<String> = if cfg.get_ecosystem() == Ecosystem::Fuel {
                cfg.contracts
                    .iter()
                    .filter_map(|(name, contract)| {
                        if let system_config::Abi::Fuel(fuel_abi) = &contract.abi {
                            let ns = format!("FuelTypes.{}", name);
                            let type_entries: Vec<String> = fuel_abi
                                .to_type_decl_multi()
                                .ok()?
                                .type_declarations()
                                .iter()
                                .map(|decl| format!("    {}", decl.to_ts_type_decl(&ns)))
                                .collect();
                            if type_entries.is_empty() {
                                None
                            } else {
                                Some(format!(
                                    "  namespace {} {{\n{}\n  }}",
                                    name,
                                    type_entries.join("\n")
                                ))
                            }
                        } else {
                            None
                        }
                    })
                    .collect()
            } else {
                vec![]
            };
            parts.push(if fuel_types_entries.is_empty() {
                "declare namespace FuelTypes {}".to_string()
            } else {
                format!(
                    "declare namespace FuelTypes {{\n{}\n}}",
                    fuel_types_entries.join("\n")
                )
            });

            // SVM chain table (inlined).
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
            svm_chains_body = if svm_chains_entries.is_empty() {
                "{}".to_string()
            } else {
                format!("{{\n{}\n      }}", svm_chains_entries.join("\n"))
            };

            // File-level Enums and Entities tables. They reference each
            // other (entity field types use `Enums["Foo"]`), so they must
            // be named — but no prefix needed since neither name collides
            // with anything still exported by envio.
            let enum_entries: Vec<String> = gql_enums
                .iter()
                .map(|gql_enum| {
                    let enum_values: Vec<String> = gql_enum
                        .params
                        .iter()
                        .map(|value| format!("\"{}\"", value.original))
                        .collect();
                    format!(
                        "  \"{}\": {};",
                        gql_enum.name.original,
                        enum_values.join(" | ")
                    )
                })
                .collect();
            parts.push(if enum_entries.is_empty() {
                "type Enums = {};".to_string()
            } else {
                format!("type Enums = {{\n{}\n}};", enum_entries.join("\n"))
            });
            enums_body = "Enums".to_string();

            let entity_entries: Vec<String> = entities
                .iter()
                .map(|entity| {
                    let field_entries: Vec<String> = entity
                        .params
                        .iter()
                        .filter(|param| !param.is_derived_field)
                        .map(|param| {
                            let ts_type = param.field_type.to_ts_type_string();
                            let (field_name, field_type) = if param.is_entity_field {
                                let base_type = if param.field_type.is_option() {
                                    "string | undefined".to_string()
                                } else {
                                    "string".to_string()
                                };
                                (format!("{}_id", param.field_name.original), base_type)
                            } else {
                                (param.field_name.original.clone(), ts_type)
                            };
                            format!("    readonly \"{}\": {};", field_name, field_type)
                        })
                        .collect();
                    format!(
                        "  \"{}\": {{\n{}\n  }};",
                        entity.name.capitalized,
                        field_entries.join("\n")
                    )
                })
                .collect();
            parts.push(if entity_entries.is_empty() {
                "type Entities = {};".to_string()
            } else {
                format!("type Entities = {{\n{}\n}};", entity_entries.join("\n"))
            });
            entities_body = "Entities".to_string();

            envio_dts_code = parts.join("\n");
        }

        // Per-entity aliases shadow the lookup table for ergonomic imports
        // (`import type { User } from "envio"`). Enums skip aliasing —
        // their schema names often clash with TS reserved words or
        // existing envio exports, so users go through `Enum<"Name">`.
        let entity_aliases: Vec<String> = entities
            .iter()
            .map(|e| e.name.capitalized.clone())
            .collect();

        Ok(ProjectTemplate {
            chain_configs,
            is_rescript: cfg.is_rescript,
            indexer_code,
            envio_types_dts: Self::wrap_envio_module_augmentation(
                &envio_dts_code,
                &entity_aliases,
                cfg.get_ecosystem(),
                ConfigBodies {
                    evm_chains: &evm_chains_body,
                    evm_contracts: &evm_contracts_body,
                    evm_event_filters: &evm_event_filters_body,
                    fuel_chains: &fuel_chains_body,
                    fuel_contracts: &fuel_contracts_body,
                    fuel_event_filters: &fuel_event_filters_body,
                    svm_chains: &svm_chains_body,
                    entities: &entities_body,
                    enums: &enums_body,
                },
            ),
        })
    }

    /// Wrap the project-derived types in a `declare module "envio"` block so
    /// the generic types in `packages/envio/index.d.ts` resolve through the
    /// augmented `Global` interface.
    ///
    /// File-level types (`EvmBlock`, `EvmTransaction`, `FuelBlock`,
    /// `FuelTransaction`, `FuelTypes`, `Entities`, `Enums`) are emitted at
    /// the host file's top level. Their names don't collide with anything
    /// envio exports or uses internally as a generic. The per-ecosystem
    /// `chains` / `contracts` / `eventFilters` shapes are inlined directly
    /// into `Global.config` rather than named at file scope — naming them
    /// (e.g. `EvmContracts`) would shadow envio's internal generic
    /// `EvmContracts<Config>` and collapse `indexer.onEvent`'s callback to
    /// `any`.
    ///
    /// Per-entity aliases are emitted so handlers can `import type { Foo }
    /// from "envio"`. Enums skip aliasing — schema enum names commonly
    /// collide with TS reserved words or envio exports — users go through
    /// `Enum<"Name">` instead.
    fn wrap_envio_module_augmentation(
        file_level_types: &str,
        entity_aliases: &[String],
        ecosystem: Ecosystem,
        bodies: ConfigBodies<'_>,
    ) -> String {
        const I2: &str = "  ";
        const I4: &str = "    ";
        const I6: &str = "      ";

        // Only the configured ecosystem populates `Global.config.<eco>`. Generic
        // helpers in envio fall back to error-message strings for unconfigured
        // ecosystems.
        let ecosystem_field = match ecosystem {
            Ecosystem::Evm => format!(
                "evm: {{ chains: {chains}; contracts: {contracts}; eventFilters: {filters} }};",
                chains = bodies.evm_chains,
                contracts = bodies.evm_contracts,
                filters = bodies.evm_event_filters,
            ),
            Ecosystem::Fuel => format!(
                "fuel: {{ chains: {chains}; contracts: {contracts}; eventFilters: {filters} }};",
                chains = bodies.fuel_chains,
                contracts = bodies.fuel_contracts,
                filters = bodies.fuel_event_filters,
            ),
            Ecosystem::Svm => format!("svm: {{ chains: {} }};", bodies.svm_chains),
        };
        let config_block = [
            ecosystem_field.as_str(),
            &format!("entities: {};", bodies.entities),
            &format!("enums: {};", bodies.enums),
        ]
        .iter()
        .map(|line| format!("{I6}{line}"))
        .collect::<Vec<_>>()
        .join("\n");

        let entity_aliases = entity_aliases
            .iter()
            .map(|name| format!("{I2}export type {name} = Entities[\"{name}\"];"))
            .collect::<Vec<_>>()
            .join("\n");

        format!(
            "/**\n \
             * This file is generated by HyperIndex codegen from config.yaml and schema.graphql.\n \
             * Do not edit manually.\n \
             * If your project's types look out of date, run `envio codegen`\n \
             * (or your package manager's `codegen` script, e.g. `pnpm codegen`).\n \
             */\n\
             \n\
             import type {{ Address, BigDecimal, SingleOrMultiple }} from \"envio\";\n\
             \n\
             {file_level_types}\n\
             \n\
             declare module \"envio\" {{\n\
             {I2}interface Global {{\n\
             {I4}config: {{\n\
             {config_block}\n\
             {I4}}};\n\
             {I2}}}\n\
             \n\
             {entity_aliases}\n\
             }}\n",
            file_level_types = file_level_types,
            entity_aliases = entity_aliases,
        )
    }
}

struct ConfigBodies<'a> {
    evm_chains: &'a str,
    evm_contracts: &'a str,
    evm_event_filters: &'a str,
    fuel_chains: &'a str,
    fuel_contracts: &'a str,
    fuel_event_filters: &'a str,
    svm_chains: &'a str,
    entities: &'a str,
    enums: &'a str,
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
        let project_paths = ParsedProjectPaths::new(&project_root, &config).expect("Parsed paths");

        let config = SystemConfig::parse_from_project_files(&project_paths)
            .expect("Deserialized yml config should be parseable");

        super::ProjectTemplate::from_config(&config)
            .expect("should be able to get project template")
    }

    fn get_internal_config_json_helper(configs_file_name: &str) -> String {
        let project_root = get_test_path_string_helper();
        let config = format!("configs/{}", configs_file_name);
        let project_paths = ParsedProjectPaths::new(&project_root, &config).expect("Parsed paths");

        let config = SystemConfig::parse_from_project_files(&project_paths)
            .expect("Deserialized yml config should be parseable");

        config
            .to_public_config_json(false)
            .expect("should be able to serialize public config JSON")
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
        };

        let expected_chain_configs = vec![chain_config_1];

        let project_template = get_project_template_helper("fuel-config.yaml");

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
        };

        let expected_chain_configs = vec![chain_config_1];

        let project_template = get_project_template_helper("config1.yaml");

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
        };
        let chain_config_2 = super::NetworkConfigTemplate {
            network_config: network2,
            codegen_contracts: vec![contract1_on_chain2, contract2_on_chain2],
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

    #[test]
    fn event_template_with_empty_params() {
        let event_template = EventTemplate::from_config_event(
            &system_config::Event {
                name: "NewGravatar".to_string(),
                kind: system_config::EventKind::Params(vec![]),
                sighash: "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
                    .to_string(),
                event_signature: String::new(),
                field_selection: None,
            },
            None,
            &"Gravatar".to_string().to_capitalized_options(),
        )
        .unwrap();

        assert_eq!(event_template.name, "NewGravatar");
        insta::assert_snapshot!(event_template.module_code);
    }

    /// Builds the Sablier-style event from issue #538 used by the named-struct
    /// snapshot tests below:
    ///
    ///   event CreateLockupTranchedStream(
    ///     uint256 indexed streamId,
    ///     Lockup.CreateEventCommon commonParams,
    ///     LockupTranched.Tranche[] tranches
    ///   );
    ///
    /// `commonParams` is a named struct containing a nested `timestamps`
    /// struct, and `tranches` is an array of `Tranche` structs — this
    /// exercises every interesting code path for struct rendering.
    ///
    /// The synthetic `mixedTuple` param covers tuples that mix named and
    /// unnamed components: unnamed fields fall back to their positional
    /// index as the JS object key.
    fn sablier_named_struct_event() -> system_config::Event {
        use crate::config_parsing::abi_compat::{AbiTupleField, AbiType, EventParam};

        fn named(name: &str, kind: AbiType) -> AbiTupleField {
            AbiTupleField {
                name: Some(name.to_string()),
                kind,
            }
        }
        fn unnamed(kind: AbiType) -> AbiTupleField {
            AbiTupleField { name: None, kind }
        }

        let common_params = AbiType::Tuple(vec![
            named("funder", AbiType::Address),
            named("sender", AbiType::Address),
            named("recipient", AbiType::Address),
            named(
                "amounts",
                AbiType::Tuple(vec![
                    named("deposit", AbiType::Uint(128)),
                    named("brokerFee", AbiType::Uint(128)),
                ]),
            ),
            named("token", AbiType::Address),
            named("cancelable", AbiType::Bool),
            named("transferable", AbiType::Bool),
            named(
                "timestamps",
                AbiType::Tuple(vec![
                    named("start", AbiType::Uint(40)),
                    named("end", AbiType::Uint(40)),
                ]),
            ),
            named("shape", AbiType::String),
            named("broker", AbiType::Address),
        ]);

        let tranche = AbiType::Tuple(vec![
            named("amount", AbiType::Uint(128)),
            named("timestamp", AbiType::Uint(40)),
        ]);

        let mixed_tuple = AbiType::Tuple(vec![
            named("label", AbiType::String),
            unnamed(AbiType::Uint(256)),
            named("recipient", AbiType::Address),
            unnamed(AbiType::Bool),
        ]);

        system_config::Event {
            name: "CreateLockupTranchedStream".to_string(),
            kind: system_config::EventKind::Params(vec![
                EventParam {
                    name: "streamId".to_string(),
                    kind: AbiType::Uint(256),
                    indexed: true,
                },
                EventParam {
                    name: "commonParams".to_string(),
                    kind: common_params,
                    indexed: false,
                },
                EventParam {
                    name: "tranches".to_string(),
                    kind: AbiType::Array(Box::new(tranche)),
                    indexed: false,
                },
                EventParam {
                    name: "mixedTuple".to_string(),
                    kind: mixed_tuple,
                    indexed: false,
                },
            ]),
            sighash: "0x0000000000000000000000000000000000000000000000000000000000000000"
                .to_string(),
            event_signature: String::new(),
            field_selection: None,
        }
    }

    #[test]
    fn event_template_named_struct_rescript_snapshot() {
        // Snapshots the ReScript module emitted for the Sablier-style event,
        // exercising lifted `params_*` type aliases for nested + array structs.
        let event = sablier_named_struct_event();
        let contract_name = "SablierLockup".to_string().to_capitalized_options();
        let template = EventTemplate::from_config_event(&event, None, &contract_name).unwrap();
        insta::assert_snapshot!(template.module_code);
    }

    #[test]
    fn event_template_named_struct_typescript_snapshot() {
        // Snapshots the TypeScript event type emitted into envio.d.ts. Unlike
        // ReScript, TypeScript inlines record types directly so each named
        // struct shows up as `{ readonly funder: Address; ... }`.
        // The test module imports `system_config::FieldSelection`, so the
        // codegen-internal `FieldSelection` (used by `generate_contract_event_ts_type`)
        // must be referenced via `super::`.
        let event = sablier_named_struct_event();
        let all_evm = system_config::FieldSelection::all_evm();
        let aggregated = super::FieldSelection::new(super::FieldSelectionOptions {
            block_fields: all_evm.block_fields,
            transaction_fields: all_evm.transaction_fields,
        });
        let ts = ProjectTemplate::generate_contract_event_ts_type(
            "SablierLockup",
            &event,
            &aggregated,
            "ChainId",
            "EvmBlock",
            "EvmTransaction",
        );
        insta::assert_snapshot!(ts);
    }

    #[test]
    fn event_template_with_custom_field_selection() {
        let all_evm = system_config::FieldSelection::all_evm();
        let all_ecosystem_fields = Some(super::FieldSelection::new(super::FieldSelectionOptions {
            block_fields: all_evm.block_fields,
            transaction_fields: all_evm.transaction_fields,
        }));
        let event_template = EventTemplate::from_config_event(
            &system_config::Event {
                name: "NewGravatar".to_string(),
                kind: system_config::EventKind::Params(vec![]),
                sighash: "0x50f7d27e90d1a5a38aeed4ceced2e8ec1ff185737aca96d15791b470d3f17363"
                    .to_string(),
                event_signature: String::new(),
                field_selection: Some(FieldSelection {
                    block_fields: vec![],
                    transaction_fields: vec![SelectedField {
                        name: "from".to_string(),
                        data_type: TypeIdent::option(TypeIdent::Address),
                    }],
                }),
            },
            all_ecosystem_fields,
            &"Gravatar".to_string().to_capitalized_options(),
        )
        .unwrap();

        insta::assert_snapshot!(event_template.module_code);
        assert_eq!(event_template.name, "NewGravatar");
    }

    #[test]
    fn internal_config_json_code_generated_for_evm() {
        let json = get_internal_config_json_helper("config1.yaml");
        insta::assert_snapshot!(json);
    }

    #[test]
    fn internal_config_json_code_generated_for_fuel() {
        // Note: Fuel defaults to rollback_on_reorg: false in system_config.rs,
        // which differs from the runtime default of true, so it's included
        let json = get_internal_config_json_helper("fuel-config.yaml");
        insta::assert_snapshot!(json);
    }

    #[test]
    fn internal_config_json_code_with_all_options() {
        let json = get_internal_config_json_helper("config-with-all-options.yaml");
        insta::assert_snapshot!(json);
    }

    #[test]
    fn envio_types_dts_generated_for_evm() {
        let project_template = get_project_template_helper("config1.yaml");
        insta::assert_snapshot!(project_template.envio_types_dts);
    }

    #[test]
    fn envio_types_dts_generated_for_fuel() {
        let project_template = get_project_template_helper("fuel-config.yaml");
        insta::assert_snapshot!(project_template.envio_types_dts);
    }

    #[test]
    fn internal_config_json_code_with_no_contracts() {
        // config4.yaml has empty contracts array - tests that comma is properly
        // placed before addressFormat when contracts section is omitted
        let json = get_internal_config_json_helper("config4.yaml");
        insta::assert_snapshot!(json);
    }

    #[test]
    fn internal_config_json_code_with_multiple_contracts() {
        // config2.yaml has two contracts - tests comma separation between contracts
        let json = get_internal_config_json_helper("config2.yaml");
        insta::assert_snapshot!(json);
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

    #[test]
    fn internal_config_json_code_with_lowercase_contract_name() {
        let json = get_internal_config_json_helper("lowercase-contract-name.yaml");
        insta::assert_snapshot!(json);
    }

    /// End-to-end: `generate_templates` writes the four expected artifacts
    /// (`.envio/types.d.ts`, `.envio/.gitignore`, `envio-env.d.ts`, and for
    /// ReScript projects `src/Indexer.res`) into the project root. Also
    /// verifies that `.envio/.gitignore` is write-once: a user-modified
    /// version is preserved across subsequent codegen runs.
    #[test]
    fn generate_templates_writes_expected_files() {
        use tempdir::TempDir;

        let project_template = get_project_template_helper("config1.yaml");

        // Drive `generate_templates` against a fresh tempdir so we can poke
        // at the on-disk output without polluting the test fixtures.
        let tmp = TempDir::new("envio-codegen-test").expect("create tempdir");
        let project_root = tmp.path().to_path_buf();
        let project_paths = ParsedProjectPaths {
            project_root: project_root.clone(),
            config: project_root.join("config.yaml"),
            envio_dir: project_root.join(".envio"),
        };

        project_template
            .generate_templates(&project_paths)
            .expect("first codegen run");

        let types_dts = project_root.join(".envio/types.d.ts");
        let gitignore = project_root.join(".envio/.gitignore");
        let envio_env = project_root.join("envio-env.d.ts");

        assert!(types_dts.exists(), ".envio/types.d.ts must exist");
        assert!(gitignore.exists(), ".envio/.gitignore must exist");
        assert!(envio_env.exists(), "envio-env.d.ts must exist");

        let types_dts_contents = std::fs::read_to_string(&types_dts).expect("read types.d.ts");
        assert!(
            types_dts_contents.contains("declare module \"envio\""),
            "types.d.ts should augment the envio module",
        );

        let envio_env_contents = std::fs::read_to_string(&envio_env).expect("read envio-env.d.ts");
        assert!(
            envio_env_contents.contains("/// <reference path=\"./.envio/types.d.ts\" />"),
            "envio-env.d.ts should reference .envio/types.d.ts via triple-slash directive",
        );

        let gitignore_contents = std::fs::read_to_string(&gitignore).expect("read .gitignore");
        assert!(
            gitignore_contents.contains("types.d.ts"),
            ".envio/.gitignore should ignore types.d.ts",
        );

        // Write-once: a user edits the .gitignore — codegen must not stomp it.
        let user_edited = "types.d.ts\nmy-extra-rule\n";
        std::fs::write(&gitignore, user_edited).expect("user edits .gitignore");

        project_template
            .generate_templates(&project_paths)
            .expect("second codegen run");

        assert_eq!(
            std::fs::read_to_string(&gitignore).expect("read .gitignore after second run"),
            user_edited,
            "user edits to .envio/.gitignore must be preserved across codegen runs",
        );
    }

    /// Regression: only entities get per-name aliases; enum schema names
    /// often clash with TS reserved words or envio exports, so they're
    /// only available via `Enum<"Name">`.
    #[test]
    fn entities_get_aliases_enums_do_not() {
        let file_level_types =
            "type Enums = {\n  \"accountType\": \"ADMIN\" | \"USER\";\n};\ntype Entities = {\n  \"User\": { readonly id: string };\n};";
        let entity_aliases = vec!["User".to_string()];

        let out = super::ProjectTemplate::wrap_envio_module_augmentation(
            file_level_types,
            &entity_aliases,
            super::Ecosystem::Evm,
            super::ConfigBodies {
                evm_chains: "{}",
                evm_contracts: "{}",
                evm_event_filters: "{}",
                fuel_chains: "{}",
                fuel_contracts: "{}",
                fuel_event_filters: "{}",
                svm_chains: "{}",
                entities: "Entities",
                enums: "Enums",
            },
        );

        assert_eq!(
            (
                out.contains("export type User = Entities[\"User\"];"),
                out.contains("export type AccountType"),
            ),
            (true, false),
            "Got:\n{out}",
        );
    }
}
