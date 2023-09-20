use std::error::Error;

use anyhow::{anyhow, Context};
use clap::Parser;

use envio::{
    cli_args::{
        CommandLineArgs, CommandType, DbMigrateSubcommands, LocalCommandTypes,
        LocalDockerSubcommands, ProjectPathsArgs, ToProjectPathsArgs,
    },
    commands,
    config_parsing::is_rescript,
    persisted_state::{
        check_user_file_diff_match, handler_file_has_changed, persisted_state_file_exists,
        ExistingPersistedState, PersistedState, RerunOptions,
    },
    project_paths::ParsedPaths,
    service_health::{self, EndpointHealth},
    utils::run_init_args,
};

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
            commands::codegen::run_codegen(&parsed_paths).await?;
            commands::codegen::run_post_codegen_command_sequence(project_paths).await?;
            Ok(())
        }

        CommandType::Dev => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;

            // if hasura healhz check returns not found assume docker isnt running and start it up {
            let hasura_health_check_is_error =
                service_health::fetch_hasura_healthz().await.is_err();

            let mut docker_started_on_run = false;

            if hasura_health_check_is_error {
                //Run docker commands to spin up container
                commands::docker::docker_compose_up_d(project_paths).await?;
                docker_started_on_run = true;
            }

            let hasura_health = service_health::fetch_hasura_healthz_with_retry().await;

            match hasura_health {
                EndpointHealth::Unhealthy(err_message) => {
                    Err(anyhow!(err_message)).context("Failed to start hasura")?;
                }
                EndpointHealth::Healthy => {
                    {
                        let existing_persisted_state = if persisted_state_file_exists(project_paths)
                        {
                            let persisted_state =
                                PersistedState::get_from_generated_file(project_paths)?;
                            ExistingPersistedState::ExistingFile(persisted_state)
                        } else {
                            ExistingPersistedState::NoFile
                        };

                        if handler_file_has_changed(&existing_persisted_state, &parsed_paths)?
                            && is_rescript(&parsed_paths.handler_paths)
                        {
                            commands::rescript::build(&project_paths.project_root).await?;
                        }

                        match check_user_file_diff_match(&existing_persisted_state, &parsed_paths)?
                        {
                            RerunOptions::CodegenAndSyncFromRpc => {
                                commands::codegen::run_codegen(&parsed_paths).await?;
                                commands::codegen::run_post_codegen_command_sequence(
                                    &parsed_paths.project_paths,
                                )
                                .await?;
                                commands::db_migrate::run_db_setup(project_paths, true).await?;
                                commands::start::start_indexer(
                                    project_paths,
                                    docker_started_on_run,
                                )
                                .await?;
                            }
                            RerunOptions::CodegenAndResyncFromStoredEvents => {
                                //TODO: Implement command for rerunning from stored events
                                //and action from this match arm
                                commands::codegen::run_codegen(&parsed_paths).await?;
                                commands::codegen::run_post_codegen_command_sequence(
                                    &parsed_paths.project_paths,
                                )
                                .await?;
                                commands::db_migrate::run_db_setup(project_paths, false).await?;
                                commands::start::start_indexer(
                                    project_paths,
                                    docker_started_on_run,
                                )
                                .await?;
                            }
                            RerunOptions::ResyncFromStoredEvents => {
                                //TODO: Implement command for rerunning from stored events
                                //and action from this match arm
                                commands::db_migrate::run_db_setup(project_paths, false).await?; // does this need to be run?
                                commands::start::start_indexer(
                                    project_paths,
                                    docker_started_on_run,
                                )
                                .await?;
                            }
                            RerunOptions::ContinueSync => {
                                let has_run_db_migrations = match existing_persisted_state {
                                    ExistingPersistedState::NoFile => false,
                                    ExistingPersistedState::ExistingFile(ps) => {
                                        ps.has_run_db_migrations
                                    }
                                };

                                if !has_run_db_migrations || docker_started_on_run {
                                    commands::db_migrate::run_db_setup(project_paths, true).await?;
                                }
                                commands::start::start_indexer(
                                    project_paths,
                                    docker_started_on_run,
                                )
                                .await?;
                            }
                        }
                    }
                }
            }

            Ok(())
        }
        CommandType::Stop => {
            let parsed_paths = ParsedPaths::new(ProjectPathsArgs::default())?;
            let project_paths = &parsed_paths.project_paths;

            commands::docker::docker_compose_down_v(project_paths).await?;
            Ok(())
        }

        CommandType::Start(start_args) => {
            let parsed_paths = ParsedPaths::new(start_args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;
            if start_args.restart {
                commands::db_migrate::run_db_setup(project_paths, true).await?;
            }
            commands::start::start_indexer(project_paths, false).await?;
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
                        commands::db_migrate::run_db_setup(project_paths, true).await?;
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
