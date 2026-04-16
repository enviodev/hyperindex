use super::{
    entity_parsing::IndexFieldDirection,
    field_types,
    human_config::evm::For,
    system_config::{self, Abi, Ecosystem, EventKind, FuelEventKind, SystemConfig},
};
use crate::{config_parsing::chain_helpers::Network, persisted_state, utils::text::Capitalize};
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;

fn is_true(v: &bool) -> bool {
    *v
}

fn is_false(v: &bool) -> bool {
    !v
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub(crate) struct PublicConfigJson<'a> {
    version: &'a str,
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
    storage: StorageConfig,
    #[serde(skip_serializing_if = "Option::is_none")]
    evm: Option<EvmConfig<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fuel: Option<FuelConfig<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    svm: Option<SvmConfig>,
    enums: BTreeMap<String, Vec<String>>,
    entities: Vec<EntityJson>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct StorageConfig {
    postgres: bool,
    #[serde(skip_serializing_if = "is_false")]
    clickhouse: bool,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct EntityJson {
    name: String,
    properties: Vec<PropertyJson>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    derived_fields: Vec<DerivedFieldJson>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    composite_indices: Vec<Vec<CompositeIndexJson>>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct PropertyJson {
    name: String,
    #[serde(rename = "type")]
    field_type: String,
    #[serde(skip_serializing_if = "is_false")]
    is_nullable: bool,
    #[serde(skip_serializing_if = "is_false")]
    is_array: bool,
    #[serde(skip_serializing_if = "is_false")]
    is_index: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    linked_entity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "enum")]
    enum_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    entity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    precision: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    scale: Option<u32>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct DerivedFieldJson {
    field_name: String,
    derived_from_entity: String,
    derived_from_field: String,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct CompositeIndexJson {
    field_name: String,
    direction: String,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct EvmConfig<'a> {
    chains: BTreeMap<String, ChainConfig>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    contracts: BTreeMap<&'a str, ContractConfig>,
    address_format: &'a str,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    global_block_fields: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    global_transaction_fields: Vec<String>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct FuelConfig<'a> {
    chains: BTreeMap<String, ChainConfig>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    contracts: BTreeMap<&'a str, ContractConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SvmConfig {
    chains: BTreeMap<String, ChainConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct RpcConfig {
    url: String,
    #[serde(rename = "for")]
    source_for: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    ws: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    initial_block_interval: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    backoff_multiplicative: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    acceleration_additive: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    interval_ceiling: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    backoff_millis: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback_stall_timeout: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    query_timeout_millis: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    polling_interval: Option<u32>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct ChainConfig {
    id: u64,
    start_block: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    end_block: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_reorg_depth: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    block_lag: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    hypersync: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    rpcs: Vec<RpcConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rpc: Option<String>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    contracts: BTreeMap<String, ChainContractConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct ChainContractConfig {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    addresses: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start_block: Option<u64>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct EventParam {
    name: String,
    abi_type: String,
    #[serde(skip_serializing_if = "is_false")]
    indexed: bool,
    /// Recursive tuple component metadata. Present only when the top-level type is a
    /// struct / array of structs / nested tuple. Runtime uses this to rebuild named
    /// record shapes from positional decoder output.
    #[serde(skip_serializing_if = "Option::is_none")]
    components: Option<Vec<EventParamComponent>>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct EventParamComponent {
    /// Component name from the ABI. For unnamed slots in mixed-name tuples the
    /// CLI fills in the positional index (`"0"`, `"1"`, ...) so the runtime
    /// always has a valid record key that matches the codegen'd type.
    name: String,
    abi_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    components: Option<Vec<EventParamComponent>>,
}

/// Walk an `AbiType` to produce the `components` tree that the runtime needs to
/// rebuild named records. Every tuple (Solidity struct, mixed-name, or fully
/// anonymous) emits components so the runtime can remap positional decoder
/// output into a keyed object — unnamed components use their positional index
/// as the key (`"0"`, `"1"`, …).
fn abi_type_to_components(
    ty: &crate::config_parsing::abi_compat::AbiType,
) -> Option<Vec<EventParamComponent>> {
    use crate::config_parsing::abi_compat::AbiType;
    match ty {
        // `AbiTupleField` constructors normalise empty source names to `None`,
        // so `Some(_)` always carries a non-empty identifier.
        AbiType::Tuple(fields) => Some(
            fields
                .iter()
                .enumerate()
                .map(|(i, f)| EventParamComponent {
                    name: f.name.clone().unwrap_or_else(|| i.to_string()),
                    abi_type: f.kind.to_signature_string(),
                    components: abi_type_to_components(&f.kind),
                })
                .collect(),
        ),
        // For arrays, descend into the element type so struct arrays still surface
        // component metadata under the param.
        AbiType::Array(inner) | AbiType::FixedArray(inner, _) => abi_type_to_components(inner),
        _ => None,
    }
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct ContractEventItem {
    event: String,
    name: String,
    sighash: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    params: Vec<EventParam>,
    #[serde(skip_serializing_if = "Option::is_none")]
    kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    block_fields: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    transaction_fields: Option<Vec<String>>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct ContractConfig {
    abi: Box<serde_json::value::RawValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    handler: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    events: Vec<ContractEventItem>,
}

fn chain_id_to_name(chain_id: u64, ecosystem: &Ecosystem) -> String {
    use convert_case::{Case, Casing};
    match ecosystem {
        Ecosystem::Evm => Network::from_repr(chain_id)
            .map(|n| n.to_string().to_case(Case::Camel))
            .unwrap_or_else(|| chain_id.to_string()),
        Ecosystem::Fuel | Ecosystem::Svm => chain_id.to_string(),
    }
}

impl SystemConfig {
    pub fn to_public_config_json(&self) -> Result<String> {
        let cfg = self;

        // Build chains map
        let chains: BTreeMap<String, ChainConfig> = cfg
            .get_chains()
            .iter()
            .map(|network| {
                let chain_name = chain_id_to_name(network.id, &cfg.get_ecosystem());

                let (hypersync, rpcs, rpc) = match &network.sync_source {
                    system_config::DataSource::Evm { main, rpcs } => {
                        let hypersync_url = match main {
                            system_config::MainEvmDataSource::HyperSync {
                                hypersync_endpoint_url,
                            } => Some(hypersync_endpoint_url.clone()),
                            system_config::MainEvmDataSource::Rpc(_) => None,
                        };
                        let rpc_configs: Vec<RpcConfig> = rpcs
                            .iter()
                            .map(|rpc| RpcConfig {
                                url: rpc.url.clone(),
                                source_for: match rpc.source_for {
                                    Some(For::Sync) => "sync",
                                    Some(For::Fallback) => "fallback",
                                    Some(For::Live) => "live",
                                    None => unreachable!(
                                        "source_for should be resolved by from_evm_network_config"
                                    ),
                                },
                                ws: rpc.ws.clone(),
                                initial_block_interval: rpc.initial_block_interval,
                                backoff_multiplicative: rpc.backoff_multiplicative,
                                acceleration_additive: rpc.acceleration_additive,
                                interval_ceiling: rpc.interval_ceiling,
                                backoff_millis: rpc.backoff_millis,
                                fallback_stall_timeout: rpc.fallback_stall_timeout,
                                query_timeout_millis: rpc.query_timeout_millis,
                                polling_interval: rpc.polling_interval,
                            })
                            .collect();
                        (hypersync_url, rpc_configs, None)
                    }
                    system_config::DataSource::Fuel {
                        hypersync_endpoint_url,
                    } => (Some(hypersync_endpoint_url.clone()), vec![], None),
                    system_config::DataSource::Svm { rpc } => (None, vec![], Some(rpc.clone())),
                };

                let chain_contracts: BTreeMap<String, ChainContractConfig> = network
                    .contracts
                    .iter()
                    .map(|nc| {
                        (
                            nc.name.capitalize(),
                            ChainContractConfig {
                                addresses: nc.addresses.clone(),
                                start_block: nc.start_block,
                            },
                        )
                    })
                    .collect();

                (
                    chain_name,
                    ChainConfig {
                        id: network.id,
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: network.max_reorg_depth,
                        block_lag: network.block_lag,
                        hypersync,
                        rpcs,
                        rpc,
                        contracts: chain_contracts,
                    },
                )
            })
            .collect();

        // Build contracts map
        let contracts: BTreeMap<&str, ContractConfig> =
            cfg.contracts
                .values()
                .map(|contract| -> Result<(&str, ContractConfig)> {
                    let abi_str = match &contract.abi {
                        Abi::Evm(abi) => &abi.raw,
                        Abi::Fuel(abi) => &abi.raw,
                    };
                    let abi_value: serde_json::Value = serde_json::from_str(abi_str)?;
                    let abi_compact = serde_json::to_string(&abi_value)?;
                    let abi_raw = serde_json::value::RawValue::from_string(abi_compact)?;

                    let events: Vec<ContractEventItem> = contract
                        .events
                        .iter()
                        .map(|e| {
                            let (params, kind) = match &e.kind {
                                EventKind::Params(event_params) => {
                                    let params = event_params
                                        .iter()
                                        .map(|p| EventParam {
                                            name: p.name.clone(),
                                            abi_type: p.kind.to_signature_string(),
                                            indexed: p.indexed,
                                            // Indexed structs/tuples are delivered as keccak256
                                            // topic hashes, not decoded tuples, so the runtime
                                            // can't rebuild a named record from them. Skip the
                                            // component metadata so the decoder takes the legacy
                                            // path and leaves the value as the raw hash.
                                            components: if p.indexed {
                                                None
                                            } else {
                                                abi_type_to_components(&p.kind)
                                            },
                                        })
                                        .collect();
                                    (params, None)
                                }
                                EventKind::Fuel(fuel_kind) => {
                                    let kind_str = match fuel_kind {
                                        FuelEventKind::LogData(_) => "logData",
                                        FuelEventKind::Mint => "mint",
                                        FuelEventKind::Burn => "burn",
                                        FuelEventKind::Transfer => "transfer",
                                        FuelEventKind::Call => "call",
                                    };
                                    (vec![], Some(kind_str.to_string()))
                                }
                            };
                            ContractEventItem {
                                event: e.event_signature.clone(),
                                name: e.name.clone(),
                                sighash: e.sighash.clone(),
                                params,
                                kind,
                                block_fields: e.field_selection.as_ref().map(|fs| {
                                    fs.block_fields.iter().map(|f| f.name.clone()).collect()
                                }),
                                transaction_fields: e.field_selection.as_ref().map(|fs| {
                                    fs.transaction_fields
                                        .iter()
                                        .map(|f| f.name.clone())
                                        .collect()
                                }),
                            }
                        })
                        .collect();
                    Ok((
                        contract.name.as_str(),
                        ContractConfig {
                            abi: abi_raw,
                            handler: contract.handler_path.clone(),
                            events,
                        },
                    ))
                })
                .collect::<Result<_>>()?;

        // Build ecosystem config
        let (evm, fuel, svm) = match cfg.get_ecosystem() {
            Ecosystem::Evm => (
                Some(EvmConfig {
                    chains,
                    contracts,
                    address_format: if cfg.lowercase_addresses {
                        "lowercase"
                    } else {
                        "checksum"
                    },
                    global_block_fields: cfg
                        .field_selection
                        .block_fields
                        .iter()
                        .map(|f| f.name.clone())
                        .collect(),
                    global_transaction_fields: cfg
                        .field_selection
                        .transaction_fields
                        .iter()
                        .map(|f| f.name.clone())
                        .collect(),
                }),
                None,
                None,
            ),
            Ecosystem::Fuel => (None, Some(FuelConfig { chains, contracts }), None),
            Ecosystem::Svm => (None, None, Some(SvmConfig { chains })),
        };

        // Build multichain value
        let multichain = match cfg.multichain {
            crate::config_parsing::human_config::evm::Multichain::Ordered => Some("ordered"),
            crate::config_parsing::human_config::evm::Multichain::Unordered => None,
        };

        let enums_json: BTreeMap<String, Vec<String>> = cfg
            .get_gql_enums()
            .iter()
            .map(|e| (e.name.clone(), e.values.clone()))
            .collect();

        let entities_json: Vec<EntityJson> = cfg
            .get_entities()
            .iter()
            .map(|entity| {
                let postgres_fields: Vec<field_types::Field> = entity
                    .get_fields()
                    .iter()
                    .map(|gql_field| gql_field.get_postgres_field(&cfg.schema, entity))
                    .collect::<Result<Vec<_>>>()?
                    .into_iter()
                    .flatten()
                    .collect();

                let properties = postgres_fields
                    .iter()
                    .map(|f| {
                        use field_types::Primitive;
                        let (field_type, enum_name, entity_name, precision, scale) =
                            match &f.field_type {
                                Primitive::Boolean => ("boolean".into(), None, None, None, None),
                                Primitive::String => ("string".into(), None, None, None, None),
                                Primitive::Int32 => ("int".into(), None, None, None, None),
                                Primitive::BigInt { precision } => {
                                    ("bigint".into(), None, None, *precision, None)
                                }
                                Primitive::BigDecimal(config) => {
                                    let (p, s) = match config {
                                        Some((p, s)) => (Some(*p), Some(*s)),
                                        None => (None, None),
                                    };
                                    ("bigdecimal".into(), None, None, p, s)
                                }
                                Primitive::Number => ("float".into(), None, None, None, None),
                                Primitive::Serial => ("serial".into(), None, None, None, None),
                                Primitive::Json => ("json".into(), None, None, None, None),
                                Primitive::Date => ("date".into(), None, None, None, None),
                                Primitive::Enum(name) => {
                                    ("enum".into(), Some(name.clone()), None, None, None)
                                }
                                Primitive::Entity(name) => {
                                    ("entity".into(), None, Some(name.clone()), None, None)
                                }
                            };
                        PropertyJson {
                            name: f.field_name.clone(),
                            field_type,
                            is_nullable: f.is_nullable,
                            is_array: f.is_array,
                            is_index: f.is_index,
                            linked_entity: f.linked_entity.clone(),
                            enum_name,
                            entity: entity_name,
                            precision,
                            scale,
                        }
                    })
                    .collect();

                let derived_fields = entity
                    .get_fields()
                    .iter()
                    .filter_map(|gql_field| {
                        gql_field
                            .get_derived_from_field()
                            .map(|df| DerivedFieldJson {
                                field_name: df.field_name,
                                derived_from_entity: df.derived_from_entity,
                                derived_from_field: df.derived_from_field,
                            })
                    })
                    .collect();

                let composite_indices = entity
                    .get_composite_indices()
                    .into_iter()
                    .map(|fields| {
                        fields
                            .iter()
                            .map(|f| CompositeIndexJson {
                                field_name: f.name.clone(),
                                direction: match f.direction {
                                    IndexFieldDirection::Asc => "Asc".to_string(),
                                    IndexFieldDirection::Desc => "Desc".to_string(),
                                },
                            })
                            .collect()
                    })
                    .collect();

                Ok(EntityJson {
                    name: entity.name.clone(),
                    properties,
                    derived_fields,
                    composite_indices,
                })
            })
            .collect::<Result<_>>()?;

        let config = PublicConfigJson {
            version: persisted_state::current_version(),
            name: &cfg.name,
            description: cfg.human_config.get_base_config().description.as_deref(),
            handlers: cfg.handlers.as_deref(),
            multichain,
            full_batch_size: cfg.human_config.get_base_config().full_batch_size,
            rollback_on_reorg: cfg.rollback_on_reorg,
            save_full_history: cfg.save_full_history,
            raw_events: cfg.enable_raw_events,
            storage: StorageConfig {
                postgres: cfg.storage.postgres,
                clickhouse: cfg.storage.clickhouse,
            },
            evm,
            fuel,
            svm,
            enums: enums_json,
            entities: entities_json,
        };

        Ok(serde_json::to_string_pretty(&config)? + "\n")
    }
}
