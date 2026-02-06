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
    collections::{HashMap, HashSet},
    env, fs,
    path::{Component, Path, PathBuf},
};

type ContractNameKey = String;
type NetworkIdKey = u64;
type EntityKey = String;
type GraphqlEnumKey = String;
type NetworkMap = HashMap<NetworkIdKey, Network>;
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

pub fn get_envio_version() -> Result<String> {
    let crate_version = env!("CARGO_PKG_VERSION");
    if is_valid_release_version_number(crate_version) {
        // Check that crate version is not a dev release. In which case the
        // version should be installable from npm
        Ok(crate_version.to_string())
    } else {
        // Else install the local version for development and testing
        match env::current_exe() {
            // This should be something like "file:~/envio/hyperindex/codegenerator/target/debug/envio" or "file:.../target/debug/integration_tests"
            Ok(exe_path) => Ok(format!(
                "file:{}/../../../cli/npm/envio",
                exe_path.to_string_lossy()
            )),
            Err(e) => Err(anyhow!("failed to get current exe path: {e}")),
        }
    }
}

#[derive(Debug)]
pub struct SystemConfig {
    pub name: String,
    pub schema_path: String,
    pub parsed_project_paths: ParsedProjectPaths,
    pub chains: NetworkMap,
    pub contracts: ContractMap,
    pub multichain: human_config::evm::Multichain,
    pub rollback_on_reorg: bool,
    pub save_full_history: bool,
    pub schema: Schema,
    pub field_selection: FieldSelection,
    pub enable_raw_events: bool,
    pub human_config: HumanConfig,
    pub lowercase_addresses: bool,
    pub handlers: Option<String>,
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

