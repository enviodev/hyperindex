use super::{path_utils, ProjectPaths};
use pathdiff::diff_paths;
use serde::Serialize;
use std::{collections::HashMap, path::PathBuf};

use crate::{
    cli_args::ProjectPathsArgs,
    config_parsing::{config, deserialize_config_from_yaml},
    utils::unique_hashmap,
};

pub const DEFAULT_SCHEMA_PATH: &str = "schema.graphql";

use anyhow::{anyhow, Context};
type ContractNameKey = String;

#[derive(Serialize, Debug, Eq, PartialEq, Clone)]
pub struct HandlerPathsTemplate {
    absolute: String,
    relative_to_generated_src: String,
}

#[derive(Debug)]
pub struct ParsedPaths {
    pub project_paths: ProjectPaths,
    pub schema_path: PathBuf,
    pub handler_paths: HashMap<ContractNameKey, PathBuf>,
    abi_paths: HashMap<ContractNameKey, PathBuf>,
}

impl ParsedPaths {
    pub fn new(project_paths_args: ProjectPathsArgs) -> anyhow::Result<ParsedPaths> {
        let project_paths =
            ProjectPaths::new(project_paths_args).context("Failed parsing project_paths")?;

        let config_directory = project_paths
            .config
            .parent()
            .ok_or_else(|| anyhow!("Unexpected config file should have a parent directory"))?;

        let deserialized_yaml = deserialize_config_from_yaml(&project_paths.config)
            .context("Failed deserializing config file")?;
        let parsed_config =
            config::Config::parse_from_yaml_config(&deserialized_yaml, &project_paths)
                .context("Failed parsing config from deserialized file")?;
        let schema_path_relative = PathBuf::from(&parsed_config.schema_path);
        let schema_path_joined = config_directory.join(schema_path_relative);
        let schema_path = path_utils::normalize_path(&schema_path_joined);

        let mut handler_paths = HashMap::new();
        let mut abi_paths = HashMap::new();
        for contract in parsed_config.get_contracts() {
            let handler_path_relative = PathBuf::from(&contract.handler_path);
            let handler_path_joined = config_directory.join(handler_path_relative);
            let handler_path = path_utils::normalize_path(&handler_path_joined);

            unique_hashmap::try_insert(&mut handler_paths, contract.name.clone(), handler_path)
                .context("Failed inserting contract handler into parsed paths")?;

            if let Some(abi_path_str) = &contract.abi_file_path {
                let abi_path_relative = PathBuf::from(abi_path_str);
                let abi_path_joined = config_directory.join(abi_path_relative);
                let abi_path = path_utils::normalize_path(&abi_path_joined);

                unique_hashmap::try_insert(&mut abi_paths, contract.name.clone(), abi_path)
                    .context("Failed inserting contract abi file path into parsed paths")?;
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
        contract_name: &ContractNameKey,
    ) -> anyhow::Result<HandlerPathsTemplate> {
        let generated_src = self.project_paths.generated.join("src");

        let absolute_path = self
            .handler_paths
            .get(contract_name)
            .ok_or_else(|| anyhow!("invalid contract configuration"))?;

        let relative_to_generated_src = diff_paths(absolute_path, generated_src)
            .ok_or_else(|| anyhow!("could not find handler path relative to generated"))?
            .to_str()
            .ok_or_else(|| anyhow!("Handler path should be unicode"))?
            .to_string();

        let absolute = absolute_path
            .to_str()
            .ok_or_else(|| anyhow!("Handler path should be unicode"))?
            .to_string();

        Ok(HandlerPathsTemplate {
            absolute,
            relative_to_generated_src,
        })
    }

    pub fn get_contract_abi(
        &self,
        contract_name: &ContractNameKey,
    ) -> anyhow::Result<Option<ethers::abi::Contract>> {
        let abi_path_opt = self.abi_paths.get(contract_name);

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
    use super::{HandlerPathsTemplate, ParsedPaths};

    #[test]
    fn test_all_paths_construction_1() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let test_dir_path_buf = PathBuf::from(&test_dir);
        let project_root = String::from(test_dir);
        let config = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let parsed_paths = ParsedPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .expect("Failed creating parsed_paths");

        let expected_schema_path = test_dir_path_buf.join(PathBuf::from("schemas/schema.graphql"));
        let contract_name = "Contract1".to_string();

        let mut expected_handler_paths = HashMap::new();
        expected_handler_paths.insert(
            contract_name.clone(),
            test_dir_path_buf.join(PathBuf::from("configs/src/EventHandler.js")),
        );

        let mut expected_abi_paths = HashMap::new();
        expected_abi_paths.insert(
            contract_name,
            test_dir_path_buf.join(PathBuf::from("abis/Contract1.json")),
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
        .expect("Failed creating parsed_paths");

        let contract_name = "Contract1".to_string();

        let contract_handler_paths = parsed_paths
            .get_contract_handler_paths_template(&contract_name)
            .expect("Failed getting contract handler_paths_template");
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
        .expect("Failed creating parsed_paths");

        let contract_name = "Contract1".to_string();

        let contract_abi = parsed_paths
            .get_contract_abi(&contract_name)
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
