use anyhow::anyhow;
use std::path::{Component, PathBuf};

use crate::{
    cli_args::{clap_definitions::ProjectPaths, init_config::InitConfig},
    constants::project_paths::{
        DEFAULT_CONFIG_PATH, DEFAULT_GENERATED_PATH, DEFAULT_PROJECT_ROOT_PATH,
    },
};

pub mod handler_paths;
pub mod path_utils;

#[derive(Debug, PartialEq, Clone)]
pub struct ParsedProjectPaths {
    pub project_root: PathBuf,
    pub config: PathBuf,
    pub generated: PathBuf,
}

impl ParsedProjectPaths {
    pub fn new(
        project_root: &str,
        generated: &str,
        config: &str,
    ) -> anyhow::Result<ParsedProjectPaths> {
        let project_root = PathBuf::from(&project_root);
        let generated_relative_path = PathBuf::from(generated);
        if let Some(Component::ParentDir) = generated_relative_path.components().peekable().peek() {
            return Err(anyhow!("Generated folder must be in project directory"));
        }
        let generated_joined: PathBuf = project_root.join(generated_relative_path);
        let generated = path_utils::normalize_path(generated_joined);

        let config_relative_path = PathBuf::from(config);
        if let Some(Component::ParentDir) = config_relative_path.components().peekable().peek() {
            return Err(anyhow!("Config path must be in project directory"));
        }

        let config_joined: PathBuf = project_root.join(config_relative_path);
        let config = path_utils::normalize_path(config_joined);

        Ok(ParsedProjectPaths {
            project_root,
            generated,
            config,
        })
    }

    pub fn default_with_root(project_root: &str) -> anyhow::Result<ParsedProjectPaths> {
        Self::new(project_root, DEFAULT_GENERATED_PATH, DEFAULT_CONFIG_PATH)
    }
}

impl Default for ParsedProjectPaths {
    fn default() -> Self {
        Self::new(
            DEFAULT_PROJECT_ROOT_PATH,
            DEFAULT_GENERATED_PATH,
            DEFAULT_CONFIG_PATH,
        )
        .expect("Unexpected failure initializing default parsed paths")
    }
}

impl TryFrom<ProjectPaths> for ParsedProjectPaths {
    type Error = anyhow::Error;
    fn try_from(project_paths: ProjectPaths) -> Result<Self, Self::Error> {
        let project_root = project_paths
            .directory
            .unwrap_or_else(|| DEFAULT_PROJECT_ROOT_PATH.to_string());

        Self::new(
            &project_root,
            &project_paths.output_directory,
            &project_paths.config,
        )
    }
}

impl TryFrom<InitConfig> for ParsedProjectPaths {
    type Error = anyhow::Error;
    fn try_from(init_config: InitConfig) -> Result<Self, Self::Error> {
        Self::default_with_root(&init_config.directory)
    }
}

#[cfg(test)]
mod tests {

    use super::ParsedProjectPaths;
    use pretty_assertions::assert_eq;
    use std::path::PathBuf;
    #[test]
    fn test_project_path_default_case() {
        let project_paths = ParsedProjectPaths::default();

        let expected_project_paths = ParsedProjectPaths {
            project_root: PathBuf::from("."),
            config: PathBuf::from("config.yaml"),
            generated: PathBuf::from("generated"),
        };
        assert_eq!(expected_project_paths, project_paths,)
    }
    #[test]
    fn test_project_path_alternative_case() {
        let project_root = "my_dir/my_project";
        let config = "custom_config.yaml";
        let generated = "custom_gen/my_project_generated";
        let project_paths = ParsedProjectPaths::new(project_root, generated, config).unwrap();

        let expected_project_paths = ParsedProjectPaths {
            project_root: PathBuf::from("my_dir/my_project/"),
            config: PathBuf::from("my_dir/my_project/custom_config.yaml"),

            generated: PathBuf::from("my_dir/my_project/custom_gen/my_project_generated"),
        };
        assert_eq!(expected_project_paths, project_paths,)
    }
    #[test]
    fn test_project_path_relative_case() {
        let project_root = "../my_dir/my_project";
        let config = "custom_config.yaml";
        let generated = "custom_gen/my_project_generated";
        let project_paths = ParsedProjectPaths::new(project_root, generated, config).unwrap();

        let expected_project_paths = ParsedProjectPaths {
            project_root: PathBuf::from("../my_dir/my_project/"),
            config: PathBuf::from("../my_dir/my_project/custom_config.yaml"),
            generated: PathBuf::from("../my_dir/my_project/custom_gen/my_project_generated"),
        };
        assert_eq!(expected_project_paths, project_paths)
    }

    #[test]
    #[should_panic]
    fn test_project_path_panics_when_generated_is_outside_of_root() {
        let project_root = "./";
        let config = "config.yaml";
        let generated = "../generated/";
        ParsedProjectPaths::new(project_root, config, generated).unwrap();
    }

    #[test]
    #[should_panic]
    fn test_project_path_panics_when_config_is_outside_of_root() {
        let project_root = "./";
        let config = "../config.yaml";
        let generated = "generated/";
        ParsedProjectPaths::new(project_root, config, generated).unwrap();
    }

    #[test]
    fn check_default_does_not_panic() {
        ParsedProjectPaths::default();
    }
}
