use super::{
    chain_helpers::get_max_reorg_depth_from_id,
    entity_parsing::{Entity, GraphQLEnum, Schema},
    human_config::{
        self,
        evm::{
            Chain as EvmChain, EventConfig as EvmEventConfig, For, HumanConfig as EvmConfig, Rpc,
            RpcSelection,
        },
        fuel::{EventConfig as FuelEventConfig, HumanConfig as FuelConfig},
        HumanConfig,
    },
    hypersync_endpoints,
    validation::{self, validate_names_valid_rescript},
};
use crate::{
    config_parsing::human_config::evm::{RpcBlockField, RpcTransactionField},
    constants::{links, project_paths::DEFAULT_SCHEMA_PATH},
    evm::abi::AbiOrNestedAbi,
    fuel::abi::{FuelAbi, BURN_EVENT_NAME, CALL_EVENT_NAME, MINT_EVENT_NAME, TRANSFER_EVENT_NAME},
    project_paths::{path_utils, ParsedProjectPaths},
    type_schema::TypeIdent,
    utils::unique_hashmap,
};
use alloy_json_abi::{Event as AlloyEvent, JsonAbi};
use anyhow::{anyhow, Context, Result};
use dotenvy::{EnvLoader, EnvMap, EnvSequence};
use itertools::Itertools;

use super::abi_compat::EventParam;
use regex::Regex;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    env, fs,
    path::{Path, PathBuf},
};

use hypersync_client_solana::decode::{
    metaplex_token_metadata, schema_from_anchor_idl_json, EnumVariant as SvmEnumVariant,
    FieldType as SvmFieldType, NamedField as SvmNamedField, ProgramSchema as SvmProgramSchema,
};

type ContractNameKey = String;
type NetworkIdKey = u64;
type EntityKey = String;
type GraphqlEnumKey = String;
type ChainMap = HashMap<NetworkIdKey, Chain>;
type ContractMap = HashMap<ContractNameKey, Contract>;
pub type EntityMap = HashMap<EntityKey, Entity>;
pub type GraphQlEnumMap = HashMap<GraphqlEnumKey, GraphQLEnum>;

#[derive(Debug, PartialEq)]
pub enum Ecosystem {
    Evm,
    Fuel,
    Svm,
}

// Allows to get an env var with a lazy loading of .env file
#[derive(Debug)]
pub struct EnvState {
    // Lazy loading of .env file
    maybe_dotenv: Option<EnvMap>,
    project_root: PathBuf,
}

impl EnvState {
    pub fn new(project_root: &Path) -> Self {
        EnvState {
            maybe_dotenv: None,
            project_root: PathBuf::from(project_root),
        }
    }

    pub fn var(&mut self, name: &str) -> Option<String> {
        match std::env::var(name) {
            Ok(val) => Some(val),
            Err(_) => {
                let result = match &self.maybe_dotenv {
                    Some(env_map) => env_map.var(name),
                    None => {
                        match EnvLoader::with_path(self.project_root.join(".env"))
                            .sequence(EnvSequence::InputOnly)
                            .load()
                        {
                            Ok(env_map) => {
                                self.maybe_dotenv = Some(env_map.clone());
                                env_map.var(name)
                            }
                            Err(err) => {
                                match err {
                                    dotenvy::Error::Io(_, _) => (),
                                    _ => println!(
                                        "Warning: Failed loading .env file with unexpected error: \
                                         {err}"
                                    ),
                                };
                                self.maybe_dotenv = Some(EnvMap::new());
                                Err(err)
                            }
                        }
                    }
                };
                result.ok()
            }
        }
    }
}

mod interpolation {
    use anyhow::{anyhow, Result};
    use regex::{Captures, Regex};

    #[derive(PartialEq)]
    enum InterpolationResult {
        DirectSubstitution,
        InvalidName,
        DefaultForMissing(String),
        DefaultForMissingAndEmpty(String),
    }

    fn parse_capture(inner: &str) -> (String, InterpolationResult) {
        let (name, result) = match (inner.find(":-"), inner.find('-')) {
            (Some(pos1), Some(pos2)) if pos1 < pos2 => {
                let name = &inner[..pos1];
                let default_value = inner[pos1 + 2..].to_string();
                (
                    name,
                    InterpolationResult::DefaultForMissingAndEmpty(default_value),
                )
            }
            (_, Some(pos)) => {
                let name = &inner[..pos];
                let default_value = inner[pos + 1..].to_string();
                (name, InterpolationResult::DefaultForMissing(default_value))
            }
            (Some(pos), _) => {
                let name = &inner[..pos];
                let default_value = inner[pos + 2..].to_string();
                (
                    name,
                    InterpolationResult::DefaultForMissingAndEmpty(default_value),
                )
            }
            (None, None) => (inner, InterpolationResult::DirectSubstitution),
        };

        if name.is_empty()
            || name.chars().next().is_some_and(|c| c.is_ascii_digit())
            || !name.chars().all(|c| {
                matches!(c,
                'a'..='z' | 'A'..='Z' | '0'..='9' | '_')
            })
        {
            return (name.to_string(), InterpolationResult::InvalidName);
        }

        (name.to_string(), result)
    }

    pub fn interpolate_config_variables(
        config_string: String,
        mut get_env: impl FnMut(&str) -> Option<String>,
    ) -> Result<String> {
        let mut missing_vars = Vec::new();
        let mut invalid_vars = Vec::new();

        // If we don't have `[^}]` and simpley use `.` in the regex, it will match the last `}` and the rest of the string until the last `}`
        let re = Regex::new(r"\$\{([^}]*)\}").unwrap();
        let config_string = re.replace_all(&config_string, |caps: &Captures| {
            let name = &caps[1];
            let (name, interpolation_result) = parse_capture(name);
            if interpolation_result == InterpolationResult::InvalidName {
                // Wrap invalid vars with quotes to make them more visible in the error message
                // Don't need to do this for missing ones, because they won't have spaces in the name
                invalid_vars.push(format!("\"{name}\""));
                return "".to_string();
            }
            match (get_env(&name), interpolation_result) {
                (Some(val), InterpolationResult::DefaultForMissingAndEmpty(default))
                    if val.is_empty() =>
                {
                    default
                }
                (Some(val), _) => val,
                (None, InterpolationResult::DefaultForMissing(default))
                | (None, InterpolationResult::DefaultForMissingAndEmpty(default)) => default,
                (None, _) => {
                    missing_vars.push(name.to_string());
                    "".to_string()
                }
            }
        });

        if !invalid_vars.is_empty() {
            return Err(anyhow!(
                "Failed to interpolate variables into your config file. Invalid environment \
                 variables are present: {}",
                invalid_vars.join(", ")
            ));
        }

        if !missing_vars.is_empty() {
            return Err(anyhow!(
                "Failed to interpolate variables into your config file. Environment variables are \
                 not present: {}",
                missing_vars.join(", ")
            ));
        }

        Ok(config_string.to_string())
    }

    #[cfg(test)]
    mod test {
        use pretty_assertions::assert_eq;

        #[test]
        fn test_interpolate_config_variables_with_single_capture() {
            let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    start_block: 0
"#;
            let interpolated_config_string =
                super::interpolate_config_variables(config_string.to_string(), |name| match name {
                    "ENVIO_NETWORK_ID" => Some("0".to_string()),
                    _ => None,
                })
                .unwrap();
            assert_eq!(
                interpolated_config_string,
                r#"
chains:
  - id: 0
    start_block: 0
"#
            );
        }

        #[test]
        fn test_interpolate_config_variables_with_multiple_captures() {
            let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    rpc:
      url: ${ENVIO_ETH_RPC_URL}?api_key=${ENVIO_ETH_RPC_KEY}
"#;
            let interpolated_config_string =
                super::interpolate_config_variables(config_string.to_string(), |name| match name {
                    "ENVIO_NETWORK_ID" => Some("0".to_string()),
                    "ENVIO_ETH_RPC_URL" => Some("https://eth.com".to_string()),
                    "ENVIO_ETH_RPC_KEY" => Some("foo".to_string()),
                    _ => None,
                })
                .unwrap();
            assert_eq!(
                interpolated_config_string,
                r#"
chains:
  - id: 0
    rpc:
      url: https://eth.com?api_key=foo
"#
            );
        }

        #[test]
        fn test_interpolate_config_variables_with_no_captures() {
            let config_string = r#"
chains:
  - id: 0
    start_block: 0
"#;
            let interpolated_config_string =
                super::interpolate_config_variables(config_string.to_string(), |name| match name {
                    "ENVIO_NETWORK_ID" => Some("0".to_string()),
                    _ => None,
                })
                .unwrap();
            assert_eq!(
                interpolated_config_string,
                r#"
chains:
  - id: 0
    start_block: 0
"#
            );
        }

        #[test]
        fn test_interpolate_config_variables_with_missing_env() {
            let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    rpc:
      url: https://eth.com?api_key=${ENVIO_ETH_API_KEY}
"#;
            let interpolated_config_string =
                super::interpolate_config_variables(config_string.to_string(), |name| match name {
                    "ENVIO_NETWORK_ID" => Some("0".to_string()),
                    _ => None,
                })
                .unwrap_err();
            assert_eq!(
                interpolated_config_string.to_string(),
                r#"Failed to interpolate variables into your config file. Environment variables are not present: ENVIO_ETH_API_KEY"#
            );
        }

        #[test]
        fn test_interpolate_config_variables_with_invalid_captures_and_missing_env() {
            let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    rpc:
      url: ${My RPC URL}?api_key=${}
"#;
            let interpolated_config_string =
                super::interpolate_config_variables(config_string.to_string(), |name| match name {
                    "ENVIO_NETWORK_ID" => Some("0".to_string()),
                    _ => None,
                })
                .unwrap_err();
            assert_eq!(
                interpolated_config_string.to_string(),
                r#"Failed to interpolate variables into your config file. Invalid environment variables are present: "My RPC URL", """#
            );
        }

        #[test]
        fn test_interpolate_config_variables_with_different_substituations() {
            let config_string = r#"
DirectSubstitution with existing env: "${EXISTING_ENV}"
DefaultForMissing with existing env: "${EXISTING_ENV-default}"
DefaultForMissing with existing env and many dashes: "${EXISTING_ENV----:---}"
DefaultForMissing with missing env: "${MISSING_ENV-default}"
DefaultForMissing with missing env and many dashes: "${MISSING_ENV----:---}"
DefaultForMissing with missing env and empty default: "${MISSING_ENV-}"
DefaultForMissingAndEmpty with existing env: "${EXISTING_ENV:-default}"
DefaultForMissingAndEmpty with existing env and many dashes: "${EXISTING_ENV:----:---}"
DefaultForMissingAndEmpty with missing env: "${MISSING_ENV:-default}"
DefaultForMissingAndEmpty with missing env and many dashes: "${MISSING_ENV:----:---}"
DefaultForMissingAndEmpty with missing env and empty default: "${MISSING_ENV:-}"
DefaultForMissingAndEmpty with empty env: "${EMPTY_ENV:-default}"
DefaultForMissingAndEmpty with empty env and many dashes: "${EMPTY_ENV:----:---}"
DefaultForMissingAndEmpty with empty env and empty default: "${EMPTY_ENV:-}"
"#;
            let interpolated_config_string =
                super::interpolate_config_variables(config_string.to_string(), |name| match name {
                    "EXISTING_ENV" => Some("val".to_string()),
                    "EMPTY_ENV" => Some("".to_string()),
                    _ => None,
                })
                .unwrap();
            assert_eq!(
                interpolated_config_string,
                r#"
DirectSubstitution with existing env: "val"
DefaultForMissing with existing env: "val"
DefaultForMissing with existing env and many dashes: "val"
DefaultForMissing with missing env: "default"
DefaultForMissing with missing env and many dashes: "---:---"
DefaultForMissing with missing env and empty default: ""
DefaultForMissingAndEmpty with existing env: "val"
DefaultForMissingAndEmpty with existing env and many dashes: "val"
DefaultForMissingAndEmpty with missing env: "default"
DefaultForMissingAndEmpty with missing env and many dashes: "---:---"
DefaultForMissingAndEmpty with missing env and empty default: ""
DefaultForMissingAndEmpty with empty env: "default"
DefaultForMissingAndEmpty with empty env and many dashes: "---:---"
DefaultForMissingAndEmpty with empty env and empty default: ""
"#
            );
        }
    }
}

//Validates version name (3 digits separated by period ".")
//Returns false if there are any additional chars as this should imply
//it is a dev release version or an unstable release
fn is_valid_release_version_number(version: &str) -> bool {
    let re_version_pattern = Regex::new(r"^\d+\.\d+\.\d+(-(rc|alpha)\.\d+)?$")
        .expect("version regex pattern should be valid regex");
    re_version_pattern.is_match(version) || version.contains("-main-")
}

