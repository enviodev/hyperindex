use crate::{
    cli_args::clap_definitions::Language,
    project_paths::{path_utils::add_leading_relative_dot, ParsedProjectPaths},
};
use anyhow::{anyhow, Context};
use pathdiff::diff_paths;
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
        envio_version: String,
    ) -> anyhow::Result<Self> {
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
            is_rescript: lang == &Language::ReScript,
            is_typescript: lang == &Language::TypeScript,
            is_javascript: lang == &Language::JavaScript,
            envio_version,
            relative_path_from_root_to_generated,
        };

        Ok(template)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_new_init_template() {
        let init_temp = InitTemplates::new(
            "my-project".to_string(),
            &Language::ReScript,
            &ParsedProjectPaths::default(),
            "latest".to_string(),
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
