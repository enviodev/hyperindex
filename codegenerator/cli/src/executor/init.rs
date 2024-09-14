use crate::{
    cli_args::{
        clap_definitions::{InitArgs, ProjectPaths},
        init_config::{self, Ecosystem, Language},
        interactive_init::prompt_missing_init_args,
    },
    commands,
    config_parsing::{
        entity_parsing::Schema, graph_migration::generate_config_from_subgraph_id,
        system_config::SystemConfig,
    },
    hbs_templating::{
        contract_import_templates, hbs_dir_generator::HandleBarsDirGenerator,
        init_templates::InitTemplates,
    },
    project_paths::ParsedProjectPaths,
    template_dirs::TemplateDirs,
    utils::file_system,
};
use anyhow::{anyhow, Context, Result};
use regex::Regex;
use std::{env, path::PathBuf};

//Validates version name (3 digits separated by period ".")
//Returns false if there are any additional chars as this should imply
//it is a dev release version or an unstable release
fn is_valid_release_version_number(version: &str) -> bool {
    let re_version_pattern = Regex::new(r"^\d+\.\d+\.\d+(-rc\.\d+)?$")
        .expect("version regex pattern should be valid regex");
    re_version_pattern.is_match(version)
}

pub async fn run_init_args(init_args: InitArgs, project_paths: &ProjectPaths) -> Result<()> {
    let template_dirs = TemplateDirs::new();
    //get_init_args_interactive opens an interactive cli for required args to be selected
    //if they haven't already been
    let init_config = prompt_missing_init_args(init_args, project_paths)
        .await
        .context("Failed during interactive input")?;

    let parsed_project_paths = ParsedProjectPaths::try_from(init_config.clone())
        .context("Failed parsing paths from interactive input")?;
    // The cli errors if the folder exists, the user must provide a new folder to proceed which we create below
    std::fs::create_dir_all(&parsed_project_paths.project_root)?;

    match &init_config.ecosystem {
        Ecosystem::Fuel {
            init_flow: init_config::fuel::InitFlow::Template(template),
        } => {
            template_dirs
                .get_and_extract_template(
                    template,
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing Fuel template {} with language {} at path {:?}",
                    &template, &init_config.language, &parsed_project_paths.project_root,
                ))?;
        }
        Ecosystem::Evm {
            init_flow: init_config::evm::InitFlow::Template(template),
        } => {
            template_dirs
                .get_and_extract_template(
                    template,
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing Evm template {} with language {} at path {:?}",
                    &template, &init_config.language, &parsed_project_paths.project_root,
                ))?;
        }
        Ecosystem::Evm {
            init_flow: init_config::evm::InitFlow::SubgraphID(cid),
        } => {
            template_dirs
                .get_and_extract_blank_template(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Subgraph Migration with language {} \
                     at path {:?}",
                    &init_config.language, &parsed_project_paths.project_root,
                ))?;

            let evm_config = generate_config_from_subgraph_id(
                &parsed_project_paths.project_root,
                cid,
                &init_config.language,
            )
            .await
            .context("Failed generating config from subgraph")?;

            let system_config =
                SystemConfig::from_evm_config(evm_config, Schema::empty(), &parsed_project_paths)
                    .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(
                    system_config,
                    &init_config.language,
                    init_config.api_token.clone(),
                )
                .context("Failed converting config to auto auto_schema_handler_template")?;

            auto_schema_handler_template
                .generate_subgraph_migration_templates(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context("Failed generating subgraph migration templates for event handlers.")?;
        }

        Ecosystem::Fuel {
            init_flow: init_config::fuel::InitFlow::ContractImport(contract_import_selection),
        } => {
            let fuel_config = contract_import_selection.to_human_config(&init_config);

            // TODO: Allow parsed paths to not depend on a written config.yaml file in file system
            file_system::write_file_string_to_system(
                fuel_config.to_string(),
                parsed_project_paths.project_root.join("config.yaml"),
            )
            .await
            .context("Failed writing imported config.yaml")?;

            for selected_contract in &contract_import_selection.contracts {
                file_system::write_file_string_to_system(
                    selected_contract.abi.raw.clone(),
                    parsed_project_paths
                        .project_root
                        .join(selected_contract.get_vendored_abi_file_path()),
                )
                .await
                .context(format!(
                    "Failed vendoring ABI file for {} contract",
                    selected_contract.name
                ))?;
            }

            //Use an empty schema config to generate auto_schema_handler_template
            //After it's been generated, the schema exists and codegen can parse it/use it
            let system_config =
                SystemConfig::from_fuel_config(fuel_config, Schema::empty(), &parsed_project_paths)
                    .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(
                    system_config,
                    &init_config.language,
                    init_config.api_token.clone(),
                )
                .context("Failed converting config to auto auto_schema_handler_template")?;

            template_dirs
                .get_and_extract_blank_template(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Contract Import with language {} at \
                     path {:?}",
                    &init_config.language, &parsed_project_paths.project_root,
                ))?;

            auto_schema_handler_template
                .generate_contract_import_templates(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(
                    "Failed generating contract import templates for schema and event handlers.",
                )?;
        }

        Ecosystem::Evm {
            init_flow: init_config::evm::InitFlow::ContractImport(auto_config_selection),
        } => {
            let evm_config = auto_config_selection
                .to_human_config(&init_config)
                .context("Failed to converting auto config selection into config.yaml")?;

            // TODO: Allow parsed paths to not depend on a written config.yaml file in file system
            file_system::write_file_string_to_system(
                evm_config.to_string(),
                parsed_project_paths.project_root.join("config.yaml"),
            )
            .await
            .context("failed writing imported config.yaml")?;

            //Use an empty schema config to generate auto_schema_handler_template
            //After it's been generated, the schema exists and codegen can parse it/use it
            let system_config =
                SystemConfig::from_evm_config(evm_config, Schema::empty(), &parsed_project_paths)
                    .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(
                    system_config,
                    &init_config.language,
                    init_config.api_token.clone(),
                )
                .context("Failed converting config to auto auto_schema_handler_template")?;

            template_dirs
                .get_and_extract_blank_template(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Contract Import with language {} at \
                     path {:?}",
                    &init_config.language, &parsed_project_paths.project_root,
                ))?;

            auto_schema_handler_template
                .generate_contract_import_templates(
                    &init_config.language,
                    &parsed_project_paths.project_root,
                )
                .context(
                    "Failed generating contract import templates for schema and event handlers.",
                )?;
        }
    }

    let envio_version = {
        let crate_version = env!("CARGO_PKG_VERSION");
        if is_valid_release_version_number(crate_version) {
            // Check that crate version is not a dev release. In which case the
            // version should be installable from npm
            crate_version.to_string()
        } else {
            // Else install the local version for development and testing
            match env::current_exe() {
                // This should be something like "~/envio/hyperindex/codegenerator/target/debug/envio"
                Ok(exe_path) => exe_path
                    .to_string_lossy()
                    .replace("/target/debug/envio", "/cli/npm/envio"),
                Err(e) => return Err(anyhow!("failed to get current exe path: {e}")),
            }
        }
    };

    let hbs_template = InitTemplates::new(
        init_config.name.clone(),
        &init_config.language,
        &parsed_project_paths,
        envio_version.clone(),
        init_config.api_token,
    )
    .context("Failed creating init templates")?;

    let init_shared_template_dir = template_dirs.get_init_template_dynamic_shared()?;

    let hbs_generator = HandleBarsDirGenerator::new(
        &init_shared_template_dir,
        &hbs_template,
        &parsed_project_paths.project_root,
    );

    hbs_generator.generate_hbs_templates()?;

    println!("Project template ready");
    println!("Running codegen");

    match init_config.ecosystem {
        Ecosystem::Fuel { .. } => {
            commands::codegen::npx_codegen(envio_version, &parsed_project_paths).await?
        }
        Ecosystem::Evm { .. } => {
            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;

            commands::codegen::run_codegen(&config, &parsed_project_paths).await?;
        }
    };

    if init_config.language == Language::ReScript {
        let res_build_exit = commands::rescript::build(&parsed_project_paths.project_root).await?;
        if !res_build_exit.success() {
            return Err(anyhow!("Failed to build rescript"))?;
        }
    }

    // If the project directory is not the current directory, print a message for user to cd into it
    if parsed_project_paths.project_root != PathBuf::from(".") {
        println!(
            "Please run `cd {}` to run the rest of the envio commands",
            parsed_project_paths.project_root.to_str().unwrap_or("")
        );
    }

    Ok(())
}

#[cfg(test)]
mod test {

    #[test]
    fn test_valid_version_numbers() {
        let valid_version_numbers = vec!["0.0.0", "999.999.999", "0.0.1", "10.2.3", "2.0.0-rc.1"];

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
}
