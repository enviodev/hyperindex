use crate::{
    cli_args::clap_definitions::{CommandLineArgs, CommandType},
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    persisted_state::{PersistedState, PersistedStateExists, CURRENT_CRATE_VERSION},
    project_paths::ParsedProjectPaths,
};

mod codegen;
mod dev;
pub mod init;
mod local;

use anyhow::{Context, Result};

pub async fn execute(command_line_args: CommandLineArgs) -> Result<()> {
    let global_project_paths = command_line_args.project_paths;
    let parsed_project_paths = ParsedProjectPaths::try_from(global_project_paths.clone())
        .context("Failed parsing project paths")?;

    match command_line_args.command {
        
        CommandType::Init(init_args) => {
            init::run_init_args(&init_args, &global_project_paths).await?;
        }

        CommandType::Codegen => {
            codegen::run_codegen(&parsed_project_paths).await?;
        }

        CommandType::Dev => {
            dev::run_dev(parsed_project_paths).await?;
        }

        CommandType::Stop => {
            commands::docker::docker_compose_down_v(&parsed_project_paths).await?;
        }

        CommandType::Start(start_args) => {
            //Add warnings to start command
            match PersistedStateExists::get_persisted_state_file(&parsed_project_paths) {
                PersistedStateExists::Exists(ps) if &ps.envio_version != CURRENT_CRATE_VERSION => 
                    println!(
                    "WARNING: Envio version '{}' is currently being used. It does not match the version '{}' that was used to create generated directory previously. Please consider rerunning envio codegen, or running the same version of envio. ",
                    CURRENT_CRATE_VERSION, &ps.envio_version
                ),
                PersistedStateExists::NotExists => println!("WARNING: Generated directory not detected. Consider running envio codegen first"),
                PersistedStateExists::Corrupted => println!("WARNING: Generated directory is corrupted. Consider running envio codegen first"),
                PersistedStateExists::Exists(_)=>()
            };

            if start_args.restart {
                let yaml_config =
                    human_config::deserialize_config_from_yaml(&parsed_project_paths.config)
                        .context("Failed deserializing config")?;

                let config =
                    SystemConfig::parse_from_human_config(&yaml_config, &parsed_project_paths)
                        .context("Failed parsing config")?;

                let persisted_state = PersistedState::get_current_state(&config).await
                    .context("Failed constructing persisted state")?;

                const SHOULD_DROP_RAW_EVENTS: bool = true;

                commands::db_migrate::run_db_setup(
                    &parsed_project_paths,
                    SHOULD_DROP_RAW_EVENTS,
                    &persisted_state,
                )
                .await?;
            }
            const SHOULD_SYNC_FROM_RAW_EVENTS: bool = false;
            const SHOULD_OPEN_HASURA: bool = false;
            commands::start::start_indexer(
                &parsed_project_paths,
                SHOULD_SYNC_FROM_RAW_EVENTS,
                SHOULD_OPEN_HASURA,
            )
            .await?;
        }

        CommandType::Local(local_commands) => {
            local::run_local(&local_commands, &parsed_project_paths).await?;
        }

        CommandType::PrintAllHelp {} => {
            clap_markdown::print_help_markdown::<CommandLineArgs>();
        }
    };

    Ok(())
}
