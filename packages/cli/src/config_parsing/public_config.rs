use super::{
    entity_parsing::IndexFieldDirection,
    field_types,
    human_config::{self, evm::For, ColumnNameFormat},
    system_config::{
        self, field_type_to_arg_type, named_field_to_arg_def, Abi, Ecosystem, EventKind,
        FuelEventKind, SvmAbi, SvmSchemaSource, SystemConfig,
    },
};
use crate::{config_parsing::chain_helpers::Network, utils::text::Capitalize};
use anyhow::{anyhow, Result};
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
    #[serde(skip_serializing_if = "is_false")]
    is_dev: bool,
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
    svm: Option<SvmConfig<'a>>,
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

impl From<&system_config::Storage> for StorageConfig {
    fn from(s: &system_config::Storage) -> Self {
        Self {
            postgres: s.postgres.is_some(),
            clickhouse: s.clickhouse.is_some(),
        }
    }
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct EntityJson {
    name: String,
    // Mirrors the user's `@storage(...)` directive verbatim: only the args
    // they wrote are emitted. Without a directive the entity gets the
    // backends marked `default` in config.yaml — stamped here, except when
    // they coincide with the enabled backends: then the field is omitted
    // and the ReScript side falls back to the global storage, keeping the
    // JSON byte-identical for projects predating per-backend `default`.
    #[serde(skip_serializing_if = "Option::is_none")]
    storage: Option<EntityStorageJson>,
    properties: Vec<PropertyJson>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    derived_fields: Vec<DerivedFieldJson>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    composite_indices: Vec<Vec<CompositeIndexJson>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
}

#[derive(Serialize, Debug)]
struct EntityStorageJson {
    #[serde(skip_serializing_if = "Option::is_none")]
    postgres: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    clickhouse: Option<bool>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct PropertyJson {
    name: String,
    // Per-backend database column names; each is emitted only when it
    // differs from the default naming the runtime derives from `name`
    // (`name` plus an `_id` suffix for entity references). They can diverge
    // when the backends configure different `column_name_format`s.
    #[serde(skip_serializing_if = "Option::is_none")]
    postgres_db_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    clickhouse_db_name: Option<String>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct DerivedFieldJson {
    field_name: String,
    derived_from_entity: String,
    derived_from_field: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
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
struct SvmConfig<'a> {
    chains: BTreeMap<String, ChainConfig>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    programs: BTreeMap<&'a str, ContractConfig>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SvmAccountFilterJson {
    position: u8,
    values: Vec<String>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    svm: Option<SvmEventItem>,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SvmEventItem {
    #[serde(skip_serializing_if = "Option::is_none")]
    discriminator: Option<String>,
    discriminator_byte_len: u8,
    include_transaction: bool,
    include_logs: bool,
    include_token_balances: bool,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    account_filters: Vec<Vec<SvmAccountFilterJson>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    is_inner: Option<bool>,
    /// Positional account names, in the order the on-chain program expects.
    /// `[]` means the runtime won't expose `decoded.accounts.<name>`; the
    /// raw `instruction.accounts[i]` array is still available.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    accounts: Vec<String>,
    /// Borsh args layout. `[]` means the runtime won't expose
    /// `decoded.args`; the raw `instruction.data` hex is still available.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    args: Vec<human_config::svm::ArgDef>,
}

/// Program-level Borsh schema metadata. Emitted onto `ContractConfig.svm_abi`
/// when at least one instruction in the program has a resolved schema.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct SvmAbiJson {
    program_id: String,
    /// Nominal-type registry referenced by `ArgComposite::Defined`. The
    /// runtime resolves these once per program at startup.
    #[serde(skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    defined_types: std::collections::BTreeMap<String, human_config::svm::ArgType>,
    /// `"anchorIdl"`, `"bundled"`, or `"inline"`. Carried for diagnostics; the
    /// runtime treats all three identically.
    source: &'static str,
}

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
struct ContractConfig {
    abi: Box<serde_json::value::RawValue>,
    #[serde(skip_serializing_if = "Option::is_none")]
    handler: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    events: Vec<ContractEventItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    svm_abi: Option<SvmAbiJson>,
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
    pub fn to_public_config_json(&self, is_dev: bool) -> Result<String> {
        let cfg = self;

        let active_chains: Vec<_> = cfg.get_chains().into_iter().filter(|c| !c.skip).collect();

        if active_chains.is_empty() {
            return Err(anyhow!(
                "All chains are skipped. At least one chain must be active to run the indexer."
            ));
        }

        // Build chains map
        let chains: BTreeMap<String, ChainConfig> = active_chains
            .into_iter()
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
                                    Some(For::Realtime) => "realtime",
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
                    system_config::DataSource::Svm {
                        rpc,
                        hypersync_endpoint_url,
                    } => (hypersync_endpoint_url.clone(), vec![], rpc.clone()),
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
                    let abi_raw = match &contract.abi {
                        Abi::Evm(abi) => {
                            let abi_value: serde_json::Value = serde_json::from_str(&abi.raw)?;
                            let abi_compact = serde_json::to_string(&abi_value)?;
                            serde_json::value::RawValue::from_string(abi_compact)?
                        }
                        Abi::Fuel(abi) => {
                            let abi_value: serde_json::Value = serde_json::from_str(&abi.raw)?;
                            let abi_compact = serde_json::to_string(&abi_value)?;
                            serde_json::value::RawValue::from_string(abi_compact)?
                        }
                        Abi::Svm(_) => serde_json::value::RawValue::from_string("null".into())?,
                    };

                    let events: Vec<ContractEventItem> = contract
                        .events
                        .iter()
                        .map(|e| {
                            let (params, kind, svm) = match &e.kind {
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
                                    (params, None, None)
                                }
                                EventKind::Fuel(fuel_kind) => {
                                    let kind_str = match fuel_kind {
                                        FuelEventKind::LogData(_) => "logData",
                                        FuelEventKind::Mint => "mint",
                                        FuelEventKind::Burn => "burn",
                                        FuelEventKind::Transfer => "transfer",
                                        FuelEventKind::Call => "call",
                                    };
                                    (vec![], Some(kind_str.to_string()), None)
                                }
                                EventKind::Svm(svm_kind) => {
                                    let svm_item = SvmEventItem {
                                        discriminator: svm_kind.discriminator.clone(),
                                        discriminator_byte_len: svm_kind.discriminator_byte_len,
                                        include_transaction: svm_kind.include_transaction,
                                        include_logs: svm_kind.include_logs,
                                        include_token_balances: svm_kind.include_token_balances,
                                        account_filters: svm_kind
                                            .account_filters
                                            .iter()
                                            .map(|group| {
                                                group
                                                    .iter()
                                                    .map(|af| SvmAccountFilterJson {
                                                        position: af.position,
                                                        values: af.values.clone(),
                                                    })
                                                    .collect()
                                            })
                                            .collect(),
                                        is_inner: svm_kind.is_inner,
                                        accounts: svm_kind.accounts.clone(),
                                        args: svm_kind
                                            .args
                                            .iter()
                                            .map(named_field_to_arg_def)
                                            .collect(),
                                    };
                                    (vec![], Some("svmInstruction".to_string()), Some(svm_item))
                                }
                            };
                            ContractEventItem {
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
                                svm,
                            }
                        })
                        .collect();
                    let svm_abi = match &contract.abi {
                        Abi::Svm(SvmAbi {
                            program_id,
                            instructions: _,
                            defined_types,
                            source,
                        }) => Some(SvmAbiJson {
                            program_id: program_id.clone(),
                            defined_types: defined_types
                                .iter()
                                .map(|(name, ty)| (name.clone(), field_type_to_arg_type(ty)))
                                .collect(),
                            source: match source {
                                SvmSchemaSource::AnchorIdl { .. } => "anchorIdl",
                                SvmSchemaSource::Bundled { .. } => "bundled",
                                SvmSchemaSource::Inline => "inline",
                            },
                        }),
                        _ => None,
                    };

                    Ok((
                        contract.name.as_str(),
                        ContractConfig {
                            abi: abi_raw,
                            handler: contract.handler_path.clone(),
                            events,
                            svm_abi,
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
            Ecosystem::Svm => (
                None,
                None,
                Some(SvmConfig {
                    chains,
                    programs: contracts,
                }),
            ),
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
                        let db_name_for =
                            |backend: Option<system_config::StorageBackend>| match backend
                                .map(|b| b.column_name_format)
                            {
                                None | Some(ColumnNameFormat::Original) => None,
                                Some(ColumnNameFormat::SnakeCase) => {
                                    let db_name = f.db_column_name(ColumnNameFormat::SnakeCase);
                                    if db_name == f.db_column_name(ColumnNameFormat::Original) {
                                        None
                                    } else {
                                        Some(db_name)
                                    }
                                }
                            };
                        PropertyJson {
                            name: f.field_name.clone(),
                            postgres_db_name: db_name_for(cfg.storage.postgres),
                            clickhouse_db_name: db_name_for(cfg.storage.clickhouse),
                            field_type,
                            is_nullable: f.is_nullable,
                            is_array: f.is_array,
                            is_index: f.is_index,
                            linked_entity: f.linked_entity.clone(),
                            enum_name,
                            entity: entity_name,
                            precision,
                            scale,
                            description: f.description.clone(),
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
                                description: df.description,
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

                let storage = if entity.has_storage_directive() {
                    Some(EntityStorageJson {
                        postgres: entity.postgres,
                        clickhouse: entity.clickhouse,
                    })
                } else {
                    let postgres_default = cfg.storage.postgres.is_some_and(|b| b.entity_default);
                    let clickhouse_default =
                        cfg.storage.clickhouse.is_some_and(|b| b.entity_default);
                    if (postgres_default, clickhouse_default)
                        == (
                            cfg.storage.postgres.is_some(),
                            cfg.storage.clickhouse.is_some(),
                        )
                    {
                        None
                    } else {
                        // Emitted in the same shape a positive @storage directive
                        // would produce, so switching an entity between the
                        // directive and a config-level default doesn't diff.
                        Some(EntityStorageJson {
                            postgres: postgres_default.then_some(true),
                            clickhouse: clickhouse_default.then_some(true),
                        })
                    }
                };

                Ok(EntityJson {
                    name: entity.name.clone(),
                    storage,
                    properties,
                    derived_fields,
                    composite_indices,
                    description: entity.description.clone(),
                })
            })
            .collect::<Result<_>>()?;

        let config = PublicConfigJson {
            version: system_config::VERSION,
            name: &cfg.name,
            description: cfg.human_config.get_base_config().description.as_deref(),
            handlers: cfg.handlers.as_deref(),
            is_dev,
            full_batch_size: cfg.human_config.get_base_config().full_batch_size,
            rollback_on_reorg: cfg.rollback_on_reorg,
            save_full_history: cfg.save_full_history,
            raw_events: cfg.enable_raw_events,
            storage: (&cfg.storage).into(),
            evm,
            fuel,
            svm,
            enums: enums_json,
            entities: entities_json,
        };

        Ok(serde_json::to_string_pretty(&config)? + "\n")
    }

    pub fn to_view_json(&self) -> Result<String> {
        let view = ConfigView {
            version: system_config::VERSION,
            storage: (&self.storage).into(),
        };
        Ok(serde_json::to_string_pretty(&view)?)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigView<'a> {
    version: &'a str,
    storage: StorageConfig,
}
