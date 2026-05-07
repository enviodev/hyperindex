use anyhow::anyhow;
use std::path::PathBuf;

use crate::{
    cli_args::{clap_definitions::ProjectPaths, init_config::InitConfig},
    constants::project_paths::{
        DEFAULT_CONFIG_PATH, DEFAULT_PROJECT_ROOT_PATH, ENVIO_DIR, ENVIO_ENV_DTS_FILE,
        ENVIO_TYPES_FILE,
    },
};

pub mod path_utils;

#[derive(Debug, PartialEq, Clone)]
pub struct ParsedProjectPaths {
    pub project_root: PathBuf,
    pub config: PathBuf,
    /// Project-root + `.envio/` — holds ephemeral codegen output and cache.
    pub envio_dir: PathBuf,
}

impl ParsedProjectPaths {
    pub fn new(project_root: &str, config: &str) -> anyhow::Result<ParsedProjectPaths> {
        let project_root = PathBuf::from(&project_root);
        let envio_dir = path_utils::normalize_path(project_root.join(ENVIO_DIR));

        // `Path::join` returns the right-hand side verbatim when it's
        // absolute, so this works for both absolute (`/repo/project/config.yaml`)
        // and relative (`config.yaml`, `subdir/cfg.yaml`) inputs. Lexical
        // normalization resolves any `..` so the containment check below
        // covers `foo/../../config.yaml` and similar escapes.
        let config_joined = project_root.join(config);
        let config = path_utils::normalize_path(config_joined);
        let normalized_root = path_utils::normalize_path(project_root.clone());

        // `diff_paths(config, root)` returns the path from root → config.
        // If that path starts with `..`, the config sits outside the project
        // root regardless of whether the inputs were absolute or relative.
        let escapes_root = pathdiff::diff_paths(&config, &normalized_root)
            .map(|rel| rel.starts_with(".."))
            .unwrap_or(true);
        if escapes_root {
            return Err(anyhow!(
                "Config path must be in project directory (got `{}`, project root `{}`)",
                config.display(),
                normalized_root.display(),
            ));
        }

        Ok(ParsedProjectPaths {
            project_root,
            envio_dir,
            config,
        })
    }

    pub fn default_with_root(project_root: &str) -> anyhow::Result<ParsedProjectPaths> {
        Self::new(project_root, DEFAULT_CONFIG_PATH)
    }

    /// Path to the codegen-emitted `.envio/types.d.ts` file.
    pub fn envio_types_dts(&self) -> PathBuf {
        self.envio_dir.join(ENVIO_TYPES_FILE)
    }

    /// Path to the user-facing `envio-env.d.ts` glue file at the project root.
    pub fn envio_env_dts(&self) -> PathBuf {
        self.project_root.join(ENVIO_ENV_DTS_FILE)
    }
}

impl Default for ParsedProjectPaths {
    fn default() -> Self {
        Self::new(DEFAULT_PROJECT_ROOT_PATH, DEFAULT_CONFIG_PATH)
            .expect("Unexpected failure initializing default parsed paths")
    }
}

impl TryFrom<ProjectPaths> for ParsedProjectPaths {
    type Error = anyhow::Error;
    fn try_from(project_paths: ProjectPaths) -> Result<Self, Self::Error> {
        let project_root = project_paths
            .directory
            .unwrap_or_else(|| DEFAULT_PROJECT_ROOT_PATH.to_string());

        Self::new(&project_root, &project_paths.config)
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
            envio_dir: PathBuf::from(".envio"),
        };
        assert_eq!(expected_project_paths, project_paths,)
    }
    #[test]
    fn test_project_path_alternative_case() {
        let project_root = "my_dir/my_project";
        let config = "custom_config.yaml";
        let project_paths = ParsedProjectPaths::new(project_root, config).unwrap();

        let expected_project_paths = ParsedProjectPaths {
            project_root: PathBuf::from("my_dir/my_project/"),
            config: PathBuf::from("my_dir/my_project/custom_config.yaml"),
            envio_dir: PathBuf::from("my_dir/my_project/.envio"),
        };
        assert_eq!(expected_project_paths, project_paths,)
    }
    #[test]
    fn test_project_path_relative_case() {
        let project_root = "../my_dir/my_project";
        let config = "custom_config.yaml";
        let project_paths = ParsedProjectPaths::new(project_root, config).unwrap();

        let expected_project_paths = ParsedProjectPaths {
            project_root: PathBuf::from("../my_dir/my_project/"),
            config: PathBuf::from("../my_dir/my_project/custom_config.yaml"),
            envio_dir: PathBuf::from("../my_dir/my_project/.envio"),
        };
        assert_eq!(expected_project_paths, project_paths)
    }

    #[test]
    #[should_panic]
    fn test_project_path_panics_when_config_is_outside_of_root() {
        let project_root = "./";
        let config = "../config.yaml";
        ParsedProjectPaths::new(project_root, config).unwrap();
    }

    #[test]
    #[should_panic]
    fn test_project_path_rejects_nested_parent_dir_escape() {
        // `foo/../../config.yaml` lexically resolves to `../config.yaml`,
        // which is outside the project root.
        ParsedProjectPaths::new("./", "foo/../../config.yaml").unwrap();
    }

    #[test]
    fn test_project_path_accepts_absolute_config_inside_root() {
        // Scripted invocations may pass an absolute `--config` / `ENVIO_CONFIG`
        // pointing inside the project tree.
        let paths = ParsedProjectPaths::new("/repo/project", "/repo/project/config.yaml").unwrap();
        assert_eq!(paths.config, PathBuf::from("/repo/project/config.yaml"));
    }

    #[test]
    #[should_panic]
    fn test_project_path_rejects_absolute_config_outside_root() {
        ParsedProjectPaths::new("/repo/project", "/etc/passwd").unwrap();
    }

    #[test]
    fn check_default_does_not_panic() {
        ParsedProjectPaths::default();
    }
}