/// Version baked into the binary at compile time from Cargo.toml.
/// CI patches Cargo.toml with the release version before building.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Returns the envio npm package specifier for codegen.
/// - Release builds (valid semver `VERSION`) → that version, for npm.
/// - Dev builds → `file:{envio_package_dir}`, where the caller (NAPI host
///   or a test) supplies the absolute path to `packages/envio`.
///
/// A dev build without an `envio_package_dir` is a configuration error —
/// there's no reliable way to locate the JS package from inside Rust alone.
pub fn get_envio_version(envio_package_dir: Option<&str>) -> Result<String> {
    if is_valid_release_version_number(VERSION) {
        return Ok(VERSION.to_string());
    }

    let pkg_dir = envio_package_dir.ok_or_else(|| {
        anyhow!(
            "envio version is not a release ({VERSION}) and no envio_package_dir was supplied. \
             Run via the NAPI host (which resolves it from import.meta.url) or pass an explicit path."
        )
    })?;

    // Format as `file:{dir}` so the generated `package.json` resolves to
    // the SAME envio instance as the parent, avoiding duplicate module
    // instances that break shared registries (HandlerRegister, Prometheus
    // metrics).
    let pkg = PathBuf::from(pkg_dir);
    if !pkg.is_dir() {
        return Err(anyhow!(
            "envio_package_dir does not exist or is not a directory: {}",
            pkg.display()
        ));
    }
    Ok(format!("file:{}", pkg.to_string_lossy()))
}

#[derive(Debug)]
pub struct SystemConfig {
    pub name: String,
    pub schema_path: String,
    pub parsed_project_paths: ParsedProjectPaths,
    pub chains: ChainMap,
    pub contracts: ContractMap,
    pub rollback_on_reorg: bool,
    pub save_full_history: bool,
    pub schema: Schema,
    pub field_selection: FieldSelection,
    pub enable_raw_events: bool,
    pub storage: Storage,
    pub human_config: HumanConfig,
    pub lowercase_addresses: bool,
    pub handlers: Option<String>,
    // Project uses ReScript when a rescript.json sits at the project root —
    // file existence is the source of truth; no explicit flag in config.yaml.
    pub is_rescript: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Storage {
    pub postgres: bool,
    pub clickhouse: bool,
}

impl Storage {
    pub fn resolve(config: Option<&human_config::StorageConfig>) -> Result<Self> {
        let (postgres, clickhouse) = match config {
            // Default: only Postgres enabled
            None => (true, false),
            Some(s) => {
                let clickhouse = s.clickhouse.unwrap_or(false);
                // When clickhouse is enabled, postgres must be set explicitly
                // so that the validation below catches a clickhouse-only config
                // instead of silently defaulting postgres to true.
                let postgres = s.postgres.unwrap_or(!clickhouse);
                (postgres, clickhouse)
            }
        };
        if clickhouse && !postgres {
            return Err(anyhow!(
                "ClickHouse is not supported as a single storage yet. Please enable Postgres \
                 alongside ClickHouse in the `storage` config."
            ));
        }
        if !postgres && !clickhouse {
            return Err(anyhow!(
                "At least one storage backend must be enabled. Please set `postgres: true` \
                 in the `storage` config (or omit the `storage` section entirely to use the \
                 default)."
            ));
        }
        Ok(Self {
            postgres,
            clickhouse,
        })
    }

