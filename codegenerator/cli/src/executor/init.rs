use crate::{
    cli_args::{
        clap_definitions::{InitArgs, Language, ProjectPaths},
        interactive_init::InitilizationTypeWithArgs,
    },
    commands,
    config_parsing::{
        entity_parsing::Schema, graph_migration::generate_config_from_subgraph_id, human_config,
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
use std::path::PathBuf;

pub async fn run_init_args(init_args: &InitArgs, project_paths: &ProjectPaths) -> Result<()> {
    let template_dirs = TemplateDirs::new();
    //get_init_args_interactive opens an interactive cli for required args to be selected
    //if they haven't already been
    let parsed_init_args = init_args
        .get_init_args_interactive(project_paths)
        .await
        .context("Failed during interactive input")?;

    let parsed_project_paths = ParsedProjectPaths::try_from(parsed_init_args.clone())
        .context("Failed parsing paths from interactive input")?;
    // The cli errors if the folder exists, the user must provide a new folder to proceed which we create below
    std::fs::create_dir_all(&parsed_project_paths.project_root)?;

    match &parsed_init_args.template {
        InitilizationTypeWithArgs::Template(template) => {
            template_dirs
                .get_and_extract_template(
                    &template,
                    &parsed_init_args.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing with template {} with language {} at path {:?}",
                    &template, &parsed_init_args.language, &parsed_project_paths.project_root,
                ))?;
        }
        InitilizationTypeWithArgs::SubgraphID(cid) => {
            template_dirs
                .get_and_extract_blank_template(
                    &parsed_init_args.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Subgraph Migration with language {} \
                     at path {:?}",
                    &parsed_init_args.language, &parsed_project_paths.project_root,
                ))?;

            let yaml_config = generate_config_from_subgraph_id(
                &parsed_project_paths.project_root,
                cid,
                &parsed_init_args.language,
            )
            .await
            .context("Failed generating config from subgraph")?;

            let parsed_config = SystemConfig::parse_from_human_cfg_with_schema(
                &yaml_config,
                Schema::empty(),
                &parsed_project_paths,
            )
            .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(parsed_config)
                    .context("Failed converting config to auto auto_schema_handler_template")?;

            auto_schema_handler_template
                .generate_subgraph_migration_templates(
                    &parsed_init_args.language,
                    &parsed_project_paths.project_root,
                )
                .context("Failed generating subgraph migration templates for event handlers.")?;
        }

        InitilizationTypeWithArgs::ContractImportWithArgs(auto_config_selection) => {
            let yaml_config = auto_config_selection
                .clone()
                .try_into()
                .context("Failed to converting auto config selection into config.yaml")?;

            let serialized_config =
                serde_yaml::to_string(&yaml_config).context("Failed serializing config")?;

            //TODO: Allow parsed paths to not depend on a written config.yaml file in file system
            file_system::write_file_string_to_system(
                serialized_config,
                parsed_project_paths.project_root.join("config.yaml"),
            )
            .await
            .context("failed writing imported config.yaml")?;

            //Use an empty schema config to generate auto_schema_handler_template
            //After it's been generated, the schema exists and codegen can parse it/use it
            let parsed_config = SystemConfig::parse_from_human_cfg_with_schema(
                &yaml_config,
                Schema::empty(),
                &parsed_project_paths,
            )
            .context("Failed parsing config")?;

            let auto_schema_handler_template =
                contract_import_templates::AutoSchemaHandlerTemplate::try_from(parsed_config)
                    .context("Failed converting config to auto auto_schema_handler_template")?;

            template_dirs
                .get_and_extract_blank_template(
                    &parsed_init_args.language,
                    &parsed_project_paths.project_root,
                )
                .context(format!(
                    "Failed initializing blank template for Contract Import with language {} at \
                     path {:?}",
                    &parsed_init_args.language, &parsed_project_paths.project_root,
                ))?;

            auto_schema_handler_template
                .generate_contract_import_templates(
                    &parsed_init_args.language,
                    &parsed_project_paths.project_root,
                )
                .context(
                    "Failed generating contract import templates for schema and event handlers.",
                )?;
        }
    }

    let hbs_template =
        InitTemplates::new(parsed_init_args.name.clone(), &parsed_init_args.language);

    let init_shared_template_dir = template_dirs.get_init_template_dynamic_shared()?;

    let hbs_generator = HandleBarsDirGenerator::new(
        &init_shared_template_dir,
        &hbs_template,
        &parsed_project_paths.project_root,
    );

    hbs_generator.generate_hbs_templates()?;

    println!("Project template ready");
    println!("Running codegen");

    let yaml_config = human_config::deserialize_config_from_yaml(&parsed_project_paths.config)
        .context("Failed deserializing config")?;

    let config = SystemConfig::parse_from_human_config(&yaml_config, &parsed_project_paths)
        .context("Failed parsing config")?;

    commands::codegen::run_codegen(&config, &parsed_project_paths).await?;

    let post_codegen_exit =
        commands::codegen::run_post_codegen_command_sequence(&parsed_project_paths).await?;

    if !post_codegen_exit.success() {
        return Err(anyhow!("Failed to complete post codegen command sequence"))?;
    }

    if parsed_init_args.language == Language::Rescript {
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
