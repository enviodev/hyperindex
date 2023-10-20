use super::{path_utils, ProjectPaths};
use pathdiff::diff_paths;
use serde::Serialize;
use std::{collections::HashMap, error::Error, path::PathBuf};

use crate::{
    cli_args::ProjectPathsArgs,
    config_parsing::{deserialize_config_from_yaml, get_global_contract},
};

pub const DEFAULT_SCHEMA_PATH: &str = "schema.graphql";

use anyhow::Context;
#[derive(Eq, PartialEq, Hash, Debug, Clone)]
pub struct ContractUniqueId {
    pub network_id: u64,
    pub name: String,
}

#[derive(Serialize, Debug, Eq, PartialEq, Clone)]
pub struct HandlerPathsTemplate {
    absolute: String,
    relative_to_generated_src: String,
}

#[derive(Debug)]
pub struct ParsedPaths {
    pub project_paths: ProjectPaths,
    pub schema_path: PathBuf,
    pub handler_paths: HashMap<ContractUniqueId, PathBuf>,
    abi_paths: HashMap<ContractUniqueId, PathBuf>,
}

impl ParsedPaths {
    pub fn new(project_paths_args: ProjectPathsArgs) -> Result<ParsedPaths, Box<dyn Error>> {
        let project_paths = ProjectPaths::new(project_paths_args)?;

        let config_directory = project_paths
            .config
            .parent()
            .ok_or("Unexpected config file should have a parent directory")?;
        let parsed_config = deserialize_config_from_yaml(&project_paths.config)?;
        let schema_path_relative_opt = parsed_config.schema.clone().map(PathBuf::from);

        let schema_path_joined = match schema_path_relative_opt {
            Some(schema_path_relative) => config_directory.join(schema_path_relative),
            None => project_paths.project_root.join(DEFAULT_SCHEMA_PATH),
        };

        let schema_path = path_utils::normalize_path(&schema_path_joined);

        let mut handler_paths = HashMap::new();
        let mut abi_paths = HashMap::new();

        for network in parsed_config.networks.iter() {
            for contract in network.contracts.iter() {
                let contract_unique_id = ContractUniqueId {
                    network_id: network.id,
                    name: contract.name.clone(),
                };

                let handler_path_str = contract
                    .local_contract_config
                    .as_ref()
                    .map(|l_contract| Ok::<String, anyhow::Error>(l_contract.handler.clone()))
                    .unwrap_or_else(|| {
                        Ok(get_global_contract(&parsed_config, contract.name.clone())
                            .context("Failed getting global contract")?
                            .handler
                            .clone())
                    })
                    .context("Failed getting handler path")?;

                let abi_path_str_opt = contract
                    .local_contract_config
                    .as_ref()
                    .map(|l_contract| {
                        Ok::<Option<String>, anyhow::Error>(l_contract.abi_file_path.clone())
                    })
                    .unwrap_or_else(|| {
                        Ok(get_global_contract(&parsed_config, contract.name.clone())
                            .context("Failed getting global contract")?
                            .abi_file_path
                            .clone())
                    })
                    .context("Failed getting abi path")?;

                let handler_path_relative = PathBuf::from(handler_path_str);
                let handler_path_joined = config_directory.join(handler_path_relative);
                let handler_path = path_utils::normalize_path(&handler_path_joined);
                handler_paths
                    .entry(contract_unique_id.clone())
                    .or_insert(handler_path);

                if let Some(abi_path_str) = abi_path_str_opt {
                    let abi_path_relative = PathBuf::from(abi_path_str);
                    let abi_path_joined = config_directory.join(abi_path_relative);
                    let abi_path = path_utils::normalize_path(&abi_path_joined);
                    abi_paths.entry(contract_unique_id).or_insert(abi_path);
                }
            }
        }

        Ok(ParsedPaths {
            project_paths,
            schema_path,
            handler_paths,
            abi_paths,
        })
    }

