use crate::{
    cli_args::{
        interactive_init::InitilizationTypeWithArgs, InitArgs, Language, ProjectPaths, Template,
    },
    commands,
    config_parsing::{
        contract_import::{self, generate_config_from_contract_address},
        entity_parsing::Schema,
        graph_migration::generate_config_from_subgraph_id,
        human_config,
        system_config::SystemConfig,
    },
    hbs_templating::{
        contract_import_templates, hbs_dir_generator::HandleBarsDirGenerator,
        init_templates::InitTemplates,
    },
    project_paths::ParsedProjectPaths,
};
use anyhow::{anyhow, Context, Result};
use include_dir::{include_dir, Dir};
use std::path::PathBuf;

static BLANK_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/blank_template/shared");
static BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/blank_template/javascript");
static BLANK_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/blank_template/rescript");
static BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/blank_template/typescript");
static GREETER_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/greeter_template/shared");
static GREETER_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/greeter_template/rescript");
static GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/greeter_template/typescript");
static GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/greeter_template/javascript");
static ERC20_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/erc20_template/shared");
static ERC20_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/erc20_template/rescript");
static ERC20_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/erc20_template/typescript");
static ERC20_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/static/erc20_template/javascript");
static INIT_TEMPLATES_SHARED_DIR: Dir<'_> =
    include_dir!("$CARGO_MANIFEST_DIR/templates/dynamic/init_templates/shared");

pub async fn run_init_args(init_args: &InitArgs, project_paths: &ProjectPaths) -> Result<()> {
    //get_init_args_interactive opens an interactive cli for required args to be selected
    //if they haven't already been
    let parsed_init_args = init_args
        .get_init_args_interactive(project_paths)
        .context("Failed during interactive input")?;

    let parsed_project_paths = ParsedProjectPaths::try_from(parsed_init_args.clone())
        .context("Failed parsing paths from interactive input")?;
    // The cli errors if the folder exists, the user must provide a new folder to proceed which we create below
    std::fs::create_dir_all(&parsed_project_paths.project_root)?;

    let hbs_template =
        InitTemplates::new(parsed_init_args.name.clone(), &parsed_init_args.language);

    let hbs_generator = HandleBarsDirGenerator::new(
        &INIT_TEMPLATES_SHARED_DIR,
        &hbs_template,
        &parsed_project_paths.project_root,
    );

    match &parsed_init_args.template {
        InitilizationTypeWithArgs::Template(template) => match template {
            Template::Greeter => {
                //Copy in the relevant language specific greeter files
                match &parsed_init_args.language {
                    Language::Rescript => {
                        GREETER_TEMPLATE_STATIC_RESCRIPT_DIR
                            .extract(&parsed_project_paths.project_root)?;
                    }
                    Language::Typescript => {
                        GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR
                            .extract(&parsed_project_paths.project_root)?;
                    }
                    Language::Javascript => {
                        GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR
                            .extract(&parsed_project_paths.project_root)?;
                    }
                }
                //Copy in the rest of the shared greeter files
                GREETER_TEMPLATE_STATIC_SHARED_DIR.extract(&parsed_project_paths.project_root)?;
            }
            Template::Erc20 => {
                //Copy in the relevant js flavor specific greeter files
                match &parsed_init_args.language {
                    Language::Rescript => {
                        ERC20_TEMPLATE_STATIC_RESCRIPT_DIR
                            .extract(&parsed_project_paths.project_root)?;
                    }
                    Language::Typescript => {
                        ERC20_TEMPLATE_STATIC_TYPESCRIPT_DIR
                            .extract(&parsed_project_paths.project_root)?;
                    }
                    Language::Javascript => {
                        ERC20_TEMPLATE_STATIC_JAVASCRIPT_DIR
                            .extract(&parsed_project_paths.project_root)?;
                    }
                }
                //Copy in the rest of the shared greeter files
                ERC20_TEMPLATE_STATIC_SHARED_DIR.extract(&parsed_project_paths.project_root)?;
            }
        },
        InitilizationTypeWithArgs::SubgraphID(cid) => {
            //  Copy in the relevant js flavor specific subgraph migration files
            match &parsed_init_args.language {
                Language::Rescript => {
                    BLANK_TEMPLATE_STATIC_RESCRIPT_DIR
                        .extract(&parsed_project_paths.project_root)?;
                }
                Language::Typescript => {
                    BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR
                        .extract(&parsed_project_paths.project_root)?;
                }
                Language::Javascript => {
                    BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR
                        .extract(&parsed_project_paths.project_root)?;
                }
            }
            //Copy in the rest of the shared subgraph migration files
            BLANK_TEMPLATE_STATIC_SHARED_DIR.extract(&parsed_project_paths.project_root)?;

            generate_config_from_subgraph_id(
                &parsed_project_paths.project_root,
                cid,
                &parsed_init_args.language,
            )
            .await?;
        }

        InitilizationTypeWithArgs::ContractImportWithArgs(network_name, contract_address) => {
            let yaml_config = generate_config_from_contract_address(
                &parsed_init_args.name,
                network_name,
                contract_address.clone(),
                &parsed_init_args.language,
            )
            .await
            .context("Failed getting config")?;

            let serialized_config =
                serde_yaml::to_string(&yaml_config).context("Failed serializing config")?;

            //TODO: Allow parsed paths to not depend on a written config.yaml file in file system
            contract_import::write_file_to_system(
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

            //  Copy in the relevant js flavor specific subgraph migration files
            match &parsed_init_args.language {
                Language::Rescript => {
                    BLANK_TEMPLATE_STATIC_RESCRIPT_DIR
                        .extract(&parsed_project_paths.project_root)?;
                    auto_schema_handler_template
                        .generate_templates_rescript(&parsed_project_paths.project_root)
                        .context(
                            "Failed generating rescript templates for schema and event handlers.",
                        )?;
                }
                Language::Typescript => {
                    BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR
                        .extract(&parsed_project_paths.project_root)?;
                    auto_schema_handler_template
                        .generate_templates_typescript(&parsed_project_paths.project_root)
                        .context(
                            "Failed generating typescript templates for schema and event handlers.",
                        )?;
                }
                Language::Javascript => {
                    BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR
                        .extract(&parsed_project_paths.project_root)?;
                    auto_schema_handler_template
                        .generate_templates_javascript(&parsed_project_paths.project_root)
                        .context(
                            "Failed generating javascript templates for schema and event handlers.",
                        )?;
                }
            }
            //Copy in the rest of the shared subgraph migration files
            BLANK_TEMPLATE_STATIC_SHARED_DIR
                .extract(&parsed_project_paths.project_root)
                .context("Parsing contract address")?;
        }
    }

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