    pub fn is_multi(&self) -> bool {
        self.postgres && self.clickhouse
    }
}

/// Check per-entity `@storage` directives against the resolved global storage.
/// Malformed directives are raised earlier, during schema parsing.
//
// With two backends, the two failure modes are mutually exclusive: multi-storage
// mode means both backends are on (so an entity can never target a disabled one),
// and single-storage mode is exempt from the must-declare rule. If a third
// backend lands the two checks could fire together — flag that here so a future
// reader sees the simplification's premise.
pub fn validate_entity_storage(storage: &Storage, schema: &Schema) -> anyhow::Result<()> {
    let mut entities: Vec<&Entity> = schema.entities.values().collect();
    entities.sort_by(|a, b| a.name.cmp(&b.name));

    if storage.is_multi() {
        let missing: Vec<&str> = entities
            .iter()
            .filter(|e| !e.has_storage_directive())
            .map(|e| e.name.as_str())
            .collect();
        if missing.is_empty() {
            return Ok(());
        }
        let example = missing[0];
        let listed = missing
            .iter()
            .map(|n| format!("  - {n}"))
            .collect::<Vec<_>>()
            .join("\n");
        return Err(anyhow!(
            "Schema validation failed:\n\
             \n\
             Entities missing the @storage directive (multi-storage mode requires it):\n\
             {listed}\n\
             \n\
             Fixes:\n  \
             - Add @storage(postgres: true) and/or @storage(clickhouse: true) to the entities listed above. Example:\n      \
             type {example} @storage(postgres: true) {{ ... }}\n      \
             type {example} @storage(clickhouse: true) {{ ... }}\n      \
             type {example} @storage(postgres: true, clickhouse: true) {{ ... }}"
        ));
    }

    let unsupported: Vec<(&str, &'static str)> = entities
        .iter()
        .flat_map(|e| {
            let mut out: Vec<(&str, &'static str)> = Vec::new();
            if e.postgres == Some(true) && !storage.postgres {
                out.push((e.name.as_str(), "postgres"));
            }
            if e.clickhouse == Some(true) && !storage.clickhouse {
                out.push((e.name.as_str(), "clickhouse"));
            }
            out
        })
        .collect();
    if unsupported.is_empty() {
        return Ok(());
    }
    let listed = unsupported
        .iter()
        .map(|(name, backend)| {
            format!("  - `{name}` uses `{backend}`, but `{backend}` is not enabled.")
        })
        .collect::<Vec<_>>()
        .join("\n");
    Err(anyhow!(
        "Schema validation failed:\n\
         \n\
         Entities using storages not enabled in config.yaml:\n\
         {listed}\n\
         \n\
         Fixes:\n  \
         - Remove the unsupported storage from @storage on these entities, or enable it under `storage:` in config.yaml."
    ))
}

//Getter methods for system config
impl SystemConfig {
    pub fn get_contracts(&self) -> Vec<&Contract> {
        let mut contracts: Vec<&Contract> = self.contracts.values().collect();
        contracts.sort_by_key(|c| c.name.clone());
        contracts
    }

    pub fn get_ecosystem(&self) -> Ecosystem {
        match &self.human_config {
            HumanConfig::Evm(_) => Ecosystem::Evm,
            HumanConfig::Fuel(_) => Ecosystem::Fuel,
            HumanConfig::Svm(_) => Ecosystem::Svm,
        }
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

    pub fn get_chains(&self) -> Vec<&Chain> {
        let mut chains: Vec<&Chain> = self.chains.values().collect();
        chains.sort_by_key(|n| n.id);
        chains
    }

    pub fn get_path_to_schema(&self) -> Result<PathBuf> {
        let schema_path = path_utils::get_config_path_relative_to_root(
            &self.parsed_project_paths,
            PathBuf::from(&self.schema_path),
        )
        .context("Failed creating a relative path to schema")?;

        Ok(schema_path)
    }

    pub fn get_all_paths_to_abi_files(&self) -> Result<Vec<PathBuf>> {
        let mut filtered_unique_abi_files = self
            .get_contracts()
            .into_iter()
            .filter_map(|c| c.abi.get_path())
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();

        filtered_unique_abi_files.sort();
        Ok(filtered_unique_abi_files)
    }

    pub fn from_human_config(
        human_config: HumanConfig,
        schema: Schema,
        project_paths: &ParsedProjectPaths,
    ) -> Result<Self> {
        let mut chains: ChainMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        let base_config = human_config.get_base_config();
        let storage = Storage::resolve(base_config.storage.as_ref())?;
        validate_entity_storage(&storage, &schema)?;

        let final_project_paths = project_paths.clone();

        let is_rescript = final_project_paths
            .project_root
            .join("rescript.json")
            .exists();

        match human_config {
            HumanConfig::Evm(ref evm_config) => {
                // TODO: Add similar validation for Fuel
                validation::validate_deserialized_config_yaml(evm_config)?;

                let has_rpc_sync_src = evm_config.chains.iter().any(|n| {
                    let default_for = default_rpc_for(n);
                    let is_sync = |source_for: &Option<For>| {
                        matches!(source_for.as_ref().unwrap_or(&default_for), For::Sync)
                    };
                    match &n.rpc {
                        Some(RpcSelection::Single(rpc)) => is_sync(&rpc.source_for),
                        Some(RpcSelection::List(rpcs)) => {
                            rpcs.iter().any(|r| is_sync(&r.source_for))
                        }
                        Some(RpcSelection::Url(_)) => default_for == For::Sync,
                        None => false,
                    }
                });

                //Add all global contracts
                if let Some(global_contracts) = &evm_config.contracts {
                    for g_contract in global_contracts {
                        let (events, evm_abi) = Event::from_evm_events_config(
                            g_contract.config.events.clone(),
                            &g_contract.config.abi_file_path,
                            &final_project_paths,
                            has_rpc_sync_src,
                        )
                        .context(format!(
                            "Failed parsing abi types for events in global contract {}",
                            g_contract.name,
                        ))?;

                        let contract = Contract::new(
                            g_contract.name.clone(),
                            g_contract.config.handler.clone(),
                            events,
                            Abi::Evm(evm_abi),
                        )
                        .context("Failed parsing globally defined contract")?;

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context("Failed inserting globally defined contract")?;
                    }
                }

                for network in &evm_config.chains {
                    for contract in network.contracts.clone().unwrap_or_default() {
                        //Add values for local contract
                        match contract.config {
                            Some(l_contract) => {
                                let (events, evm_abi) = Event::from_evm_events_config(
                                    l_contract.events,
                                    &l_contract.abi_file_path,
                                    &final_project_paths,
                                    has_rpc_sync_src,
                                )
                                .context(format!(
                                    "Failed parsing abi types for events in contract {} on \
                                     network {}",
                                    contract.name, network.id,
                                ))?;

                                let contract = Contract::new(
                                    contract.name,
                                    l_contract.handler,
                                    events,
                                    Abi::Evm(evm_abi),
                                )
                                .context(format!(
                                    "Failed parsing locally defined network contract at network \
                                     id {}",
                                    network.id
                                ))?;

                                //Check if contract exists
                                unique_hashmap::try_insert(
                                    &mut contracts,
                                    contract.name.clone(),
                                    contract,
                                )
                                .context(format!(
                                    "Failed inserting locally defined network contract at network \
                                     id {}",
                                    network.id,
                                ))?;
                            }
                            None => {
                                //Validate that there is a global contract for the given contract if
                                //there is no config
                                if !contracts.contains_key(&contract.name) {
                                    Err(anyhow!(
                                        "Failed to parse contract '{}' for the network '{}'. If \
                                         you use a global contract definition, please verify that \
                                         the name reference is correct.",
                                        contract.name,
                                        network.id
                                    ))?;
                                }
                            }
                        }
                    }

                    let sync_source = DataSource::from_evm_network_config(network.clone())?;

                    let contracts: Vec<ChainContract> = network
                        .contracts
                        .as_ref()
                        .unwrap_or(&vec![])
                        .iter()
                        .cloned()
                        .map(|c| ChainContract {
                            name: c.name,
                            addresses: c.address.into(),
                            start_block: c.start_block,
                        })
                        .collect();

                    let chain = Chain {
                        id: network.id,
                        skip: network.skip.unwrap_or(false),
                        max_reorg_depth: network
                            .max_reorg_depth
                            .or_else(|| get_max_reorg_depth_from_id(network.id)),
                        block_lag: network.block_lag,
                        start_block: network.start_block,
                        end_block: network.end_block,
                        sync_source,
                        contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, chain.id, chain)
                        .context("Failed inserting chain at chains map")?;
                }

                let field_selection = FieldSelection::try_from_config_field_selection(
                    evm_config.field_selection.clone().unwrap_or(
                        human_config::evm::FieldSelection {
                            transaction_fields: None,
                            block_fields: None,
                        },
                    ),
                    has_rpc_sync_src,
                )?;

                Ok(SystemConfig {
                    name: base_config.name.clone(),
                    parsed_project_paths: final_project_paths,
                    schema_path: base_config
                        .schema
                        .clone()
                        .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
                    chains,
                    contracts,
                    rollback_on_reorg: evm_config.rollback_on_reorg.unwrap_or(true),
                    save_full_history: evm_config.save_full_history.unwrap_or(false),
                    schema,
                    field_selection,
                    enable_raw_events: evm_config.raw_events.unwrap_or(false),
                    storage,
                    lowercase_addresses: matches!(
                        evm_config.address_format,
                        Some(super::human_config::evm::AddressFormat::Lowercase)
                    ),
                    handlers: base_config.handlers.clone(),
                    human_config,
                    is_rescript,
                })
            }
            HumanConfig::Fuel(ref fuel_config) => {
                //Add all global contracts
                if let Some(global_contracts) = &fuel_config.contracts {
                    for g_contract in global_contracts {
                        let (events, fuel_abi) = Event::from_fuel_events_config(
                            &g_contract.config.events,
                            &g_contract.config.abi_file_path,
                            &final_project_paths,
                        )
                        .context(format!(
                            "Failed parsing abi types for events in global contract {}",
                            g_contract.name,
                        ))?;

                        let contract = Contract::new(
                            g_contract.name.clone(),
                            g_contract.config.handler.clone(),
                            events,
                            Abi::fuel(fuel_abi),
                        )?;

                        //Check if contract exists
                        unique_hashmap::try_insert(&mut contracts, contract.name.clone(), contract)
                            .context("Failed inserting globally defined contract")?;
                    }
                }

                for network in &fuel_config.chains {
                    for contract in network.contracts.clone().unwrap_or_default() {
                        //Add values for local contract
                        match contract.config {
                            Some(l_contract) => {
                                let (events, fuel_abi) = Event::from_fuel_events_config(
                                    &l_contract.events,
                                    &l_contract.abi_file_path,
                                    &final_project_paths,
                                )
                                .context(format!(
                                    "Failed parsing abi types for events in contract {} on \
                                     network {}",
                                    contract.name, network.id,
                                ))?;

                                let contract = Contract::new(
                                    contract.name.clone(),
                                    l_contract.handler,
                                    events,
                                    Abi::fuel(fuel_abi),
                                )?;

                                //Check if contract exists
                                unique_hashmap::try_insert(
                                    &mut contracts,
                                    contract.name.clone(),
                                    contract,
                                )
                                .context(format!(
                                    "Failed inserting locally defined network contract at network \
                                     id {}",
                                    network.id,
                                ))?;
                            }
                            None => {
                                //Validate that there is a global contract for the given contract if
                                //there is no local_contract_config
                                if !contracts.contains_key(&contract.name) {
                                    Err(anyhow!(
                                        "Failed to parse contract '{}' for the network '{}'. If \
                                         you use a global contract definition, please verify that \
                                         the name reference is correct.",
                                        contract.name,
                                        network.id
                                    ))?;
                                }
                            }
                        }
                    }

                    let sync_source = DataSource::Fuel {
                        hypersync_endpoint_url: match &network.hyperfuel_config {
                            Some(config) => config.url.clone(),
                            None => match network.id {
                                0 => "https://fuel-testnet.hypersync.xyz".to_string(),
                                9889 => "https://fuel.hypersync.xyz".to_string(),
                                _ => {
                                    return Err(anyhow!(
                                        "Fuel network id {} is not supported",
                                        network.id
                                    ))
                                }
                            },
                        },
                    };

                    let contracts: Vec<ChainContract> = network
                        .contracts
                        .as_ref()
                        .unwrap_or(&vec![])
                        .iter()
                        .cloned()
                        .map(|c| ChainContract {
                            name: c.name,
                            addresses: c.address.into(),
                            start_block: c.start_block,
                        })
                        .collect();

                    let chain = Chain {
                        id: network.id,
                        skip: network.skip.unwrap_or(false),
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: network.max_reorg_depth,
                        block_lag: network.block_lag,
                        sync_source,
                        contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, chain.id, chain)
                        .context("Failed inserting chain at chains map")?;
                }

                Ok(SystemConfig {
                    name: base_config.name.clone(),
                    parsed_project_paths: final_project_paths,
                    schema_path: base_config
                        .schema
                        .clone()
                        .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
                    chains,
                    contracts,
                    rollback_on_reorg: false,
                    save_full_history: false,
                    schema,
                    field_selection: FieldSelection::fuel(),
                    enable_raw_events: fuel_config.raw_events.unwrap_or(false),
                    storage,
                    lowercase_addresses: false,
                    handlers: base_config.handlers.clone(),
                    human_config,
                    is_rescript,
                })
            }
            HumanConfig::Svm(ref svm_config) => {
                validation::validate_deserialized_svm_config_yaml(svm_config)?;
                for network in &svm_config.chains {
                    let sync_source = DataSource::Svm {
                        rpc: network.rpc.clone(),
                        hypersync_endpoint_url: network
                            .hypersync_config
                            .as_ref()
                            .map(|h| h.url.clone()),
                    };

                    let mut chain_contracts = Vec::new();
                    for program in network.programs.as_deref().unwrap_or(&[]) {
                        let svm_abi = resolve_program_schema(program, project_paths)
                            .with_context(|| {
                                format!(
                                    "Resolving Borsh schema for program '{}' ({})",
                                    program.name, program.program_id
                                )
                            })?;
                        let program_schema = lookup_program_schema(&svm_abi);

                        let events = program
                            .instructions
                            .iter()
                            .map(|instr| -> Result<Event> {
                                let (normalized_discriminator, byte_len) =
                                    match &instr.discriminator {
                                        Some(d) => {
                                            let hex = d.strip_prefix("0x").unwrap_or(d);
                                            let byte_len = (hex.len() / 2) as u8;
                                            (Some(format!("0x{hex}")), byte_len)
                                        }
                                        None => (None, 0u8),
                                    };
                                let (accounts, args) = resolve_instruction_layout(
                                    program,
                                    instr,
                                    program_schema,
                                    &svm_abi.source,
                                )
                                .with_context(|| {
                                    format!("Layout for instruction '{}'", instr.name)
                                })?;
                                let fs = instr.field_selection.as_ref();
                                let include_token_balances = fs
                                    .and_then(|f| f.token_balance_fields.as_ref())
                                    .map_or(false, |v| v.is_enabled());
                                let include_transaction = fs
                                    .and_then(|f| f.transaction_fields.as_ref())
                                    .map_or(false, |v| v.is_enabled())
                                    || include_token_balances;
                                let include_logs = fs
                                    .and_then(|f| f.log_fields.as_ref())
                                    .map_or(false, |v| v.is_enabled());
                                let svm_kind = SvmEventKind {
                                    discriminator: normalized_discriminator.clone(),
                                    discriminator_byte_len: byte_len,
                                    include_token_balances,
                                    include_transaction,
                                    include_logs,
                                    account_filters: instr
                                        .account_filters
                                        .as_ref()
                                        .map(|filters| {
                                            filters
                                                .groups()
                                                .into_iter()
                                                .map(|group| {
                                                    group
                                                        .iter()
                                                        .map(|af| SvmAccountFilter {
                                                            position: af.position,
                                                            values: af.values.clone(),
                                                        })
                                                        .collect()
                                                })
                                                .collect()
                                        })
                                        .unwrap_or_default(),
                                    is_inner: instr.is_inner,
                                    accounts,
                                    args,
                                };
                                Ok(Event {
                                    name: instr.name.clone(),
                                    kind: EventKind::Svm(svm_kind),
                                    sighash: normalized_discriminator.clone().unwrap_or_default(),
                                    event_signature: String::new(),
                                    field_selection: None,
                                })
                            })
                            .collect::<Result<Vec<_>>>()?;

                        let contract = Contract::new(
                            program.name.clone(),
                            program.handler.clone(),
                            events,
                            Abi::Svm(svm_abi),
                        )?;
                        contracts.insert(contract.name.clone(), contract.clone());
                        chain_contracts.push(ChainContract {
                            name: program.name.clone(),
                            addresses: vec![program.program_id.clone()],
                            start_block: None,
                        });
                    }

                    let chain = Chain {
                        id: 0, //network.id,
                        skip: network.skip.unwrap_or(false),
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: None,
                        block_lag: network.block_lag,
                        sync_source,
                        contracts: chain_contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, chain.id, chain)
                        .context("Failed inserting chain at chains map")?;
                }

                Ok(SystemConfig {
                    name: svm_config.base.name.clone(),
                    parsed_project_paths: final_project_paths,
                    schema_path: svm_config
                        .base
                        .schema
                        .clone()
                        .unwrap_or_else(|| DEFAULT_SCHEMA_PATH.to_string()),
                    chains,
                    contracts,
                    rollback_on_reorg: false,
                    save_full_history: false,
                    schema,
                    field_selection: FieldSelection::fuel(),
                    enable_raw_events: false,
                    storage,
                    lowercase_addresses: false,
                    handlers: None,
                    human_config,
                    is_rescript,
                })
            }
        }
    }

    pub fn parse_from_project_files(project_paths: &ParsedProjectPaths) -> Result<Self> {
        let human_config_string =
            std::fs::read_to_string(&project_paths.config).context(format!(
                "Failed to resolve config path {0}. Make sure you're in the correct \
                 directory and that a config file with the name {0} exists. I can configure \
                 another path by using the --config flag.",
                &project_paths.config.to_str().unwrap_or("{unknown}"),
            ))?;

        let mut env_state = EnvState::new(&project_paths.project_root);
        let human_config_string =
            interpolation::interpolate_config_variables(human_config_string, |name| {
                env_state.var(name)
            })?;

        let config_discriminant: human_config::ConfigDiscriminant =
            serde_yaml::from_str(&human_config_string).context(
                "Failed to deserialize config. The config.yaml file is either not a valid \
                 yaml or the \"ecosystem\" field is not a string.",
            )?;

        let ecosystem = match config_discriminant.ecosystem.as_deref() {
            Some("evm") => Ecosystem::Evm,
            Some("fuel") => Ecosystem::Fuel,
            Some("svm") => Ecosystem::Svm,
            Some(ecosystem) => {
                return Err(anyhow!(
                    "Failed to deserialize config. The ecosystem \"{}\" is not supported.",
                    ecosystem
                ))
            }
            None => Ecosystem::Evm,
        };

        match ecosystem {
            Ecosystem::Evm => {
                let evm_config: EvmConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "Failed to deserialize config. Visit the docs for more information \
                         {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?;
                let schema = Schema::parse_from_file(project_paths, &evm_config.base.schema)
                    .context("Parsing schema file for config")?;
                Self::from_human_config(HumanConfig::Evm(evm_config), schema, project_paths)
            }
            Ecosystem::Fuel => {
                let fuel_config: FuelConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "Failed to deserialize config. Visit the docs for more information \
                         {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?;
                let schema = Schema::parse_from_file(project_paths, &fuel_config.base.schema)
                    .context("Parsing schema file for config")?;
                Self::from_human_config(HumanConfig::Fuel(fuel_config), schema, project_paths)
            }
            Ecosystem::Svm => {
                let svm_config: human_config::svm::HumanConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "Failed to deserialize config. Visit the docs for more information \
                         {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?;
                let schema = Schema::parse_from_file(project_paths, &svm_config.base.schema)
                    .context("Parsing schema file for config")?;
                Self::from_human_config(HumanConfig::Svm(svm_config), schema, project_paths)
            }
        }
    }
}

type ServerUrl = String;

/// This data structure mainly needed to conviniently prepare data
/// for ConfigYAML, so we don't break backward compatibility
#[derive(Debug, Clone, PartialEq)]
pub enum MainEvmDataSource {
    HyperSync { hypersync_endpoint_url: ServerUrl },
    Rpc(Rpc),
}

#[derive(Debug, Clone, PartialEq)]
pub enum DataSource {
    Evm {
        main: MainEvmDataSource,
        rpcs: Vec<Rpc>,
    },
    Fuel {
        hypersync_endpoint_url: ServerUrl,
    },
    Svm {
        rpc: ServerUrl,
        hypersync_endpoint_url: Option<ServerUrl>,
    },
}

// Check if the given URL is valid in terms of formatting
fn parse_url(url: &str) -> Option<String> {
    // Check URL format
    if !url.starts_with("http://") && !url.starts_with("https://") {
        return None;
    }
    // Trim any trailing slashes from the URL
    let trimmed_url = url.trim_end_matches('/').to_string();
    Some(trimmed_url)
}

/// Returns the default `For` value for an RPC on a chain:
/// `Fallback` if HyperSync is available, `Sync` otherwise.
fn default_rpc_for(chain: &EvmChain) -> For {
    let has_hypersync = chain.hypersync_config.is_some()
        || hypersync_endpoints::get_default_hypersync_endpoint(chain.id).is_ok();
    if has_hypersync {
        For::Fallback
    } else {
        For::Sync
    }
}

impl DataSource {
    fn from_evm_network_config(network: EvmChain) -> Result<Self> {
        let default_for = default_rpc_for(&network);
        let hypersync_endpoint_url = match &network.hypersync_config {
            Some(config) => Some(config.url.to_string()),
            None => hypersync_endpoints::get_default_hypersync_endpoint(network.id).ok(),
        };
        let resolve_for = |rpc: Rpc| Rpc {
            source_for: Some(rpc.source_for.unwrap_or(default_for.clone())),
            ..rpc
        };
        let raw_rpcs = match network.rpc {
            Some(RpcSelection::Url(url)) => vec![Rpc {
                url: url.to_string(),
                source_for: Some(default_for.clone()),
                ws: None,
                initial_block_interval: None,
                backoff_multiplicative: None,
                acceleration_additive: None,
                interval_ceiling: None,
                backoff_millis: None,
                fallback_stall_timeout: None,
                query_timeout_millis: None,
                polling_interval: None,
            }],
            Some(RpcSelection::Single(rpc)) => vec![resolve_for(rpc)],
            Some(RpcSelection::List(list)) => list.into_iter().map(resolve_for).collect(),
            None => vec![],
        };

        let mut rpcs = vec![];
        for rpc in raw_rpcs.iter() {
            match parse_url(rpc.url.as_str()) {
              None => return Err(anyhow!("The RPC url \"{}\" is incorrect format. The RPC url needs to start with either http:// or https://", rpc.url)),
              Some(url) => {
                // Validate ws URL protocol if provided
                let ws = match &rpc.ws {
                    Some(ws_url) => {
                        if ws_url.starts_with("wss://") || ws_url.starts_with("ws://") {
                            Some(ws_url.trim_end_matches('/').to_string())
                        } else {
                            return Err(anyhow!(
                                "The WebSocket URL \"{}\" is in incorrect format. \
                                 Expected wss:// or ws:// protocol.",
                                ws_url
                            ));
                        }
                    }
                    None => None,
                };
                rpcs.push(Rpc {
                    url,
                    ws,
                    ..rpc.clone()
                })
              }
            }
        }

        let rpc_for_sync = rpcs.iter().find(|rpc| rpc.source_for == Some(For::Sync));

        let main = match rpc_for_sync {
            Some(rpc) => {
                if network.hypersync_config.is_some() {
                    Err(anyhow!(
                        "Cannot define both hypersync_config and rpc as a data-source for \
                         historical sync at the same time, please choose only one option or set \
                         RPC to be a fallback. Read more in our docs {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?
                };

                MainEvmDataSource::Rpc(rpc.clone())
            }
            None => {
                let url = hypersync_endpoint_url.ok_or(anyhow!(
                    "Failed to automatically find HyperSync endpoint for the chain {chain_id}. \
                     If the chain is supported by HyperSync, provide the endpoint manually:\n\n\
                     chains:\n  - id: {chain_id}\n    hypersync_config:\n      \
                     url: https://{chain_id}.hypersync.xyz\n\n\
                     Or use an RPC endpoint for historical sync:\n\n\
                     chains:\n  - id: {chain_id}\n    rpc:\n      \
                     url: https://your-rpc-endpoint\n      for: sync\n\n\
                     Read more: {docs_url}",
                    chain_id = network.id,
                    docs_url = links::DOC_CONFIGURATION_SCHEMA_HYPERSYNC_CONFIG
                ))?;

                let parsed_url = parse_url(&url).ok_or(anyhow!(
                  "The HyperSync URL \"{}\" is in incorrect format. The URL needs to start with either http:// or https://",
                  url
                ))?;

                MainEvmDataSource::HyperSync {
                    hypersync_endpoint_url: parsed_url,
                }
            }
        };

        Ok(Self::Evm { main, rpcs })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Chain {
    pub id: u64,
    pub skip: bool,
    pub sync_source: DataSource,
    pub start_block: u64,
    pub end_block: Option<u64>,
    pub max_reorg_depth: Option<u32>,
    pub block_lag: Option<u32>,
    pub contracts: Vec<ChainContract>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ChainContract {
    pub name: ContractNameKey,
    pub addresses: Vec<String>,
    pub start_block: Option<u64>,
}

impl ChainContract {
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
    typed: JsonAbi,
}

impl EvmAbi {
    pub fn event_signature_from_abi_event(abi_event: &AlloyEvent) -> String {
        format!(
            "{}({}){}",
            abi_event.name,
            abi_event
                .inputs
                .iter()
                .map(|input| {
                    let param_type = input.selector_type();
                    let indexed_keyword = if input.indexed { " indexed " } else { " " };
                    let param_name = &input.name;

                    format!("{}{}{}", param_type, indexed_keyword, param_name)
                })
                .collect::<Vec<_>>()
                .join(", "),
            if abi_event.anonymous {
                " anonymous"
            } else {
                ""
            },
        )
    }

    pub fn get_event_signatures(&self) -> Vec<String> {
        self.typed
            .events()
            .map(Self::event_signature_from_abi_event)
            .collect()
    }

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
                let mut raw = fs::read_to_string(&path)
                    .context(format!("Failed to read ABI file at \"{}\"", abi_file_path))?;

                // Abi files generated by the hardhat plugin can contain a nested abi field. This code to support that.
                let typed = match serde_json::from_str::<AbiOrNestedAbi>(&raw).context(format!(
                    "Failed to decode ABI file at \"{}\"",
                    abi_file_path
                ))? {
                    AbiOrNestedAbi::Abi(abi) => abi,
                    AbiOrNestedAbi::NestedAbi { abi } => {
                        raw = serde_json::to_string(&abi)
                            .context("Failed serializing ABI from nested field")?;
                        abi
                    }
                };
                Ok(Some(Self {
                    path: Some(path),
                    raw,
                    typed,
                }))
            }
        }
    }
}

/// Base58 program id for the bundled Metaplex Token Metadata schema. Kept
/// here (rather than imported from the upstream crate) so a future bundled
/// schema can be added by appending a row to the `bundled_program_schemas`
/// table without leaking strings across the module boundary.
const METAPLEX_TOKEN_METADATA_PROGRAM_ID: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

/// One row in the bundled-programs table: `(program_id, source_name,
/// accessor returning the upstream `ProgramSchema`)`.
type BundledProgramRow = (
    &'static str,
    &'static str,
    fn() -> &'static SvmProgramSchema,
);

/// Table of bundled programs. Lookup by base58 `program_id`. To add a
/// program: ship a `ProgramSchema` constant in `hypersync_client_solana`,
/// expose a public accessor, then add a row here.
fn bundled_program_schemas() -> Vec<BundledProgramRow> {
    vec![(
        METAPLEX_TOKEN_METADATA_PROGRAM_ID,
        "metaplex_token_metadata",
        metaplex_token_metadata,
    )]
}

fn resolve_program_schema(
    program: &human_config::svm::Program,
    project_paths: &ParsedProjectPaths,
) -> Result<SvmAbi> {
    let any_instruction_carries_schema = program
        .instructions
        .iter()
        .any(|i| i.accounts.is_some() || i.args.is_some());

    if let Some(idl_path) = program.idl.as_deref() {
        if any_instruction_carries_schema {
            return Err(anyhow!(
                "Program '{}': `idl` is mutually exclusive with per-instruction \
                 `accounts`/`args` overrides. Use one or the other.",
                program.name
            ));
        }
        let abs = project_paths.project_root.join(idl_path);
        let body = fs::read_to_string(&abs)
            .with_context(|| format!("reading IDL at '{}'", abs.display()))?;
        let schema = schema_from_anchor_idl_json(&body)
            .with_context(|| format!("parsing IDL at '{}'", abs.display()))?;
        return Ok(SvmAbi {
            program_id: program.program_id.clone(),
            defined_types: schema.defined_types,
            source: SvmSchemaSource::AnchorIdl {
                path: idl_path.to_string(),
            },
        });
    }

    if !any_instruction_carries_schema {
        if let Some((_, name, getter)) = bundled_program_schemas()
            .into_iter()
            .find(|(pid, _, _)| *pid == program.program_id.as_str())
        {
            let schema = getter();
            return Ok(SvmAbi {
                program_id: program.program_id.clone(),
                defined_types: schema.defined_types.clone(),
                source: SvmSchemaSource::Bundled { name },
            });
        }
    }

    Ok(SvmAbi {
        program_id: program.program_id.clone(),
        defined_types: BTreeMap::new(),
        source: SvmSchemaSource::Inline,
    })
}

fn lookup_program_schema(abi: &SvmAbi) -> Option<&'static SvmProgramSchema> {
    match abi.source {
        SvmSchemaSource::Bundled { .. } => bundled_program_schemas()
            .into_iter()
            .find(|(pid, _, _)| *pid == abi.program_id.as_str())
            .map(|(_, _, getter)| getter()),
        _ => None,
    }
}

/// Resolve per-instruction `(accounts, args)` from one of:
/// 1. YAML per-instruction `accounts`/`args` overrides (highest priority).
/// 2. The matching `InstructionSchema` on a bundled `ProgramSchema`, keyed
///    by the YAML `discriminator` bytes.
/// 3. An empty pair (`accounts: []`, `args: []`) so existing untyped
///    handlers keep working.
fn resolve_instruction_layout(
    _program: &human_config::svm::Program,
    instr: &human_config::svm::Instruction,
    program_schema: Option<&SvmProgramSchema>,
    source: &SvmSchemaSource,
) -> Result<(Vec<String>, Vec<SvmNamedField>)> {
    if let (Some(accounts_yaml), Some(args_yaml)) = (&instr.accounts, &instr.args) {
        let args = args_yaml
            .iter()
            .map(yaml_arg_to_named_field)
            .collect::<Result<Vec<_>>>()?;
        return Ok((accounts_yaml.clone(), args));
    }
    if instr.accounts.is_some() != instr.args.is_some() {
        return Err(anyhow!(
            "Instruction '{}': `accounts` and `args` must be provided together \
             (or both omitted to fall back to a bundled/IDL schema).",
            instr.name
        ));
    }

    if let (Some(schema), SvmSchemaSource::Bundled { .. } | SvmSchemaSource::AnchorIdl { .. }) =
        (program_schema, source)
    {
        if let Some(disc_bytes) = disc_to_bytes(instr.discriminator.as_deref())? {
            if let Some(ix_schema) = schema.instructions.get(&disc_bytes) {
                let accounts = ix_schema.accounts.iter().map(|a| a.name.clone()).collect();
                let args = ix_schema.args.clone();
                return Ok((accounts, args));
            }
        }
    }

    Ok((Vec::new(), Vec::new()))
}

fn disc_to_bytes(disc: Option<&str>) -> Result<Option<Vec<u8>>> {
    let Some(s) = disc else { return Ok(None) };
    let hex = s.strip_prefix("0x").unwrap_or(s);
    let bytes = (0..hex.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&hex[i..i + 2], 16)
                .with_context(|| format!("invalid hex byte at offset {i} in discriminator '{s}'"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(Some(bytes))
}

fn yaml_arg_to_named_field(arg: &human_config::svm::ArgDef) -> Result<SvmNamedField> {
    Ok(SvmNamedField {
        name: arg.name.clone(),
        ty: yaml_type_to_field_type(&arg.ty)
            .with_context(|| format!("translating type for arg '{}'", arg.name))?,
    })
}

/// Convert an upstream `FieldType` into the YAML/wire-format `ArgType`. Used
/// when serializing `SvmEventKind.args` / `SvmAbi.defined_types` into
/// `internal_config.json` for the runtime to consume.
pub fn field_type_to_arg_type(ty: &SvmFieldType) -> human_config::svm::ArgType {
    use human_config::svm::{ArgComposite as C, ArgPrimitive as P, ArgType as T};
    match ty {
        SvmFieldType::Bool => T::Primitive(P::Bool),
        SvmFieldType::U8 => T::Primitive(P::U8),
        SvmFieldType::U16 => T::Primitive(P::U16),
        SvmFieldType::U32 => T::Primitive(P::U32),
        SvmFieldType::U64 => T::Primitive(P::U64),
        SvmFieldType::U128 => T::Primitive(P::U128),
        SvmFieldType::I8 => T::Primitive(P::I8),
        SvmFieldType::I16 => T::Primitive(P::I16),
        SvmFieldType::I32 => T::Primitive(P::I32),
        SvmFieldType::I64 => T::Primitive(P::I64),
        SvmFieldType::I128 => T::Primitive(P::I128),
        SvmFieldType::F32 => T::Primitive(P::F32),
        SvmFieldType::F64 => T::Primitive(P::F64),
        SvmFieldType::String => T::Primitive(P::String),
        SvmFieldType::Bytes => T::Primitive(P::Bytes),
        SvmFieldType::Pubkey => T::Primitive(P::Pubkey),
        SvmFieldType::Option(inner) => {
            T::Composite(C::Option(Box::new(field_type_to_arg_type(inner))))
        }
        SvmFieldType::Vec(inner) => {
            T::Composite(C::Vec(Box::new(field_type_to_arg_type(inner))))
        }
        SvmFieldType::Array { ty, len } => {
            T::Composite(C::Array(Box::new(field_type_to_arg_type(ty)), *len))
        }
        SvmFieldType::Defined(name) => T::Composite(C::Defined(name.clone())),
        SvmFieldType::Struct(fields) => T::Composite(C::Struct(
            fields.iter().map(named_field_to_arg_def).collect(),
        )),
        SvmFieldType::Enum(variants) => T::Composite(C::Enum(
            variants
                .iter()
                .map(|v| human_config::svm::ArgEnumVariant {
                    name: v.name.clone(),
                    fields: v
                        .fields
                        .as_ref()
                        .map(|fs| fs.iter().map(named_field_to_arg_def).collect()),
                })
                .collect(),
        )),
    }
}

pub fn named_field_to_arg_def(nf: &SvmNamedField) -> human_config::svm::ArgDef {
    human_config::svm::ArgDef {
        name: nf.name.clone(),
        ty: field_type_to_arg_type(&nf.ty),
    }
}

fn yaml_type_to_field_type(ty: &human_config::svm::ArgType) -> Result<SvmFieldType> {
    use human_config::svm::{ArgComposite as C, ArgPrimitive as P, ArgType as T};
    Ok(match ty {
        T::Primitive(p) => match p {
            P::Bool => SvmFieldType::Bool,
            P::U8 => SvmFieldType::U8,
            P::U16 => SvmFieldType::U16,
            P::U32 => SvmFieldType::U32,
            P::U64 => SvmFieldType::U64,
            P::U128 => SvmFieldType::U128,
            P::I8 => SvmFieldType::I8,
            P::I16 => SvmFieldType::I16,
            P::I32 => SvmFieldType::I32,
            P::I64 => SvmFieldType::I64,
            P::I128 => SvmFieldType::I128,
            P::F32 => SvmFieldType::F32,
            P::F64 => SvmFieldType::F64,
            P::String => SvmFieldType::String,
            P::Bytes => SvmFieldType::Bytes,
            P::Pubkey | P::PublicKey => SvmFieldType::Pubkey,
        },
        T::Composite(c) => match c {
            C::Option(inner) => SvmFieldType::Option(Box::new(yaml_type_to_field_type(inner)?)),
            C::Vec(inner) => SvmFieldType::Vec(Box::new(yaml_type_to_field_type(inner)?)),
            C::Array(inner, len) => SvmFieldType::Array {
                ty: Box::new(yaml_type_to_field_type(inner)?),
                len: *len,
            },
            C::Defined(name) => SvmFieldType::Defined(name.clone()),
            C::Struct(fields) => SvmFieldType::Struct(
                fields
                    .iter()
                    .map(yaml_arg_to_named_field)
                    .collect::<Result<_>>()?,
            ),
            C::Enum(variants) => SvmFieldType::Enum(
                variants
                    .iter()
                    .map(|v| {
                        let fields = v
                            .fields
                            .as_ref()
                            .map(|fs| {
                                fs.iter()
                                    .map(yaml_arg_to_named_field)
                                    .collect::<Result<_>>()
                            })
                            .transpose()?;
                        Ok(SvmEnumVariant {
                            name: v.name.clone(),
                            fields,
                        })
                    })
                    .collect::<Result<_>>()?,
            ),
        },
    })
}

// Suppress unused warnings on imports only referenced via paths above when
// the enum-variant constructor isn't reached at compile time.
#[allow(dead_code)]
const _UNUSED_ENUM_VARIANT: Option<SvmEnumVariant> = None;

#[derive(Debug, Clone, PartialEq)]
pub enum Abi {
    Evm(EvmAbi),
    Fuel(Box<FuelAbi>),
    /// Solana programs ship no on-chain ABI artifact. The `SvmAbi` payload
    /// holds the program-level Borsh schema (defined-types registry, source
    /// origin) shared across all of the program's instructions. The
    /// per-instruction Borsh layout lives on each `SvmEventKind`.
    Svm(SvmAbi),
}

#[derive(Debug, Clone, PartialEq)]
pub struct SvmAbi {
    /// Base58 program id this schema describes.
    pub program_id: String,
    /// Nominal-type registry referenced by `SvmFieldType::Defined`. Populated
    /// from an Anchor IDL's `types:` block, the bundled-schema registry, or
    /// empty for hand-written ad-hoc schemas.
    pub defined_types: BTreeMap<String, SvmFieldType>,
    pub source: SvmSchemaSource,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SvmSchemaSource {
    /// User-supplied `idl: <path>` parsed at codegen time.
    AnchorIdl { path: String },
    /// `program_id` matched a bundled `ProgramSchema` (e.g. Metaplex).
    Bundled { name: &'static str },
    /// Hand-written per-instruction `accounts`/`args` in YAML.
    Inline,
}

impl Abi {
    fn get_path(&self) -> Option<PathBuf> {
        match self {
            Abi::Evm(abi) => abi.path.clone(),
            Abi::Fuel(abi) => Some(abi.path_buf.clone()),
            Abi::Svm(_) => None,
        }
    }

    fn fuel(fuel_abi: FuelAbi) -> Self {
        Abi::Fuel(Box::new(fuel_abi))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Contract {
    pub name: ContractNameKey,
    pub handler_path: Option<String>,
    pub abi: Abi,
    pub events: Vec<Event>,
}

impl Contract {
    pub fn new(
        name: String,
        handler_path: Option<String>,
        events: Vec<Event>,
        abi: Abi,
    ) -> Result<Self> {
        // TODO: Validatate that all event names are unique
        validate_names_valid_rescript(
            &events.iter().map(|e| e.name.clone()).collect(),
            "event".to_string(),
        )?;

        Ok(Self {
            name,
            events,
            handler_path,
            abi,
        })
    }

    pub fn get_chain_ids(&self, system_config: &SystemConfig) -> Vec<u64> {
        system_config
            .get_chains()
            .iter()
            .filter_map(|network| {
                if network.contracts.iter().any(|c| c.name == self.name) {
                    Some(network.id)
                } else {
                    None
                }
            })
            .collect()
    }
}

#[derive(Debug, PartialEq, Clone)]
pub enum FuelEventKind {
    LogData(TypeIdent),
    Mint,
    Burn,
    Transfer,
    Call,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SvmAccountFilter {
    pub position: u8,
    pub values: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SvmEventKind {
    /// Hex-encoded discriminator (`0x`-prefixed), or `None` to match every
    /// instruction in the program.
    pub discriminator: Option<String>,
    /// Length of the decoded discriminator in bytes (0 / 1 / 2 / 4 / 8). The
    /// router precomputes a per-program ordering on this so dispatch tries
    /// longest first.
    pub discriminator_byte_len: u8,
    pub include_transaction: bool,
    pub include_logs: bool,
    pub include_token_balances: bool,
    /// Disjunctive normal form: outer list is OR of AND-groups, inner list is
    /// AND across positions. An empty outer list means "no account filter".
    pub account_filters: Vec<Vec<SvmAccountFilter>>,
    /// `None` matches both outer and inner (CPI-invoked) instructions.
    pub is_inner: Option<bool>,
    /// Positional account names. Empty when the user supplied no schema and
    /// no bundled/IDL schema applies; in that case `decoded.accounts` is `{}`.
    pub accounts: Vec<String>,
    /// Borsh argument layout in declared order. Empty for unknown
    /// instructions; the raw `instruction.data` is still available.
    pub args: Vec<SvmNamedField>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EventKind {
    Params(Vec<EventParam>),
    Fuel(FuelEventKind),
    Svm(SvmEventKind),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub kind: EventKind,
    pub name: String,
    pub sighash: String,
    /// Full event signature (e.g. "Transfer(address indexed from, address indexed to, uint256 value)")
    /// Only set for EVM events; empty for Fuel events.
    pub event_signature: String,
    pub field_selection: Option<FieldSelection>,
}

impl Event {
    /// Normalize an event signature string to handle common formatting variations:
    /// - Strip trailing semicolons
    /// - Remove spaces before commas (`uint128 ,uint16` -> `uint128,uint16`)
    /// - Collapse multiple spaces into one (`uint128,  uint16` -> `uint128, uint16`)
    fn normalize_event_signature(sig: &str) -> String {
        let sig = sig.trim();
        let sig = sig.strip_suffix(';').unwrap_or(sig).trim_end();

        let mut result = String::with_capacity(sig.len());
        let mut chars = sig.chars().peekable();

        while let Some(ch) = chars.next() {
            if ch == ',' {
                // Remove any trailing spaces before this comma that we already added
                while result.ends_with(' ') {
                    result.pop();
                }
                result.push(',');
                // Skip any whitespace after comma, then add exactly one space
                while chars.peek() == Some(&' ') {
                    chars.next();
                }
                // Add a space after comma if the next char isn't ')' or ']'
                // (to handle cases like trailing commas)
                if chars.peek().is_some()
                    && chars.peek() != Some(&')')
                    && chars.peek() != Some(&']')
                {
                    result.push(' ');
                }
            } else {
                result.push(ch);
            }
        }

        result
    }

    fn get_abi_event(event_string: &str, opt_abi: &Option<EvmAbi>) -> Result<AlloyEvent> {
        let parse_event_sig = |sig: &str| -> Result<AlloyEvent> {
            crate::config_parsing::abi_compat::parse_event_signature_to_alloy(sig).map_err(|err| {
                anyhow!(
                    "Unable to parse event signature {} due to the following error: {}. \
                     Please refer to our docs on how to correctly define a human readable ABI.",
                    sig,
                    err
                )
            })
        };

        let event_string = &Self::normalize_event_signature(event_string);

        if event_string.starts_with("event ") {
            parse_event_sig(event_string)
        } else if event_string.contains('(') {
            let signature = format!("event {}", event_string);
            parse_event_sig(&signature)
        } else {
            match opt_abi {
                Some(abi) => {
                    let events = abi
                        .typed
                        .event(event_string)
                        .context(format!("Failed retrieving event {} from abi", event_string))?;
                    // Return the first event with that name (events can be overloaded)
                    events
                        .first()
                        .cloned()
                        .ok_or_else(|| anyhow!("Event {} not found in abi", event_string))
                }
                None => Err(anyhow!("No abi file provided for event {}", event_string)),
            }
        }
    }

    /// Convert alloy EventParam to our abi_compat EventParam
    fn convert_event_params(alloy_event: &AlloyEvent) -> Result<Vec<EventParam>> {
        alloy_event
            .inputs
            .iter()
            .enumerate()
            .map(|(i, param)| {
                let param_name = param.name.clone();
                let name = if param_name.is_empty() {
                    format!("_{}", i)
                } else {
                    param_name
                };
                EventParam::try_from_alloy(param).map(|mut ep| {
                    ep.name = name;
                    ep
                })
            })
            .collect()
    }

    pub fn from_evm_events_config(
        events_config: Vec<EvmEventConfig>,
        abi_file_path: &Option<String>,
        project_paths: &ParsedProjectPaths,
        has_rpc_sync_src: bool,
    ) -> Result<(Vec<Self>, EvmAbi)> {
        let abi_from_file = EvmAbi::from_file(abi_file_path, project_paths)?;

        let mut events = vec![];
        let mut events_abi = JsonAbi::new();

        for event_config in events_config.iter() {
            let alloy_event = Event::get_abi_event(&event_config.event, &abi_from_file)?;
            // Use alloy's selector() method which computes keccak256 of the signature
            // Note: selector() returns B256 which formats as lowercase hex with 0x prefix
            let sighash = alloy_event.selector().to_string();

            let abi_name = alloy_event.name.clone();
            let name = event_config.name.clone().unwrap_or(abi_name.clone());
            let event_signature = EvmAbi::event_signature_from_abi_event(&alloy_event);

            // Convert alloy params to our abi_compat EventParam
            let normalized_unnamed_params: Vec<EventParam> =
                Event::convert_event_params(&alloy_event)?;

            // Add the event to the ABI (alloy_event is already properly formatted)
            events_abi
                .events
                .entry(abi_name)
                .or_default()
                .push(alloy_event);
            events.push(Event {
                name,
                kind: EventKind::Params(normalized_unnamed_params),
                sighash,
                event_signature,
                field_selection: match event_config.field_selection {
                    Some(ref selection_config) => {
                        Some(FieldSelection::try_from_config_field_selection(
                            selection_config.clone(),
                            has_rpc_sync_src,
                        )?)
                    }
                    None => None,
                },
            })
        }

        let events_abi_raw = serde_json::to_string(&events_abi)
            .context("Failed serializing ABI from filtered events")?;

        Ok((
            events,
            EvmAbi {
                path: match abi_from_file {
                    Some(abi) => abi.path.clone(),
                    None => None,
                },
                raw: events_abi_raw,
                typed: events_abi,
            },
        ))
    }

    pub fn from_fuel_events_config(
        events_config: &[FuelEventConfig],
        abi_file_path: &str,
        project_paths: &ParsedProjectPaths,
    ) -> Result<(Vec<Self>, FuelAbi)> {
        use human_config::fuel::EventType;

        let abi_path: PathBuf = path_utils::get_config_path_relative_to_root(
            project_paths,
            PathBuf::from(&abi_file_path),
        )
        .context("Failed to get path to ABI relative to the root of the project")?;
        let fuel_abi = FuelAbi::parse(abi_path, abi_file_path.to_string())
            .context("Failed to parse ABI".to_string())?;

        let mut events = vec![];

        for event_config in events_config.iter() {
            let event_type = match &event_config.type_ {
                Some(event_type) => event_type.clone(),
                None => {
                    if event_config.log_id.is_some() {
                        EventType::LogData
                    } else {
                        match event_config.name.as_str() {
                            MINT_EVENT_NAME => EventType::Mint,
                            BURN_EVENT_NAME => EventType::Burn,
                            TRANSFER_EVENT_NAME => EventType::Transfer,
                            CALL_EVENT_NAME => EventType::Call,
                            _ => EventType::LogData,
                        }
                    }
                }
            };
            if event_config.log_id.is_some() && event_type != EventType::LogData {
                return Err(anyhow!(
                    "Event '{}' has both 'logId' and '{}' type set. Only one of them can be used \
                     at once.",
                    event_config.name,
                    event_type
                ));
            }
            let event = match event_type {
                EventType::LogData => {
                    let log = match &event_config.log_id {
                        None => {
                            let logged_type = fuel_abi
                                .get_type_by_struct_name(event_config.name.clone())
                                .context(
                                    "Failed to derive the event configuration from the name. Use \
                                     the logId, mint, or burn options to set it explicitly.",
                                )?;
                            fuel_abi.get_log_by_type(logged_type.id)?
                        }
                        Some(log_id) => fuel_abi.get_log(log_id)?,
                    };
                    Event {
                        name: event_config.name.clone(),
                        kind: EventKind::Fuel(FuelEventKind::LogData(log.data_type)),
                        sighash: log.id,
                        event_signature: String::new(),
                        field_selection: None,
                    }
                }
                EventType::Mint => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Mint),
                    sighash: "mint".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
                EventType::Burn => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Burn),
                    sighash: "burn".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
                EventType::Transfer => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Transfer),
                    sighash: "transfer".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
                EventType::Call => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Call),
                    sighash: "call".to_string(),
                    event_signature: String::new(),
                    field_selection: None,
                },
            };

            events.push(event)
        }

        // TODO: Clean up fuel_abi to include only relevant events
        Ok((events, fuel_abi))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SelectedField {
    pub name: String,
    pub data_type: TypeIdent,
}

impl PartialOrd for SelectedField {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for SelectedField {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.name.cmp(&other.name)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct FieldSelection {
    pub transaction_fields: Vec<SelectedField>,
    pub block_fields: Vec<SelectedField>,
}

impl FieldSelection {
    fn new(transaction_fields: Vec<SelectedField>, block_fields: Vec<SelectedField>) -> Self {
        Self {
            transaction_fields,
            block_fields,
        }
    }

    pub fn empty() -> Self {
        Self::new(vec![], vec![])
    }

    pub fn fuel() -> Self {
        Self::new(
            vec![SelectedField {
                name: "id".to_string(),
                data_type: TypeIdent::String,
            }],
            vec![
                SelectedField {
                    name: "id".to_string(),
                    data_type: TypeIdent::String,
                },
                SelectedField {
                    name: "height".to_string(),
                    data_type: TypeIdent::Int,
                },
                SelectedField {
                    name: "time".to_string(),
                    data_type: TypeIdent::Int,
                },
            ],
        )
    }

    /// Returns a FieldSelection containing ALL available EVM block and transaction fields.
    /// Used for generating complete TypeScript types where unselected fields are typed as `never`.
    pub fn all_evm() -> Self {
        use human_config::evm::{BlockField, TransactionField};
        use strum::IntoEnumIterator;

        let block_fields: Vec<SelectedField> = BlockField::iter()
            .map(|field| {
                let data_type = match field {
                    BlockField::ParentHash => TypeIdent::String,
                    BlockField::Nonce => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::Sha3Uncles => TypeIdent::String,
                    BlockField::LogsBloom => TypeIdent::String,
                    BlockField::TransactionsRoot => TypeIdent::String,
                    BlockField::StateRoot => TypeIdent::String,
                    BlockField::ReceiptsRoot => TypeIdent::String,
                    BlockField::Miner => TypeIdent::Address,
                    BlockField::Difficulty => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::TotalDifficulty => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::ExtraData => TypeIdent::String,
                    BlockField::Size => TypeIdent::BigInt,
                    BlockField::GasLimit => TypeIdent::BigInt,
                    BlockField::GasUsed => TypeIdent::BigInt,
                    BlockField::Uncles => TypeIdent::option(TypeIdent::array(TypeIdent::String)),
                    BlockField::BaseFeePerGas => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::BlobGasUsed => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::ExcessBlobGas => TypeIdent::option(TypeIdent::BigInt),
                    BlockField::ParentBeaconBlockRoot => TypeIdent::option(TypeIdent::String),
                    BlockField::WithdrawalsRoot => TypeIdent::option(TypeIdent::String),
                    BlockField::L1BlockNumber => TypeIdent::option(TypeIdent::Int),
                    BlockField::SendCount => TypeIdent::option(TypeIdent::String),
                    BlockField::SendRoot => TypeIdent::option(TypeIdent::String),
                    BlockField::MixHash => TypeIdent::option(TypeIdent::String),
                };
                SelectedField {
                    name: field.to_string(),
                    data_type,
                }
            })
            .collect();

        let transaction_fields: Vec<SelectedField> = TransactionField::iter()
            .map(|field| {
                let data_type = match field {
                    TransactionField::TransactionIndex => TypeIdent::Int,
                    TransactionField::Hash => TypeIdent::String,
                    TransactionField::From => TypeIdent::option(TypeIdent::Address),
                    TransactionField::To => TypeIdent::option(TypeIdent::Address),
                    TransactionField::Gas => TypeIdent::BigInt,
                    TransactionField::GasPrice => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::MaxPriorityFeePerGas => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::MaxFeePerGas => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::CumulativeGasUsed => TypeIdent::BigInt,
                    TransactionField::EffectiveGasPrice => TypeIdent::BigInt,
                    TransactionField::GasUsed => TypeIdent::BigInt,
                    TransactionField::Input => TypeIdent::String,
                    TransactionField::Nonce => TypeIdent::BigInt,
                    TransactionField::Value => TypeIdent::BigInt,
                    TransactionField::V => TypeIdent::option(TypeIdent::String),
                    TransactionField::R => TypeIdent::option(TypeIdent::String),
                    TransactionField::S => TypeIdent::option(TypeIdent::String),
                    TransactionField::ContractAddress => TypeIdent::option(TypeIdent::Address),
                    TransactionField::LogsBloom => TypeIdent::String,
                    TransactionField::Root => TypeIdent::option(TypeIdent::String),
                    TransactionField::Status => TypeIdent::option(TypeIdent::Int),
                    TransactionField::YParity => TypeIdent::option(TypeIdent::String),
                    TransactionField::MaxFeePerBlobGas => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::BlobVersionedHashes => {
                        TypeIdent::option(TypeIdent::array(TypeIdent::String))
                    }
                    TransactionField::Type => TypeIdent::option(TypeIdent::Int),
                    TransactionField::L1Fee => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::L1GasPrice => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::L1GasUsed => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::L1FeeScalar => TypeIdent::option(TypeIdent::Float),
                    TransactionField::GasUsedForL1 => TypeIdent::option(TypeIdent::BigInt),
                    TransactionField::AccessList => {
                        TypeIdent::option(TypeIdent::array(TypeIdent::Unknown))
                    }
                    TransactionField::AuthorizationList => {
                        TypeIdent::option(TypeIdent::array(TypeIdent::Unknown))
                    }
                };
                SelectedField {
                    name: field.to_string(),
                    data_type,
                }
            })
            .collect();

        Self::new(transaction_fields, block_fields)
    }

    pub fn try_from_config_field_selection(
        field_selection_cfg: human_config::evm::FieldSelection,
        // For validating transaction field selection with rpc
        has_rpc_sync_src: bool,
    ) -> Result<Self> {
        use human_config::evm::BlockField;
        use human_config::evm::TransactionField;

        let transaction_fields = field_selection_cfg.transaction_fields.unwrap_or_default();
        let block_fields = field_selection_cfg.block_fields.unwrap_or_default();

        //Validate no duplicates in field selection
        let tx_duplicates: Vec<_> = transaction_fields.iter().duplicates().collect();

        if !tx_duplicates.is_empty() {
            return Err(anyhow!(
                "transaction_fields selection contains the following duplicates: {}",
                tx_duplicates.iter().join(", ")
            ));
        }

        let block_duplicates: Vec<_> = block_fields.iter().duplicates().collect();

        if !block_duplicates.is_empty() {
            return Err(anyhow!(
                "block_fields selection contains the following duplicates: {}",
                block_duplicates.iter().join(", ")
            ));
        }

        if has_rpc_sync_src {
            let invalid_rpc_tx_fields: Vec<_> = transaction_fields
                .iter()
                .filter(|&field| RpcTransactionField::try_from(field.clone()).is_err())
                .cloned()
                .collect();

            if !invalid_rpc_tx_fields.is_empty() {
                return Err(anyhow!(
                    "The following selected transaction_fields are unavailable for indexing via \
                     RPC: {}",
                    invalid_rpc_tx_fields.iter().join(", ")
                ));
            }

            let invalid_rpc_block_fields: Vec<_> = block_fields
                .iter()
                .filter(|&field| RpcBlockField::try_from(field.clone()).is_err())
                .cloned()
                .collect();

            if !invalid_rpc_block_fields.is_empty() {
                return Err(anyhow!(
                    "The following selected block_fields are unavailable for indexing via RPC: {}",
                    invalid_rpc_block_fields.iter().join(", ")
                ));
            }
        }

        let mut selected_block_fields = vec![];

        type Res = TypeIdent;
        type Block = BlockField;
        type Tx = TransactionField;

        for block_field in block_fields {
            let data_type = match block_field {
                Block::ParentHash => Res::String,
                Block::Nonce => Res::option(Res::BigInt),
                Block::Sha3Uncles => Res::String,
                Block::LogsBloom => Res::String,
                Block::TransactionsRoot => Res::String,
                Block::StateRoot => Res::String,
                Block::ReceiptsRoot => Res::String,
                Block::Miner => Res::Address,
                Block::Difficulty => Res::option(Res::BigInt),
                Block::TotalDifficulty => Res::option(Res::BigInt),
                Block::ExtraData => Res::String,
                Block::Size => Res::BigInt,
                Block::GasLimit => Res::BigInt,
                Block::GasUsed => Res::BigInt,
                Block::Uncles => Res::option(Res::array(Res::String)),
                Block::BaseFeePerGas => Res::option(Res::BigInt),
                Block::BlobGasUsed => Res::option(Res::BigInt),
                Block::ExcessBlobGas => Res::option(Res::BigInt),
                Block::ParentBeaconBlockRoot => Res::option(Res::String),
                Block::WithdrawalsRoot => Res::option(Res::String),
                // Block::Withdrawals => todo!(), //should be array of withdrawal record
                Block::L1BlockNumber => Res::option(Res::Int),
                Block::SendCount => Res::option(Res::String),
                Block::SendRoot => Res::option(Res::String),
                Block::MixHash => Res::option(Res::String),
            };
            selected_block_fields.push(SelectedField {
                name: block_field.to_string(),
                data_type,
            })
        }

        let mut selected_transaction_fields = vec![];

        for transaction_field in transaction_fields {
            let data_type = match transaction_field {
                Tx::TransactionIndex => Res::Int,
                Tx::Hash => Res::String,
                Tx::From => Res::option(Res::Address),
                Tx::To => Res::option(Res::Address),
                Tx::Gas => Res::BigInt,
                Tx::GasPrice => Res::option(Res::BigInt),
                Tx::MaxPriorityFeePerGas => Res::option(Res::BigInt),
                Tx::MaxFeePerGas => Res::option(Res::BigInt),
                Tx::CumulativeGasUsed => Res::BigInt,
                Tx::EffectiveGasPrice => Res::BigInt,
                Tx::GasUsed => Res::BigInt,
                Tx::Input => Res::String,
                Tx::Nonce => Res::BigInt,
                Tx::Value => Res::BigInt,
                Tx::V => Res::option(Res::String),
                Tx::R => Res::option(Res::String),
                Tx::S => Res::option(Res::String),
                Tx::ContractAddress => Res::option(Res::Address),
                Tx::LogsBloom => Res::String,
                Tx::Root => Res::option(Res::String),
                Tx::Status => Res::option(Res::Int),
                Tx::YParity => Res::option(Res::String),
                Tx::MaxFeePerBlobGas => Res::option(Res::BigInt),
                Tx::BlobVersionedHashes => Res::option(Res::array(Res::String)),
                Tx::Type => Res::option(Res::Int),
                Tx::L1Fee => Res::option(Res::BigInt),
                Tx::L1GasPrice => Res::option(Res::BigInt),
                Tx::L1GasUsed => Res::option(Res::BigInt),
                Tx::L1FeeScalar => Res::option(Res::Float),
                Tx::GasUsedForL1 => Res::option(Res::BigInt),
                Tx::AccessList => Res::option(Res::Array(Box::new(Res::TypeApplication {
                    name: "HyperSyncClient.ResponseTypes.accessList".to_string(),
                    type_params: vec![],
                }))),
                Tx::AuthorizationList => Res::option(Res::Array(Box::new(Res::TypeApplication {
                    name: "HyperSyncClient.ResponseTypes.authorizationList".to_string(),
                    type_params: vec![],
                }))),
            };
            selected_transaction_fields.push(SelectedField {
                name: transaction_field.to_string(),
                data_type,
            })
        }

        Ok(Self::new(
            selected_transaction_fields,
            selected_block_fields,
        ))
    }
}

#[cfg(test)]
mod test {
    use std::path::PathBuf;

    use super::SystemConfig;
    use crate::{
        config_parsing::{
            human_config::evm::HumanConfig as EvmConfig,
            system_config::{DataSource, Event, MainEvmDataSource},
        },
        project_paths::ParsedProjectPaths,
    };
    use alloy_json_abi::Event as AlloyEvent;
    use handlebars::Handlebars;
    use pretty_assertions::assert_eq;
    use serde_json::json;

    #[test]
    fn renders_nested_f32() {
        let hbs = Handlebars::new();

        let rendered_backoff_multiplicative = hbs
            .render_template(
                "{{backoff_multiplicative}}",
                &json!({"backoff_multiplicative": 0.8}),
            )
            .unwrap();
        assert_eq!(&rendered_backoff_multiplicative, "0.8");
    }

    // 20-byte hex addresses must round-trip verbatim through the full
    // YAML → SystemConfig → public JSON pipeline. The ERC20 silent-skip
    // bug came from an editor f64-truncating the address on disk; this
    // locks the indexer-side path so we never reintroduce the corruption.
    #[test]
    fn parses_unquoted_hex_address_through_full_pipeline() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_paths = ParsedProjectPaths::new(&test_dir, "configs/unquoted-hex-address.yaml")
            .expect("Failed creating parsed_paths");

        let config =
            SystemConfig::parse_from_project_files(&project_paths).expect("Failed parsing config");

        let chains = config.get_chains();
        let chain = chains
            .iter()
            .find(|c| c.id == 1)
            .expect("chain id 1 missing");
        let contract = chain
            .contracts
            .iter()
            .find(|c| c.name == "Contract1")
            .expect("Contract1 missing");
        assert_eq!(
            contract.addresses,
            vec!["0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984".to_string()],
            "address must round-trip verbatim through SystemConfig"
        );

        let public_json = config
            .to_public_config_json(false)
            .expect("Failed serializing public config");
        assert!(
            public_json.contains("0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"),
            "public config JSON missing original address. Got:\n{public_json}"
        );

        // Mirror NAPI's two serde_json round-trips that hand the config
        // to the JS runtime.
        use crate::executor::public_config_value;
        let value = public_config_value(&config, false).expect("public_config_value");
        let wire = serde_json::to_string(&value).expect("to_string");
        assert!(
            wire.contains("0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"),
            "NAPI wire JSON missing original address. Got:\n{wire}"
        );
    }

    #[test]
    fn skip_chain_excluded_from_public_config_json() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_paths = ParsedProjectPaths::new(&test_dir, "configs/skip-one-chain.yaml")
            .expect("Failed creating parsed_paths");

        let config =
            SystemConfig::parse_from_project_files(&project_paths).expect("Failed parsing config");

        assert_eq!(config.get_chains().len(), 2, "both chains should be parsed");

        let public_json = config
            .to_public_config_json(false)
            .expect("Failed serializing public config");
        let parsed: serde_json::Value =
            serde_json::from_str(&public_json).expect("Failed parsing public config JSON");
        let chains = parsed["evm"]["chains"]
            .as_object()
            .expect("evm.chains should be an object");

        assert_eq!(
            chains.len(),
            1,
            "only the active chain should be in public config"
        );
        assert!(
            !public_json.contains("\"id\":137"),
            "skipped chain 137 should not appear in public config JSON"
        );
    }

    #[test]
    fn skip_all_chains_returns_error() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_paths = ParsedProjectPaths::new(&test_dir, "configs/skip-all-chains.yaml")
            .expect("Failed creating parsed_paths");

        let config =
            SystemConfig::parse_from_project_files(&project_paths).expect("Failed parsing config");

        let err = config
            .to_public_config_json(false)
            .expect_err("should error when all chains are skipped");
        assert!(
            err.to_string().contains("All chains are skipped"),
            "unexpected error message: {err}"
        );
    }

    #[test]
    fn test_get_contract_abi() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_root = test_dir.as_str();
        let config_dir = "configs/config1.yaml";
        let project_paths = ParsedProjectPaths::new(project_root, config_dir)
            .expect("Failed creating parsed_paths");

        let config =
            SystemConfig::parse_from_project_files(&project_paths).expect("Failed parsing config");

        let contract_name = "Contract1".to_string();

        let contract_abi = match &config
            .get_contract(&contract_name)
            .expect("Failed getting contract")
            .abi
        {
            super::Abi::Evm(abi) => abi.typed.clone(),
            super::Abi::Fuel(_) => panic!("Fuel abi should not be parsed"),
            super::Abi::Svm(_) => panic!("Svm abi should not be parsed"),
        };

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

        let expected_abi: alloy_json_abi::JsonAbi =
            serde_json::from_str(expected_abi_string).unwrap();

        assert_eq!(expected_abi, contract_abi);
    }

    #[test]
    fn test_get_nested_contract_abi() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_root = test_dir.as_str();
        let config_dir = "configs/nested-abi.yaml";
        let project_paths = ParsedProjectPaths::new(project_root, config_dir)
            .expect("Failed creating parsed_paths");

        let config =
            SystemConfig::parse_from_project_files(&project_paths).expect("Failed parsing config");

        let contract_name = "Contract3".to_string();

        let contract_abi = match &config
            .get_contract(&contract_name)
            .expect("Failed getting contract")
            .abi
        {
            super::Abi::Evm(abi) => abi.typed.clone(),
            super::Abi::Fuel(_) => panic!("Fuel abi should not be parsed"),
            super::Abi::Svm(_) => panic!("Svm abi should not be parsed"),
        };

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

        let expected_abi: alloy_json_abi::JsonAbi =
            serde_json::from_str(expected_abi_string).unwrap();

        assert_eq!(expected_abi, contract_abi);
    }

    #[test]
    fn parse_event_sig_with_event_prefix() {
        let event_string = "event MyEvent(uint256 myArg)".to_string();

        let expected_event = AlloyEvent::parse("event MyEvent(uint256 myArg)").unwrap();
        let parsed_event = Event::get_abi_event(&event_string, &None).unwrap();

        assert_eq!(parsed_event.name, expected_event.name);
        assert_eq!(parsed_event.anonymous, expected_event.anonymous);
        assert_eq!(parsed_event.inputs.len(), expected_event.inputs.len());
    }

    #[test]
    fn parse_event_sig_without_event_prefix() {
        let event_string = ("MyEvent(uint256 myArg)").to_string();

        let expected_event = AlloyEvent::parse("event MyEvent(uint256 myArg)").unwrap();
        let parsed_event = Event::get_abi_event(&event_string, &None).unwrap();

        assert_eq!(parsed_event.name, expected_event.name);
        assert_eq!(parsed_event.anonymous, expected_event.anonymous);
        assert_eq!(parsed_event.inputs.len(), expected_event.inputs.len());
    }

    #[test]
    fn parse_event_sig_invalid_type_fails_on_param_conversion() {
        // Note: alloy's Event::parse is more permissive and accepts "uint69" even though
        // it's not a valid Solidity type. The error occurs when we try to convert the
        // EventParam to our abi_compat::EventParam using DynSolType::parse.
        let event_string = ("MyEvent(uint69 myArg)").to_string();
        let alloy_event = Event::get_abi_event(&event_string, &None).expect("Should parse");

        // The error occurs when trying to convert to our EventParam
        let result = Event::convert_event_params(&alloy_event);
        assert!(
            result.is_err(),
            "Expected error when parsing invalid type 'uint69'"
        );
    }

    #[test]
    fn normalize_event_signature_handles_formatting_issues() {
        // Trailing semicolon
        assert_eq!(
            Event::normalize_event_signature("Transfer(address from);"),
            "Transfer(address from)"
        );
        // Space before comma
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128 ,uint16)"),
            "Foo(uint128, uint16)"
        );
        // Multiple spaces after comma
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128,  uint16)"),
            "Foo(uint128, uint16)"
        );
        // No space after comma (should add one)
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128,uint16)"),
            "Foo(uint128, uint16)"
        );
        // Already well-formatted
        assert_eq!(
            Event::normalize_event_signature("Foo(uint128, uint16)"),
            "Foo(uint128, uint16)"
        );
        // Leading/trailing whitespace
        assert_eq!(
            Event::normalize_event_signature("  Foo(uint128, uint16)  "),
            "Foo(uint128, uint16)"
        );
    }

    #[test]
    fn parse_event_sig_with_trailing_semicolon() {
        // Issue #959: trailing semicolons should be stripped
        let event_string =
            "AddShopItems((uint128, uint16, uint16, uint16, uint16, bool)[] shopItems, uint256 indexed globalEventId);";
        let parsed = Event::get_abi_event(event_string, &None).unwrap();
        assert_eq!(parsed.name, "AddShopItems");
        assert_eq!(parsed.inputs.len(), 2);
    }

    #[test]
    fn parse_event_sig_with_space_before_comma() {
        // Issue #959: spaces before commas should be normalized
        let event_string =
            "AddShopItems((uint128 ,uint16,uint16 ,uint16,uint16,bool)[] shopItems, uint256 indexed globalEventId)";
        let parsed = Event::get_abi_event(event_string, &None).unwrap();
        assert_eq!(parsed.name, "AddShopItems");
        assert_eq!(parsed.inputs.len(), 2);
    }

    #[test]
    fn parse_event_sig_with_all_formatting_issues() {
        // Issue #959: combination of trailing semicolon and inconsistent spacing
        let event_string =
            "AddShopItems((uint128 ,uint16,uint16 ,uint16,uint16,bool)[] shopItems, uint256 indexed globalEventId);";
        let parsed = Event::get_abi_event(event_string, &None).unwrap();
        assert_eq!(parsed.name, "AddShopItems");
        assert_eq!(parsed.inputs.len(), 2);

        // Should produce the same sighash as the well-formatted version
        let well_formatted =
            "AddShopItems((uint128, uint16, uint16, uint16, uint16, bool)[] shopItems, uint256 indexed globalEventId)";
        let expected = Event::get_abi_event(well_formatted, &None).unwrap();
        assert_eq!(
            parsed.selector().to_string(),
            expected.selector().to_string(),
            "Sighash should match regardless of formatting"
        );
    }

    #[test]
    fn parse_event_sig_with_named_tuple_components_issue_1206() {
        // Regression for https://github.com/enviodev/hyperindex/issues/1206.
        // A custom event signature whose tuple components are named must not
        // require an ABI file. Selector should match the canonical tuple-only
        // signature (component names stripped per ABI spec).
        let event_string = "ConsumeBoostVial(address from, uint256 playerId, (uint40 a, uint24 b, uint16 c, uint16 d, uint8 e) playerBoostInfo)";
        let parsed = Event::get_abi_event(event_string, &None).unwrap();

        let canonical = "ConsumeBoostVial(address from, uint256 playerId, (uint40,uint24,uint16,uint16,uint8) playerBoostInfo)";
        let canonical_parsed = Event::get_abi_event(canonical, &None).unwrap();

        // Selector is computed from the canonical (unnamed) signature so the
        // two forms must match.
        assert_eq!(
            parsed.selector().to_string(),
            canonical_parsed.selector().to_string(),
        );

        // Component names must survive into our converted EventParam tree so
        // codegen can emit named record fields.
        let params = Event::convert_event_params(&parsed).unwrap();
        let tuple_param = params
            .iter()
            .find(|p| p.name == "playerBoostInfo")
            .expect("playerBoostInfo");
        let names: Vec<Option<&str>> = match &tuple_param.kind {
            crate::config_parsing::abi_compat::AbiType::Tuple(fields) => {
                fields.iter().map(|f| f.name.as_deref()).collect()
            }
            other => panic!("expected Tuple, got {:?}", other),
        };
        assert_eq!(
            names,
            vec![Some("a"), Some("b"), Some("c"), Some("d"), Some("e")]
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

    #[test]
    fn test_parse_url() {
        let valid_url_1 = "https://eth-mainnet.g.alchemy.com/v2/T7uPV59s7knYTOUardPPX0hq7n7_rQwv";
        let valid_url_2 = "http://api.example.org:8080";
        let valid_url_3 = "https://eth.com/rpc-endpoint";
        assert_eq!(super::parse_url(valid_url_1), Some(valid_url_1.to_string()));
        assert_eq!(super::parse_url(valid_url_2), Some(valid_url_2.to_string()));
        assert_eq!(super::parse_url(valid_url_3), Some(valid_url_3.to_string()));

        let invalid_url_missing_slash = "http:/example.com";
        let invalid_url_other_protocol = "ftp://example.com";
        assert_eq!(super::parse_url(invalid_url_missing_slash), None);
        assert_eq!(super::parse_url(invalid_url_other_protocol), None);

        // With trailing slashes
        assert_eq!(
            super::parse_url("https://somechain.hypersync.xyz/"),
            Some("https://somechain.hypersync.xyz".to_string())
        );
        assert_eq!(
            super::parse_url("https://somechain.hypersync.xyz//"),
            Some("https://somechain.hypersync.xyz".to_string())
        );
    }

    #[test]
    fn deserializes_contract_config_with_multiple_sync_sources() {
        let config_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test/configs/invalid-multiple-sync-config.yaml");

        let file_str = std::fs::read_to_string(config_path).unwrap();

        let cfg: EvmConfig = serde_yaml::from_str(&file_str).unwrap();

        // Both hypersync and rpc config should be present
        assert!(cfg.chains[0].rpc.is_some());
        assert!(cfg.chains[0].hypersync_config.is_some());

        let error = DataSource::from_evm_network_config(cfg.chains[0].clone()).unwrap_err();

        assert_eq!(error.to_string(), "Cannot define both hypersync_config and rpc as a data-source for historical sync at the same time, please choose only one option or set RPC to be a fallback. Read more in our docs https://docs.envio.dev/docs/configuration-file");
    }

    #[test]
    fn test_hypersync_url_trailing_slash_trimming() {
        use crate::config_parsing::human_config::evm::{Chain as EvmChain, HypersyncConfig};

        let network = EvmChain {
            id: 1,
            skip: None,
            hypersync_config: Some(HypersyncConfig {
                url: "https://somechain.hypersync.xyz//".to_string(),
            }),
            rpc: None,
            start_block: 0,
            end_block: None,
            max_reorg_depth: None,
            block_lag: None,
            contracts: None,
        };

        let sync_source = DataSource::from_evm_network_config(network).unwrap();

        assert_eq!(
            sync_source,
            DataSource::Evm {
                main: MainEvmDataSource::HyperSync {
                    hypersync_endpoint_url: "https://somechain.hypersync.xyz".to_string(),
                },
                rpcs: vec![],
            }
        );
    }

    #[test]
    fn test_valid_version_numbers() {
        let valid_version_numbers = vec![
            "0.0.0",
            "999.999.999",
            "0.0.1",
            "10.2.3",
            "2.0.0-rc.1",
            "2.26.0-alpha.0",
            "2.26.0-alpha.10",
            "0.0.0-main-20241001144237-a236a894",
        ];

        for vn in valid_version_numbers {
            assert!(super::is_valid_release_version_number(vn));
        }
    }

    #[test]
    fn test_invalid_version_numbers() {
        let invalid_version_numbers = vec![
            "v10.1.0",
            "0.1",
            "0.0.1-dev",
            "0.1.*",
            "^0.1.2",
            "0.0.1.2",
            "1..1",
            "1.1.",
            ".1.1",
            "1.1.1.",
        ];
        for vn in invalid_version_numbers {
            assert!(!super::is_valid_release_version_number(vn));
        }
    }

    #[test]
    fn test_storage_resolve() {
        use super::human_config::StorageConfig;

        // Default (None) -> postgres only
        assert_eq!(
            super::Storage::resolve(None).unwrap(),
            super::Storage {
                postgres: true,
                clickhouse: false
            }
        );

        // Empty struct -> defaults
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: None,
                clickhouse: None,
            }))
            .unwrap(),
            super::Storage {
                postgres: true,
                clickhouse: false
            }
        );

        // Both enabled -> ok
        assert_eq!(
            super::Storage::resolve(Some(&StorageConfig {
                postgres: Some(true),
                clickhouse: Some(true),
            }))
            .unwrap(),
            super::Storage {
                postgres: true,
                clickhouse: true
            }
        );

        // ClickHouse without Postgres -> user-friendly error
        let err = super::Storage::resolve(Some(&StorageConfig {
            postgres: Some(false),
            clickhouse: Some(true),
        }))
        .unwrap_err();
        assert!(
            err.to_string()
                .contains("ClickHouse is not supported as a single storage yet"),
            "Unexpected error: {err}"
        );

        // ClickHouse enabled with Postgres omitted -> same error; user must
        // opt in to Postgres explicitly rather than relying on the default.
        let err = super::Storage::resolve(Some(&StorageConfig {
            postgres: None,
            clickhouse: Some(true),
        }))
        .unwrap_err();
        assert!(
            err.to_string()
                .contains("ClickHouse is not supported as a single storage yet"),
            "Unexpected error: {err}"
        );

        // All storages disabled -> user-friendly error
        let err = super::Storage::resolve(Some(&StorageConfig {
            postgres: Some(false),
            clickhouse: Some(false),
        }))
        .unwrap_err();
        assert!(
            err.to_string()
                .contains("At least one storage backend must be enabled"),
            "Unexpected error: {err}"
        );

        // postgres explicitly false with clickhouse omitted -> same error
        let err = super::Storage::resolve(Some(&StorageConfig {
            postgres: Some(false),
            clickhouse: None,
        }))
        .unwrap_err();
        assert!(
            err.to_string()
                .contains("At least one storage backend must be enabled"),
            "Unexpected error: {err}"
        );
    }

