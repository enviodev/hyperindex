use crate::{
    cli_args::{
        clap_definitions::{InitArgs, ProjectPaths},
        init_config::{self, Ecosystem, Language},
        interactive_init::prompt_missing_init_args,
    },
    commands,
    config_parsing::{
        entity_parsing::Schema,
        graph_migration::generate_config_from_subgraph_id,
        human_config::HumanConfig,
        system_config::{get_envio_version, SystemConfig},
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

use std::path::PathBuf;

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

            let system_config = SystemConfig::from_human_config(
                HumanConfig::Evm(evm_config),
                Schema::empty(),
                &parsed_project_paths,
            )
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
            let system_config = SystemConfig::from_human_config(
                HumanConfig::Fuel(fuel_config),
                Schema::empty(),
                &parsed_project_paths,
            )
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
            let system_config = SystemConfig::from_human_config(
                HumanConfig::Evm(evm_config),
                Schema::empty(),
                &parsed_project_paths,
            )
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

    let envio_version = get_envio_version()?;

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

    let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
        .context("Failed parsing config")?;

    commands::codegen::run_codegen(&config).await?;

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