    pub fn get_chains(&self) -> Vec<&Network> {
        let mut chains: Vec<&Network> = self.chains.values().collect();
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
        let mut chains: NetworkMap = HashMap::new();
        let mut contracts: ContractMap = HashMap::new();

        let base_config = human_config.get_base_config();

        // Create a new ParsedProjectPaths that uses the output field from config if specified
        let final_project_paths = {
            match base_config.output.as_ref() {
                Some(output) => {
                    // If output is specified, create a new ParsedProjectPaths with the custom output path
                    // The output path is relative to the config file location
                    let config_dir = project_paths.config.parent().ok_or_else(|| {
                        anyhow!("Unexpected config file should have a parent directory")
                    })?;

                    let output_relative_path = PathBuf::from(output);
                    if let Some(Component::ParentDir) =
                        output_relative_path.components().peekable().peek()
                    {
                        anyhow::bail!("Output folder must be in project directory");
                    }

                    let output_joined = config_dir.join(output_relative_path);
                    let output_normalized = path_utils::normalize_path(output_joined);

                    ParsedProjectPaths {
                        project_root: project_paths.project_root.clone(),
                        config: project_paths.config.clone(),
                        generated: output_normalized,
                    }
                }
                None => {
                    // If no output is specified, use the default ParsedProjectPaths
                    project_paths.clone()
                }
            }
        };

        match human_config {
            HumanConfig::Evm(ref evm_config) => {
                // TODO: Add similar validation for Fuel
                validation::validate_deserialized_config_yaml(evm_config)?;

                let has_rpc_sync_src = evm_config.chains.iter().any(|n| {
                    let has_hypersync = n.hypersync_config.is_some()
                        || hypersync_endpoints::get_default_hypersync_endpoint(n.id).is_ok();
                    let is_sync = |source_for: &Option<For>| match source_for {
                        Some(For::Sync) => true,
                        None => !has_hypersync,
                        _ => false,
                    };
                    match &n.rpc {
                        Some(RpcSelection::Single(rpc)) => is_sync(&rpc.source_for),
                        Some(RpcSelection::List(rpcs)) => rpcs.iter().any(|r| is_sync(&r.source_for)),
                        Some(RpcSelection::Url(_)) => !has_hypersync,
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

                    let contracts: Vec<NetworkContract> = network
                        .contracts
                        .as_ref()
                        .unwrap_or(&vec![])
                        .iter()
                        .cloned()
                        .map(|c| NetworkContract {
                            name: c.name,
                            addresses: c.address.into(),
                            start_block: c.start_block,
                        })
                        .collect();

                    let network = Network {
                        id: network.id,
                        max_reorg_depth: network
                            .max_reorg_depth
                            .or_else(|| get_max_reorg_depth_from_id(network.id)),
                        start_block: network.start_block,
                        end_block: network.end_block,
                        sync_source,
                        contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, network.id, network)
                        .context("Failed inserting network at chains map")?;
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
                    multichain: evm_config
                        .multichain
                        .clone()
                        .unwrap_or(human_config::evm::Multichain::Unordered),
                    rollback_on_reorg: evm_config.rollback_on_reorg.unwrap_or(true),
                    save_full_history: evm_config.save_full_history.unwrap_or(false),
                    schema,
                    field_selection,
                    enable_raw_events: evm_config.raw_events.unwrap_or(false),
                    lowercase_addresses: matches!(
                        evm_config.address_format,
                        Some(super::human_config::evm::AddressFormat::Lowercase)
                    ),
                    handlers: base_config.handlers.clone(),
                    human_config,
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

                    let contracts: Vec<NetworkContract> = network
                        .contracts
                        .as_ref()
                        .unwrap_or(&vec![])
                        .iter()
                        .cloned()
                        .map(|c| NetworkContract {
                            name: c.name,
                            addresses: c.address.into(),
                            start_block: c.start_block,
                        })
                        .collect();

                    let network = Network {
                        id: network.id,
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: None,
                        sync_source,
                        contracts,
                    };

                    unique_hashmap::try_insert(&mut chains, network.id, network)
                        .context("Failed inserting network at chains map")?;
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
                    multichain: human_config::evm::Multichain::Unordered,
                    rollback_on_reorg: false,
                    save_full_history: false,
                    schema,
                    field_selection: FieldSelection::fuel(),
                    enable_raw_events: fuel_config.raw_events.unwrap_or(false),
                    lowercase_addresses: false,
                    handlers: base_config.handlers.clone(),
                    human_config,
                })
            }
            HumanConfig::Svm(ref svm_config) => {
                for network in &svm_config.chains {
                    let sync_source = DataSource::Svm {
                        rpc: network.rpc.clone(),
                    };

                    let network = Network {
                        id: 0, //network.id,
                        start_block: network.start_block,
                        end_block: network.end_block,
                        max_reorg_depth: None,
                        sync_source,
                        contracts: vec![],
                    };

                    unique_hashmap::try_insert(&mut chains, network.id, network)
                        .context("Failed inserting network at chains map")?;
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
                    multichain: human_config::evm::Multichain::Unordered,
                    rollback_on_reorg: false,
                    save_full_history: false,
                    schema,
                    field_selection: FieldSelection::fuel(),
                    enable_raw_events: false,
                    lowercase_addresses: false,
                    handlers: None,
                    human_config,
                })
            }
        }
    }

