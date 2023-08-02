use std::error::Error;

use std::path::PathBuf;

use clap::Parser;

use envio::{
    cli_args::{
        interactive_init::TemplateOrSubgraphID, CommandLineArgs, CommandType, DbMigrateSubcommands,
        DevSubcommands, Language, LocalCommandTypes, LocalDockerSubcommands, ProjectPathsArgs,
        Template, ToProjectPathsArgs,
    },
    commands,
    config_parsing::graph_migration::generate_config_from_subgraph_id,
    hbs_templating::{hbs_dir_generator::HandleBarsDirGenerator, init_templates::InitTemplates},
    persisted_state::{
        check_user_file_diff_match, persisted_state_file_exists, ExistingPersistedState,
        PersistedState, RerunOptions,
    },
    project_paths::ParsedPaths,
    service_health,
};

use include_dir::{include_dir, Dir};

static BLANK_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/shared");
static BLANK_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/rescript");
static BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/typescript");
static BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/blank_template/javascript");
static BLANK_TEMPLATE_DYNAMIC_DIR: Dir<'_> = include_dir!("templates/dynamic/blank_template");
static GREETER_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/shared");
static GREETER_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/rescript");
static GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/typescript");
static GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/greeter_template/javascript");
static ERC20_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/shared");
static ERC20_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/rescript");
static ERC20_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/typescript");
static ERC20_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/erc20_template/javascript");
static INIT_TEMPLATES_SHARED_DIR: Dir<'_> = include_dir!("templates/dynamic/init_templates/shared");

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let command_line_args = CommandLineArgs::parse();

    match command_line_args.command {
        CommandType::Init(init_args) => {
            //get_init_args_interactive opens an interactive cli for required args to be selected
            //if they haven't already been
            let args = init_args.get_init_args_interactive()?;
            let project_root_path = PathBuf::from(&args.directory);
            // check that project_root_path exists

            let hbs_template = InitTemplates::new(args.name, &args.language);
            let hbs_generator = HandleBarsDirGenerator::new(
                &INIT_TEMPLATES_SHARED_DIR,
                &hbs_template,
                &project_root_path,
            );

            match args.template {
                TemplateOrSubgraphID::Template(template) => match template {
                    Template::Blank => {
                        //Copy in the relevant language specific blank template files
                        match &args.language {
                            Language::Rescript => {
                                BLANK_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                            }
                            Language::Typescript => {
                                BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                            }
                            Language::Javascript => {
                                BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
                            }
                        }
                        //Copy in the rest of the shared blank template files
                        BLANK_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                        hbs_generator.generate_hbs_templates()?;
                        let hbs_config_file = HandleBarsDirGenerator::new(
                            &BLANK_TEMPLATE_DYNAMIC_DIR,
                            &hbs_template,
                            &project_root_path,
                        );

                        hbs_config_file.generate_hbs_templates()?;
                    }
                    Template::Greeter => {
                        //Copy in the relevant language specific greeter files
                        match &args.language {
                            Language::Rescript => {
                                GREETER_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                            }
                            Language::Typescript => {
                                GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR
                                    .extract(&project_root_path)?;
                            }
                            Language::Javascript => {
                                GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR
                                    .extract(&project_root_path)?;
                            }
                        }
                        //Copy in the rest of the shared greeter files
                        GREETER_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                    }
                    Template::Erc20 => {
                        //Copy in the relevant js flavor specific greeter files
                        match &args.language {
                            Language::Rescript => {
                                ERC20_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                            }
                            Language::Typescript => {
                                ERC20_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                            }
                            Language::Javascript => {
                                ERC20_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
                            }
                        }
                        //Copy in the rest of the shared greeter files
                        ERC20_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                    }
                },
                TemplateOrSubgraphID::SubgraphID(cid) => {
                    //  Copy in the relevant js flavor specific subgraph migration files
                    match &args.language {
                        Language::Rescript => {
                            BLANK_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Typescript => {
                            BLANK_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        Language::Javascript => {
                            BLANK_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
                        }
                    }
                    //Copy in the rest of the shared subgraph migration files
                    BLANK_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;

                    generate_config_from_subgraph_id(&project_root_path, &cid, &args.language)
                        .await?;
                }
            }

            println!("Project template ready");
            println!("Running codegen");

            let parsed_paths = ParsedPaths::new(init_args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            commands::codegen::run_codegen(&parsed_paths)?;
            commands::codegen::run_post_codegen_command_sequence(&project_paths)?;
            Ok(())
        }

        CommandType::Codegen(args) => {
            let parsed_paths = ParsedPaths::new(args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            commands::codegen::run_codegen(&parsed_paths)?;
            commands::codegen::run_post_codegen_command_sequence(project_paths)?;
            Ok(())
        }

        // todo: go through Jono's commands to validate what he's trying to achieve with the persisted state
        // todo: make the subcommands with clap optional
        CommandType::Dev(dev_subcommands) => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;
            match dev_subcommands {
                DevSubcommands::Stop => {
                    commands::docker::docker_compose_down_v(project_paths)?;
                }
                DevSubcommands::Restart => {
                    commands::docker::docker_compose_down_v(project_paths)?;
                    commands::docker::docker_compose_up_d(project_paths)?;
                    let hasura_ready_result =
                        service_health::fetch_hasura_healthz_with_retry().await;
                    match hasura_ready_result {
                        Ok(_) => {
                            commands::db_migrate::run_db_setup(project_paths)?;
                            commands::start::start_indexer(project_paths)?;
                        }
                        Err(e) => {
                            println!("Failed to connect to hasura: {}", e);
                        }
                    }
                }
                DevSubcommands::Dev => {
                    commands::docker::docker_compose_up_d(project_paths)?;
                    let hasura_ready_result =
                        service_health::fetch_hasura_healthz_with_retry().await;
                    match hasura_ready_result {
                        Ok(_) => {
                            commands::db_migrate::run_db_setup(project_paths)?;
                            commands::start::start_indexer(project_paths)?;
                        }
                        Err(e) => {
                            println!("Failed to connect to hasura: {}", e);
                        }
                    }
                }
            }

            Ok(())
        }

        CommandType::Start(start_args) => {
            let parsed_paths = ParsedPaths::new(start_args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;

            let existing_persisted_state = if persisted_state_file_exists(&project_paths) {
                let persisted_state = PersistedState::get_from_generated_file(project_paths)?;
                ExistingPersistedState::ExistingFile(persisted_state)
            } else {
                ExistingPersistedState::NoFile
            };

            match check_user_file_diff_match(&existing_persisted_state, &parsed_paths)? {
                RerunOptions::CodegenAndSyncFromRpc => {
                    commands::codegen::run_codegen(&parsed_paths)?;
                    commands::codegen::run_post_codegen_command_sequence(
                        &parsed_paths.project_paths,
                    )?;
                    commands::db_migrate::run_db_setup(project_paths)?;
                }
                RerunOptions::CodegenAndResyncFromStoredEvents => {
                    //TODO: Implement command for rerunning from stored events
                    //and action from this match arm
                    commands::codegen::run_codegen(&parsed_paths)?;
                    commands::codegen::run_post_codegen_command_sequence(
                        &parsed_paths.project_paths,
                    )?;
                    commands::db_migrate::run_db_setup(project_paths)?;
                }
                RerunOptions::ResyncFromStoredEvents => {
                    //TODO: Implement command for rerunning from stored events
                    //and action from this match arm
                    commands::db_migrate::run_db_setup(project_paths)?;
                }
                RerunOptions::ContinueSync => {
                    let has_run_db_migrations = match existing_persisted_state {
                        ExistingPersistedState::NoFile => false,
                        ExistingPersistedState::ExistingFile(ps) => ps.has_run_db_migrations,
                    };
                    if start_args.restart || !has_run_db_migrations {
                        commands::db_migrate::run_db_setup(project_paths)?;
                    }
                }
            }

            commands::start::start_indexer(project_paths)?;
            Ok(())
        }

        CommandType::Local(local_commands) => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;
            match local_commands {
                LocalCommandTypes::Docker(subcommand) => match subcommand {
                    LocalDockerSubcommands::Up => {
                        commands::docker::docker_compose_up_d(project_paths)?;
                    }
                    LocalDockerSubcommands::Down => {
                        commands::docker::docker_compose_down_v(project_paths)?;
                    }
                },
                LocalCommandTypes::DbMigrate(subcommand) => match subcommand {
                    DbMigrateSubcommands::Up => {
                        commands::db_migrate::run_up_migrations(project_paths)?;
                    }

                    DbMigrateSubcommands::Down => {
                        commands::db_migrate::run_drop_schema(project_paths)?;
                    }

                    DbMigrateSubcommands::Setup => {
                        commands::db_migrate::run_db_setup(project_paths)?;
                    }
                },
            }
            Ok(())
        }

        CommandType::PrintAllHelp {} => {
            clap_markdown::print_help_markdown::<CommandLineArgs>();
            Ok(())
        }
    }
}
