use super::{path_utils, ParsedProjectPaths};
use crate::config_parsing::config;
use anyhow::anyhow;
use pathdiff::diff_paths;
use serde::Serialize;
use std::path::PathBuf;

pub const DEFAULT_SCHEMA_PATH: &str = "schema.graphql";

#[derive(Serialize, Debug, Eq, PartialEq, Clone)]
pub struct HandlerPathsTemplate {
    absolute: String,
    relative_to_generated_src: String,
}

impl HandlerPathsTemplate {
    pub fn from_contract(
        contract: &config::Contract,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<Self> {
        let config_directory = project_paths
            .config
            .parent()
            .ok_or_else(|| anyhow!("Unexpected config file should have a parent directory"))?;
        let handler_path_relative = PathBuf::from(&contract.handler_path);
        let handler_path_joined = config_directory.join(handler_path_relative);
        let absolute_path = path_utils::normalize_path(&handler_path_joined);

        let generated_src = project_paths.generated.join("src");

        let relative_to_generated_src = diff_paths(absolute_path.clone(), generated_src)
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
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use crate::{
        config_parsing::{self, config, entity_parsing::Schema},
        project_paths::ParsedProjectPaths,
    };

    #[test]
    fn test_all_paths_construction_1() {
        let test_dir = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let test_dir_path_buf = PathBuf::from(&test_dir);
        let project_root = String::from(test_dir);
        let config_dir = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let project_paths = ParsedProjectPaths::new(project_root, generated, config_dir)
            .expect("Failed creating parsed_paths");

        let yaml_cfg = config_parsing::deserialize_config_from_yaml(&project_paths.config)
            .expect("Failed deserializing config");

        let config =
            config::Config::parse_from_yaml_with_schema(&yaml_cfg, Schema::empty(), &project_paths)
                .expect("Failed parsing config");

        let expected_schema_path = test_dir_path_buf.join(PathBuf::from("schemas/schema.graphql"));

        let expected_handler_paths =
            vec![test_dir_path_buf.join(PathBuf::from("configs/src/EventHandler.js"))];

        let expected_abi_paths = vec![test_dir_path_buf.join(PathBuf::from("abis/Contract1.json"))];

        assert_eq!(
            expected_schema_path,
            config
                .get_path_to_schema(&project_paths)
                .expect("failed to get schema path")
        );
        assert_eq!(
            expected_handler_paths,
            config
                .get_all_paths_to_handlers(&project_paths)
                .expect("Failed to get hadnler paths")
        );
        assert_eq!(
            expected_abi_paths,
            config
                .get_all_paths_to_abi_files(&project_paths)
                .expect("failed to get abi paths")
        );
    }

    #[test]
    fn test_get_contract_handler_path_template() {
        let project_root = String::from("test");
        let config_dir = String::from("configs/config1.yaml");
        let generated = String::from("generated/");
        let project_paths = ParsedProjectPaths::new(project_root, generated, config_dir)
            .expect("Failed creating parsed_paths");

        let yaml_cfg = config_parsing::deserialize_config_from_yaml(&project_paths.config)
            .expect("Failed deserializing config");

        let config =
            config::Config::parse_from_yaml_with_schema(&yaml_cfg, Schema::empty(), &project_paths)
                .expect("Failed parsing config");

        let contract_name = "Contract1".to_string();

        let contract_handler_paths = super::HandlerPathsTemplate::from_contract(
            config
                .get_contract(&contract_name)
                .expect("Expected contract in config"),
            &project_paths,
        )
        .expect("Failed getting contract handler_paths_template");

        let expected_handler_paths = super::HandlerPathsTemplate {
            absolute: "test/configs/src/EventHandler.js".to_string(),

            relative_to_generated_src: "../../configs/src/EventHandler.js".to_string(),
        };

        assert_eq!(expected_handler_paths, contract_handler_paths);
    }
}