    pub fn parse_from_project_files(project_paths: &ParsedProjectPaths) -> Result<Self> {
        let human_config_string =
            std::fs::read_to_string(&project_paths.config).context(format!(
                "EE104: Failed to resolve config path {0}. Make sure you're in the correct \
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
                "EE105: Failed to deserialize config. The config.yaml file is either not a valid \
                 yaml or the \"ecosystem\" field is not a string.",
            )?;

        let ecosystem = match config_discriminant.ecosystem.as_deref() {
            Some("evm") => Ecosystem::Evm,
            Some("fuel") => Ecosystem::Fuel,
            Some("svm") => Ecosystem::Svm,
            Some(ecosystem) => {
                return Err(anyhow!(
                    "EE105: Failed to deserialize config. The ecosystem \"{}\" is not supported.",
                    ecosystem
                ))
            }
            None => Ecosystem::Evm,
        };

        match ecosystem {
            Ecosystem::Evm => {
                let evm_config: EvmConfig =
                    serde_yaml::from_str(&human_config_string).context(format!(
                        "EE105: Failed to deserialize config. Visit the docs for more information \
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
                        "EE105: Failed to deserialize config. Visit the docs for more information \
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
                        "EE105: Failed to deserialize config. Visit the docs for more information \
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

impl DataSource {
    fn from_evm_network_config(network: EvmChain) -> Result<Self> {
        let hypersync_endpoint_url = match &network.hypersync_config {
            Some(config) => Some(config.url.to_string()),
            None => hypersync_endpoints::get_default_hypersync_endpoint(network.id).ok(),
        };
        let default_for = match &hypersync_endpoint_url {
            Some(_) => For::Fallback,
            None => For::Sync,
        };
        let resolve_for = |rpc: Rpc| Rpc {
            source_for: Some(rpc.source_for.unwrap_or(default_for.clone())),
            ..rpc
        };
        let raw_rpcs = match network.rpc {
            Some(RpcSelection::Url(url)) => vec![Rpc {
                url: url.to_string(),
                source_for: Some(default_for.clone()),
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
              None => return Err(anyhow!("EE109: The RPC url \"{}\" is incorrect format. The RPC url needs to start with either http:// or https://", rpc.url)),
              Some(url) => rpcs.push(Rpc {
                  url,
                  ..rpc.clone()
              })
            }
        }

        let rpc_for_sync = rpcs.iter().find(|rpc| rpc.source_for == Some(For::Sync));

        let main = match rpc_for_sync {
            Some(rpc) => {
                if network.hypersync_config.is_some() {
                    Err(anyhow!(
                        "EE106: Cannot define both hypersync_config and rpc as a data-source for \
                         historical sync at the same time, please choose only one option or set \
                         RPC to be a fallback. Read more in our docs {}",
                        links::DOC_CONFIGURATION_FILE
                    ))?
                };

                MainEvmDataSource::Rpc(rpc.clone())
            }
            None => {
                let url = hypersync_endpoint_url.ok_or(anyhow!(
                    "EE106: Failed to automatically find HyperSync endpoint for the network {}. \
                     Please provide it manually via the hypersync_config option, or provide an \
                     RPC URL for historical sync. Read more in our docs: {}",
                    network.id,
                    links::DOC_CONFIGURATION_SCHEMA_HYPERSYNC_CONFIG
                ))?;

                let parsed_url = parse_url(&url).ok_or(anyhow!(
                  "EE106: The HyperSync URL \"{}\" is in incorrect format. The URL needs to start with either http:// or https://",
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
pub struct Network {
    pub id: u64,
    pub sync_source: DataSource,
    pub start_block: u64,
    pub end_block: Option<u64>,
    pub max_reorg_depth: Option<i32>,
    pub contracts: Vec<NetworkContract>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NetworkContract {
    pub name: ContractNameKey,
    pub addresses: Vec<String>,
    pub start_block: Option<u64>,
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

#[derive(Debug, Clone, PartialEq)]
pub enum Abi {
    Evm(EvmAbi),
    Fuel(Box<FuelAbi>),
}

impl Abi {
    fn get_path(&self) -> Option<PathBuf> {
        match self {
            Abi::Evm(abi) => abi.path.clone(),
            Abi::Fuel(abi) => Some(abi.path_buf.clone()),
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
pub enum EventKind {
    Params(Vec<EventParam>),
    Fuel(FuelEventKind),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub kind: EventKind,
    pub name: String,
    pub sighash: String,
    pub field_selection: Option<FieldSelection>,
}

impl Event {
    fn get_abi_event(event_string: &str, opt_abi: &Option<EvmAbi>) -> Result<AlloyEvent> {
        let parse_event_sig = |sig: &str| -> Result<AlloyEvent> {
            AlloyEvent::parse(sig).map_err(|err| {
                anyhow!(
                    "EE103: Unable to parse event signature {} due to the following error: {}. \
                     Please refer to our docs on how to correctly define a human readable ABI.",
                    sig,
                    err
                )
            })
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
        let fuel_abi = FuelAbi::parse(abi_path).context("Failed to parse ABI".to_string())?;

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
                        field_selection: None,
                    }
                }
                EventType::Mint => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Mint),
                    sighash: "mint".to_string(),
                    field_selection: None,
                },
                EventType::Burn => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Burn),
                    sighash: "burn".to_string(),
                    field_selection: None,
                },
                EventType::Transfer => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Transfer),
                    sighash: "transfer".to_string(),
                    field_selection: None,
                },
                EventType::Call => Event {
                    name: event_config.name.clone(),
                    kind: EventKind::Fuel(FuelEventKind::Call),
                    sighash: "call".to_string(),
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

        let mut selected_block_fields = vec![
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
        ];

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
            human_config::{evm::HumanConfig as EvmConfig, BaseConfig},
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

    #[test]
    fn test_get_contract_abi() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let project_root = test_dir.as_str();
        let config_dir = "configs/config1.yaml";
        let generated = "generated/";
        let project_paths = ParsedProjectPaths::new(project_root, generated, config_dir)
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
        let generated = "generated/";
        let project_paths = ParsedProjectPaths::new(project_root, generated, config_dir)
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

        assert_eq!(error.to_string(), "EE106: Cannot define both hypersync_config and rpc as a data-source for historical sync at the same time, please choose only one option or set RPC to be a fallback. Read more in our docs https://docs.envio.dev/docs/configuration-file");
    }

    #[test]
    fn test_hypersync_url_trailing_slash_trimming() {
        use crate::config_parsing::human_config::evm::{Chain as EvmChain, HypersyncConfig};

        let network = EvmChain {
            id: 1,
            hypersync_config: Some(HypersyncConfig {
                url: "https://somechain.hypersync.xyz//".to_string(),
            }),
            rpc: None,
            start_block: 0,
            end_block: None,
            max_reorg_depth: None,
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
    fn test_output_configuration() {
        use crate::config_parsing::human_config::{
            evm::{Chain as EvmChain, HumanConfig as EvmConfig},
            HumanConfig,
        };
        use crate::project_paths::ParsedProjectPaths;

        // Test with default output (no output field specified)
        let evm_config = EvmConfig {
            base: BaseConfig {
                name: "Test Project".to_string(),
                description: None,
                schema: None,
                output: None,
                handlers: None,
                full_batch_size: None,
            },
            ecosystem: None,
            contracts: None,
            chains: vec![EvmChain {
                id: 1,
                hypersync_config: None,
                rpc: None,
                start_block: 0,
                end_block: None,
                max_reorg_depth: None,
                contracts: None,
            }],
            multichain: None,
            rollback_on_reorg: None,
            save_full_history: None,
            field_selection: None,
            raw_events: None,
            address_format: None,
        };

        let project_paths = ParsedProjectPaths::new(".", "generated", "config.yaml").unwrap();
        let schema = crate::config_parsing::entity_parsing::Schema {
            entities: std::collections::HashMap::new(),
            enums: std::collections::HashMap::new(),
        };

        let system_config = SystemConfig::from_human_config(
            HumanConfig::Evm(evm_config),
            schema.clone(),
            &project_paths,
        )
        .unwrap();

        // Should use the default generated path
        assert_eq!(
            system_config.parsed_project_paths.generated,
            project_paths.generated
        );

        // Test with custom output path
        let evm_config_with_output = EvmConfig {
            base: BaseConfig {
                name: "Test Project".to_string(),
                description: None,
                schema: None,
                output: Some("custom/output".to_string()),
                handlers: None,
                full_batch_size: None,
            },
            ecosystem: None,
            contracts: None,
            chains: vec![EvmChain {
                id: 1,
                hypersync_config: None,
                rpc: None,
                start_block: 0,
                end_block: None,
                max_reorg_depth: None,
                contracts: None,
            }],
            multichain: None,
            rollback_on_reorg: None,
            save_full_history: None,
            field_selection: None,
            raw_events: None,
            address_format: None,
        };

        let system_config_with_output = SystemConfig::from_human_config(
            HumanConfig::Evm(evm_config_with_output),
            schema,
            &project_paths,
        )
        .unwrap();

        // Should use the custom output path relative to config location
        let expected_custom_path = std::path::PathBuf::from("custom/output");
        assert_eq!(
            system_config_with_output.parsed_project_paths.generated,
            expected_custom_path
        );
    }
}