    // --- validate_entity_storage: per-entity storage routing checks ---

    mod entity_storage_validation {
        use super::super::{validate_entity_storage, Storage};
        use crate::config_parsing::entity_parsing::{Entity, Schema};

        // Bypass `Schema::new` validation: only storage routing matters here.
        fn make_schema(entities: Vec<Entity>) -> Schema {
            let mut schema = Schema::empty();
            for entity in entities {
                schema.entities.insert(entity.name.clone(), entity);
            }
            schema
        }

        fn entity(name: &str, postgres: Option<bool>, clickhouse: Option<bool>) -> Entity {
            Entity {
                name: name.to_string(),
                fields: Vec::new(),
                multi_field_indexes: Vec::new(),
                description: None,
                postgres,
                clickhouse,
            }
        }

        #[test]
        fn single_storage_no_directive_ok() {
            let schema = make_schema(vec![entity("Transfer", None, None)]);
            let storage = Storage {
                postgres: true,
                clickhouse: false,
            };
            assert!(validate_entity_storage(&storage, &schema).is_ok());
        }

        #[test]
        fn single_storage_matching_directive_ok() {
            let schema = make_schema(vec![entity("Transfer", Some(true), None)]);
            let storage = Storage {
                postgres: true,
                clickhouse: false,
            };
            assert!(validate_entity_storage(&storage, &schema).is_ok());
        }

