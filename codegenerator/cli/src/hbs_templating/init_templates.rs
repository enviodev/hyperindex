use crate::{
    cli_args::clap_definitions::Language,
    project_paths::{path_utils::add_leading_relative_dot, ParsedProjectPaths},
};
use anyhow::{anyhow, Context};
use pathdiff::diff_paths;
use regex::Regex;
use serde::Serialize;
use std::path::PathBuf;

#[derive(Serialize, Debug, PartialEq)]
pub struct InitTemplates {
    project_name: String,
    is_rescript: bool,
    is_typescript: bool,
    is_javascript: bool,
    envio_version: String,
    //Used for the package.json reference to generated in handlers
    relative_path_from_root_to_generated: String,
}

impl InitTemplates {
    pub fn new(
        project_name: String,
        lang: &Language,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<Self> {
        let crate_version = env!("CARGO_PKG_VERSION");

        let envio_version = if is_valid_release_version_number(crate_version) {
            //Check that crate version is not a dev release. In which case the
            //version should be installable from npm
            crate_version.to_string()
        } else {
            //Else install the latest version from npm so as not to break dev environments
            "latest".to_string()
        };

        //Take the absolute paths of  project root and generated, diff them to get
        //relative path from root to generated and add a leading dot. So in a default project, if your
        //generated folder is at root folder "generated". Then this should output ./generated
        //Or say its at "artifact/generated" you should get "./artifacts/generated" etc
        //Used for the package.json reference to generated in handlers
        let diff_from_current = |path: &PathBuf, base: &PathBuf| -> anyhow::Result<String> {
            Ok(add_leading_relative_dot(
                diff_paths(path, base)
                    .ok_or_else(|| anyhow!("Failed to diffing paths {:?} and {:?}", path, base))?,
            )
            .to_str()
            .ok_or_else(|| anyhow!("Failed converting path to str"))?
            .to_string())
        };
        let relative_path_from_root_to_generated =
            diff_from_current(&project_paths.generated, &project_paths.project_root)
                .context("Failed to diff generated from root path")?;
        let template = InitTemplates {
            project_name,
            is_rescript: lang == &Language::Rescript,
            is_typescript: lang == &Language::Typescript,
            is_javascript: lang == &Language::Javascript,
            envio_version,
            relative_path_from_root_to_generated,
        };

        Ok(template)
    }
}

//Validates version name (3 digits separated by period ".")
//Returns false if there are any additional chars as this should imply
//it is a dev release version or an unstable release
fn is_valid_release_version_number(version: &str) -> bool {
    let re_version_pattern =
        Regex::new(r"^\d+\.\d+\.\d+$").expect("version regex pattern should be valid regex");
    re_version_pattern.is_match(version)
}

#[cfg(test)]
mod test {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_valid_version_numbers() {
        let valid_version_numbers = vec!["0.0.0", "999.999.999", "0.0.1", "10.2.3"];

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
    fn test_new_init_template() {
        let init_temp = InitTemplates::new(
            "my-project".to_string(),
            &Language::Rescript,
            &ParsedProjectPaths::default(),
        )
        .unwrap();

        let expected = InitTemplates {
            project_name: "my-project".to_string(),
            is_rescript: true,
            is_typescript: false,
            is_javascript: false,
            envio_version: "latest".to_string(),
            relative_path_from_root_to_generated: "./generated".to_string(),
        };

        assert_eq!(expected, init_temp);
    }
}
