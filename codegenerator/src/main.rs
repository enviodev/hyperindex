use std::error::Error;

use std::path::PathBuf;

use anyhow::{anyhow, Context};
use clap::Parser;

use envio::{
    cli_args::{
        interactive_init::TemplateOrSubgraphID, CommandLineArgs, CommandType, DbMigrateSubcommands,
        DevSubcommands, InitArgs, Language, LocalCommandTypes, LocalDockerSubcommands,
        ProjectPathsArgs, Template, ToProjectPathsArgs,
    },
    commands,
    config_parsing::graph_migration::generate_config_from_subgraph_id,
    hbs_templating::{hbs_dir_generator::HandleBarsDirGenerator, init_templates::InitTemplates},
    persisted_state::{
        check_user_file_diff_match, persisted_state_file_exists, ExistingPersistedState,
        PersistedState, RerunOptions,
    },
    project_paths::ParsedPaths,
    service_health::{self, HasuraHealth},
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

async fn run_init_args(init_args: &InitArgs) -> Result<(), Box<dyn Error>> {
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
                        GREETER_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                    }
                    Language::Javascript => {
                        GREETER_TEMPLATE_STATIC_JAVASCRIPT_DIR.extract(&project_root_path)?;
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

            generate_config_from_subgraph_id(&project_root_path, &cid, &args.language).await?;
        }
    }

    println!("Project template ready");
    println!("Running codegen");

    let parsed_paths = ParsedPaths::new(init_args.to_project_paths_args())?;
    let project_paths = &parsed_paths.project_paths;
    commands::codegen::run_codegen(&parsed_paths)?;
    commands::codegen::run_post_codegen_command_sequence(&project_paths).await?;
    Ok(())
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let command_line_args = CommandLineArgs::parse();

    match command_line_args.command {
        CommandType::Init(init_args) => {
            run_init_args(&init_args).await?;
            Ok(())
        }

        CommandType::Codegen(args) => {
            let parsed_paths = ParsedPaths::new(args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            commands::codegen::run_codegen(&parsed_paths)?;
            commands::codegen::run_post_codegen_command_sequence(project_paths).await?;
            Ok(())
        }

        CommandType::Dev(dev_subcommands) => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;

            match dev_subcommands.subcommands {
                None | Some(DevSubcommands::Restart) => {
                    // if hasura healhz check returns not found assume docker isnt running and start it up {
                    let hasura_health_check_is_error =
                        service_health::fetch_hasura_healthz().await.is_err();

                    if hasura_health_check_is_error {
                        //Run docker commands to spin up container
                        commands::docker::docker_compose_up_d(project_paths).await?;
                    }

                    let hasura_health = service_health::fetch_hasura_healthz_with_retry().await;

                    match hasura_health {
                        HasuraHealth::Unhealthy(err_message) => {
                            Err(anyhow!(err_message)).context("Failed to start hasura")?;
                        }
                        HasuraHealth::Healthy => {
                            {
                                let existing_persisted_state =
                                    if persisted_state_file_exists(&project_paths) {
                                        let persisted_state =
                                            PersistedState::get_from_generated_file(project_paths)?;
                                        ExistingPersistedState::ExistingFile(persisted_state)
                                    } else {
                                        ExistingPersistedState::NoFile
                                    };

                                match check_user_file_diff_match(
                                    &existing_persisted_state,
                                    &parsed_paths,
                                )? {
                                    RerunOptions::CodegenAndSyncFromRpc => {
                                        commands::codegen::run_codegen(&parsed_paths)?;
                                        commands::codegen::run_post_codegen_command_sequence(
                                            &parsed_paths.project_paths,
                                        )
                                        .await?;
                                        commands::db_migrate::run_db_setup(project_paths).await?;
                                        commands::start::start_indexer(project_paths).await?;
                                    }
                                    RerunOptions::CodegenAndResyncFromStoredEvents => {
                                        //TODO: Implement command for rerunning from stored events
                                        //and action from this match arm
                                        commands::codegen::run_codegen(&parsed_paths)?;
                                        commands::codegen::run_post_codegen_command_sequence(
                                            &parsed_paths.project_paths,
                                        )
                                        .await?;
                                        commands::db_migrate::run_db_setup(project_paths).await?;
                                        commands::start::start_indexer(project_paths).await?;
                                    }
                                    RerunOptions::ResyncFromStoredEvents => {
                                        //TODO: Implement command for rerunning from stored events
                                        //and action from this match arm
                                        commands::db_migrate::run_db_setup(project_paths).await?; // does this need to be run?
                                        commands::start::start_indexer(project_paths).await?;
                                    }
                                    RerunOptions::ContinueSync => {
                                        let is_restart = dev_subcommands.subcommands
                                            == Some(DevSubcommands::Restart);

                                        let has_run_db_migrations = match existing_persisted_state {
                                            ExistingPersistedState::NoFile => false,
                                            ExistingPersistedState::ExistingFile(ps) => {
                                                ps.has_run_db_migrations
                                            }
                                        };

                                        if !has_run_db_migrations || is_restart {
                                            commands::db_migrate::run_db_setup(project_paths)
                                                .await?;
                                        }
                                        commands::start::start_indexer(project_paths).await?;
                                    }
                                }
                            }
                        }
                    }
                }
                Some(DevSubcommands::Stop) => {
                    commands::docker::docker_compose_down_v(project_paths).await?;
                }
            }

            Ok(())
        }

        CommandType::Start(start_args) => {
            let parsed_paths = ParsedPaths::new(start_args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            if start_args.restart {
                commands::db_migrate::run_db_setup(project_paths).await?;
            }
            commands::start::start_indexer(project_paths).await?;
            Ok(())
        }

        CommandType::Local(local_commands) => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;
            match local_commands {
                LocalCommandTypes::Docker(subcommand) => match subcommand {
                    LocalDockerSubcommands::Up => {
                        commands::docker::docker_compose_up_d(project_paths).await?;
                    }
                    LocalDockerSubcommands::Down => {
                        commands::docker::docker_compose_down_v(project_paths).await?;
                    }
                },
                LocalCommandTypes::DbMigrate(subcommand) => match subcommand {
                    DbMigrateSubcommands::Up => {
                        commands::db_migrate::run_up_migrations(project_paths).await?;
                    }

                    DbMigrateSubcommands::Down => {
                        commands::db_migrate::run_drop_schema(project_paths).await?;
                    }

                    DbMigrateSubcommands::Setup => {
                        commands::db_migrate::run_db_setup(project_paths).await?;
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

#[cfg(test)]
mod test {
    use super::*;
    use strum::IntoEnumIterator;
    use tempfile::tempdir;
    use tokio::task::JoinSet;

    fn generate_init_args_combinations() -> Vec<InitArgs> {
        let mut combinations = Vec::new();

        // Use nested loops or iterators to generate all possible combinations of InitArgs.

        for language in Language::iter() {
            for template in Template::iter() {
                let init_args = InitArgs {
                    // Set other fields here
                    language: Some(language.clone()),
                    template: Some(template.clone()),
                    directory: None,
                    name: Some("test".to_string()),
                    subgraph_migration: None, // ...
                };

                combinations.push(init_args);
            }
        }

        combinations
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn test_all_init_combinations() {
        let combinations = generate_init_args_combinations();

        //Allow envio init commands to run on different threads
        // TODO -> fix the 'unhappy' case where the init commands fail,
        // at the moment the child processes running in the codegen are not aborted correctly causing strange errors

        // let mut join_set = JoinSet::new();

        for mut init_args in combinations {
            //spawn a thread for fetching schema
            // join_set.spawn(async move {
            let temp_dir = tempdir().unwrap();
            init_args.directory = Some(temp_dir.path().to_str().unwrap().to_string());
            println!("Running with init args: {:?}", init_args);

            match run_init_args(&init_args).await {
                Err(_) => {
                    println!("Failed to run with init args: {:?}", init_args);
                    temp_dir.close().unwrap();
                    panic!("Failed to run with init args: {:?}", init_args)
                }
                Ok(_) => {
                    println!("Finished for combination: {:?}", init_args);
                    temp_dir.close().unwrap();
                }
            };
            // });
        }

        // //Await all the envio init and write threads before finishing
        // while let Some(join) = join_set.join_next().await {
        //     println!("err: {:?}, ok {:?}", join.is_err(), join.is_ok());
        //     // Assert that the result is Ok
        //     // assert!(join.is_ok(), "Failed for combination");
        //     let is_ok = join.is_ok();

        //     if !is_ok {
        //         // join_set.shutdown().await;
        //         assert!(false);
        //         break;
        //     } else {
        //         assert!(true)
        //     }
        // }
    }
}
