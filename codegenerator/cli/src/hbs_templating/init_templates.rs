use crate::{
    cli_args::init_config::Language,
    package_manager::PackageManagerConfig,
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
    envio_version: String,
    //Used for the package.json reference to generated in handlers
    relative_path_from_root_to_generated: String,
    envio_api_token: Option<String>,
    // Package manager and runtime info for templates
    package_manager: String,
    is_bun_runtime: bool,
    // Package manager run prefix: "npm run ", "yarn ", "pnpm ", or "bun run "
    pm_run_prefix: String,
}

impl InitTemplates {
    pub fn new(
        project_name: String,
        lang: &Language,
        project_paths: &ParsedProjectPaths,
        envio_version: String,
        envio_api_token: Option<String>,
        pm_config: &PackageManagerConfig,
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
            envio_version,
            relative_path_from_root_to_generated,
            envio_api_token,
            package_manager: pm_config.package_manager.command().to_string(),
            is_bun_runtime: pm_config.is_bun_runtime(),
            pm_run_prefix: pm_config.run_script_prefix().to_string(),
        };

        Ok(template)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use crate::package_manager::PackageManager;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_new_init_template() {
        let pm_config = PackageManagerConfig::new(PackageManager::Npm);
        let init_temp = InitTemplates::new(
            "my-project".to_string(),
            &Language::ReScript,
            &ParsedProjectPaths::default(),
            "latest".to_string(),
            None,
            &pm_config,
        )
        .unwrap();

        let expected = InitTemplates {
            project_name: "my-project".to_string(),
            is_rescript: true,
            is_typescript: false,
            envio_version: "latest".to_string(),
            relative_path_from_root_to_generated: "./generated".to_string(),
            envio_api_token: None,
            package_manager: "npm".to_string(),
            is_bun_runtime: false,
            pm_run_prefix: "npm run ".to_string(),
        };

        assert_eq!(expected, init_temp);
    }
}