        #[test]
        fn single_storage_entity_targets_disabled_backend_e1() {
            // Global: postgres only. Entity wants clickhouse → E1.
            let schema = make_schema(vec![entity("Snapshot", Some(true), Some(true))]);
            let storage = Storage {
                postgres: true,
                clickhouse: false,
            };
            let err = validate_entity_storage(&storage, &schema).unwrap_err();
            assert_eq!(
                err.to_string(),
                "Schema validation failed:\n\
                 \n\
                 Entities using storages not enabled in config.yaml:\n  \
                 - `Snapshot` uses `clickhouse`, but `clickhouse` is not enabled.\n\
                 \n\
                 Fixes:\n  \
                 - Remove the unsupported storage from @storage on these entities, or enable it under `storage:` in config.yaml."
            );
        }

        #[test]
        fn multi_storage_all_annotated_ok() {
            let schema = make_schema(vec![
                entity("Transfer", Some(true), None),
                entity("Snapshot", None, Some(true)),
                entity("Audit", Some(true), Some(true)),
            ]);
            let storage = Storage {
                postgres: true,
                clickhouse: true,
            };
            assert!(validate_entity_storage(&storage, &schema).is_ok());
        }

        #[test]
        fn multi_storage_missing_directives_e2() {
            let schema = make_schema(vec![
                entity("Transfer", None, None),
                entity("Approval", None, None),
                entity("DailySnapshot", None, None),
            ]);
            let storage = Storage {
                postgres: true,
                clickhouse: true,
            };
            let err = validate_entity_storage(&storage, &schema).unwrap_err();
            assert_eq!(
                err.to_string(),
                "Schema validation failed:\n\
                 \n\
                 Entities missing the @storage directive (multi-storage mode requires it):\n  \
                 - Approval\n  \
                 - DailySnapshot\n  \
                 - Transfer\n\
                 \n\
                 Fixes:\n  \
                 - Add @storage(postgres: true) and/or @storage(clickhouse: true) to the entities listed above. Example:\n      \
                 type Approval @storage(postgres: true) { ... }\n      \
                 type Approval @storage(clickhouse: true) { ... }\n      \
                 type Approval @storage(postgres: true, clickhouse: true) { ... }"
            );
        }

