use std::{
    // collections:HashMap,
    error::Error,
    path::{Component, PathBuf},
};

use crate::cli_args::{ProjectPathsArgs, ToProjectPathsArgs};

pub mod handler_paths;
pub use handler_paths::ParsedPaths;
pub mod path_utils;

#[derive(Debug, PartialEq)]
pub struct ProjectPaths {
    pub project_root: PathBuf,
    pub config: PathBuf,
    pub generated: PathBuf,
}

impl ProjectPaths {
    pub fn new(project_paths_args: ProjectPathsArgs) -> Result<ProjectPaths, Box<dyn Error>> {
        let project_root = PathBuf::from(project_paths_args.project_root);
        let generated_relative_path = PathBuf::from(&project_paths_args.generated);
        if let Some(Component::ParentDir) = generated_relative_path.components().peekable().peek() {
            return Err("Generated folder must be in project directory".into());
        }
        let generated_joined: PathBuf = project_root.join(generated_relative_path);
        let generated = path_utils::normalize_path(&generated_joined);

        let config_relative_path = PathBuf::from(&project_paths_args.config);
        if let Some(Component::ParentDir) = config_relative_path.components().peekable().peek() {
            return Err("Config path must be in project directory".into());
        }

        let config_joined: PathBuf = project_root.join(config_relative_path);
        let config = path_utils::normalize_path(&config_joined);

        Ok(ProjectPaths {
            project_root,
            generated,
            config,
        })
    }
}

impl ToProjectPathsArgs for ProjectPaths {
    fn to_project_paths_args(&self) -> ProjectPathsArgs {
        let pathbuf_to_string = |path: &PathBuf| {
            path.to_str()
                .expect("project path should be convertable to a string")
                .to_string()
        };

        ProjectPathsArgs {
            project_root: pathbuf_to_string(&self.project_root),
            generated: pathbuf_to_string(&self.generated),
            config: pathbuf_to_string(&self.config),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ProjectPaths;
    use crate::cli_args::ProjectPathsArgs;
    use std::path::PathBuf;
    #[test]
    fn test_project_path_default_case() {
        let project_root = String::from("./");
        let config = String::from("config.yaml");
        let generated = String::from("generated/");
        let project_paths = ProjectPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let expected_project_paths = ProjectPaths {
            project_root: PathBuf::from("./"),
            config: PathBuf::from("config.yaml"),
            generated: PathBuf::from("generated"),
        };
        assert_eq!(expected_project_paths, project_paths,)
    }
    #[test]
    fn test_project_path_alternative_case() {
        let project_root = String::from("my_dir/my_project");
        let config = String::from("custom_config.yaml");
        let generated = String::from("custom_gen/my_project_generated");
        let project_paths = ProjectPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let expected_project_paths = ProjectPaths {
            project_root: PathBuf::from("my_dir/my_project/"),
            config: PathBuf::from("my_dir/my_project/custom_config.yaml"),

            generated: PathBuf::from("my_dir/my_project/custom_gen/my_project_generated"),
        };
        assert_eq!(expected_project_paths, project_paths,)
    }
    #[test]
    fn test_project_path_relative_case() {
        let project_root = String::from("../my_dir/my_project");
        let config = String::from("custom_config.yaml");
        let generated = String::from("custom_gen/my_project_generated");
        let project_paths = ProjectPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();

        let expected_project_paths = ProjectPaths {
            project_root: PathBuf::from("../my_dir/my_project/"),
            config: PathBuf::from("../my_dir/my_project/custom_config.yaml"),
            generated: PathBuf::from("../my_dir/my_project/custom_gen/my_project_generated"),
        };
        assert_eq!(expected_project_paths, project_paths)
    }

    #[test]
    #[should_panic]
    fn test_project_path_panics_when_generated_is_outside_of_root() {
        let project_root = String::from("./");
        let config = String::from("config.yaml");
        let generated = String::from("../generated/");
        ProjectPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();
    }

    #[test]
    #[should_panic]
    fn test_project_path_panics_when_config_is_outside_of_root() {
        let project_root = String::from("./");
        let config = String::from("../config.yaml");
        let generated = String::from("generated/");
        ProjectPaths::new(ProjectPathsArgs {
            project_root,
            config,
            generated,
        })
        .unwrap();
    }
}