    pub fn get_contract_handler_paths_template(
        &self,
        contract_unique_id: &ContractUniqueId,
    ) -> Result<HandlerPathsTemplate, Box<dyn Error>> {
        let generated_src = self.project_paths.generated.join("src");

        let absolute_path = self
            .handler_paths
            .get(contract_unique_id)
            .ok_or_else(|| "invalid contract configuration".to_string())?;

        let relative_to_generated_src = diff_paths(absolute_path, generated_src)
            .ok_or("could not find handler path relative to generated")?
            .to_str()
            .ok_or_else(|| "Handler path should be unicode".to_string())?
            .to_string();

        let absolute = absolute_path
            .to_str()
            .ok_or_else(|| "Handler path should be unicode".to_string())?
            .to_string();

        Ok(HandlerPathsTemplate {
            absolute,
            relative_to_generated_src,
        })
    }

    pub fn get_contract_abi(
        &self,
        contract_unique_id: &ContractUniqueId,
    ) -> anyhow::Result<Option<ethers::abi::Contract>> {
        let abi_path_opt = self.abi_paths.get(contract_unique_id);

        let abi_opt = match abi_path_opt {
            None => None,
            Some(abi_path) => {
                let abi_file = std::fs::read_to_string(abi_path).context(format!(
                    "Failed to read abi at {}",
                    abi_path.to_str().unwrap_or("no_path"),
                ))?;

                let opt_abi: Option<ethers::abi::Contract> = serde_json::from_str(&abi_file)
                    .map_err(|_e| eprintln!("Failed to deserialize ABI - contiuing without the ABI - future errors may occur. Please ensure the ABI file is formatted correctly or contact the team."))
                    .ok();

                opt_abi
            }
        };
        Ok(abi_opt)
    }

    pub fn get_all_handler_paths(&self) -> Vec<&PathBuf> {
        let mut paths = self.handler_paths.values().collect::<Vec<&PathBuf>>();
        paths.sort();

        paths
    }

    pub fn get_all_abi_paths(&self) -> Vec<&PathBuf> {
        let mut paths = self.abi_paths.values().collect::<Vec<&PathBuf>>();
        paths.sort();
        paths
    }
}

#[cfg(test)]
mod tests {
    use serde_json;
    use std::collections::HashMap;
    use std::path::PathBuf;

    use super::super::ProjectPathsArgs;
    use super::{ContractUniqueId, HandlerPathsTemplate, ParsedPaths};

    #[test]
    fn test_all_paths_construction_1() {
        let project_root = String::from("test");
        let config = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let expected_schema_path = PathBuf::from("test/schemas/schema.graphql");
        let contract_unique_id = ContractUniqueId {
            network_id: 1,
            name: "Contract1".to_string(),
        };

        let mut expected_handler_paths = HashMap::new();
        expected_handler_paths.insert(
            contract_unique_id.clone(),
            PathBuf::from("test/configs/src/EventHandler.js"),
        );

        let mut expected_abi_paths = HashMap::new();
        expected_abi_paths.insert(
            contract_unique_id,
            PathBuf::from("test/abis/Contract1.json"),
        );

        assert_eq!(expected_schema_path, parsed_paths.schema_path);
        assert_eq!(expected_handler_paths, parsed_paths.handler_paths);
        assert_eq!(expected_abi_paths, parsed_paths.abi_paths);
    }

    #[test]
    fn test_get_contract_handler_path_template() {
        let project_root = String::from("test");
        let config = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let contract_unique_id = ContractUniqueId {
            network_id: 1,
            name: String::from("Contract1"),
        };

        let contract_handler_paths = parsed_paths
            .get_contract_handler_paths_template(&contract_unique_id)
            .unwrap();
        let expected_handler_paths = HandlerPathsTemplate {
            absolute: "test/configs/src/EventHandler.js".to_string(),

            relative_to_generated_src: "../../configs/src/EventHandler.js".to_string(),
        };

        assert_eq!(expected_handler_paths, contract_handler_paths);
    }

    #[test]
    fn test_get_contract_abi() {
        let project_root = String::from("test");
        let config = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let contract_unique_id = ContractUniqueId {
            network_id: 1,
            name: String::from("Contract1"),
        };

        let contract_abi = parsed_paths
            .get_contract_abi(&contract_unique_id)
            .unwrap()
            .unwrap();
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

        let expected_abi: ethers::abi::Contract =
            serde_json::from_str(expected_abi_string).unwrap();

        assert_eq!(expected_abi, contract_abi);
    }
}