        // Insertion order is Zebra→Apple→Mango; the error must still list
        // them alphabetically regardless of HashMap iteration order.
        #[test]
        fn entities_listed_alphabetically_in_error() {
            let schema = make_schema(vec![
                entity("Zebra", None, None),
                entity("Apple", None, None),
                entity("Mango", None, None),
            ]);
            let storage = Storage {
                postgres: true,
                clickhouse: true,
            };
            let err = validate_entity_storage(&storage, &schema).unwrap_err();
            assert!(
                err.to_string().contains("- Apple\n  - Mango\n  - Zebra"),
                "Entities not listed alphabetically. Got:\n{err}"
            );
        }
    }

    mod svm_translation {
        use super::SystemConfig;
        use crate::config_parsing::system_config::{Abi, DataSource, EventKind};
        use crate::project_paths::ParsedProjectPaths;
        use pretty_assertions::assert_eq;

        /// End-to-end: the Metaplex YAML fixture deserializes, validates, and
        /// translates into a single Contract whose two Events carry the
        /// expected discriminator + flags. Guards Stage 3 + Stage 4 plumbing
        /// from drifting out of sync.
        #[test]
        fn translates_metaplex_yaml_into_contract_events() {
            let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
            let project_paths =
                ParsedProjectPaths::new(&test_dir, "configs/svm-metaplex-config.yaml")
                    .expect("paths");
            let config = SystemConfig::parse_from_project_files(&project_paths).expect("parse");

            // Single chain, single program -> one contract with two events.
            let contracts = config.contracts.values().collect::<Vec<_>>();
            assert_eq!(contracts.len(), 1);
            let token_metadata = contracts[0];
            assert_eq!(token_metadata.name, "TokenMetadata");
            assert!(matches!(token_metadata.abi, Abi::Svm(_)));
            assert_eq!(token_metadata.events.len(), 2);

            let kinds: Vec<_> = token_metadata
                .events
                .iter()
                .map(|e| match &e.kind {
                    EventKind::Svm(k) => (
                        e.name.as_str(),
                        k.discriminator.as_deref(),
                        k.discriminator_byte_len,
                        k.include_transaction,
                        k.include_logs,
                        k.include_token_balances,
                        k.account_filters.len(),
                    ),
                    _ => panic!("expected Svm event kind, got {:?}", e.kind),
                })
                .collect();
            assert_eq!(
                kinds,
                vec![
                    (
                        "CreateMetadataAccountV3",
                        Some("0x21"),
                        1,
                        false,
                        false,
                        false,
                        0
                    ),
                    (
                        "UpdateMetadataAccountV2",
                        Some("0x0f"),
                        1,
                        true,
                        false,
                        false,
                        1
                    ),
                ],
            );

            // Chain data carries the program_id on the contract-side address,
            // and the HyperSync URL flows through to the source config.
            let chains = config.get_chains();
            assert_eq!(chains.len(), 1);
            let chain = chains[0];
            assert_eq!(chain.contracts.len(), 1);
            assert_eq!(
                chain.contracts[0].addresses,
                vec!["metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s".to_string()],
            );
            assert!(matches!(
                &chain.sync_source,
                DataSource::Svm {
                    hypersync_endpoint_url: Some(url),
                    ..
                } if url == "https://solana.hypersync.xyz"
            ));
        }
    }
}
