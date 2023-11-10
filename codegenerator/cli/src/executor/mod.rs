use crate::{
    cli_args::clap_definitions::{CommandLineArgs, CommandType},
    commands,
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
            if start_args.restart {
                const SHOULD_DROP_RAW_EVENTS: bool = true;
                commands::db_migrate::run_db_setup(&parsed_project_paths, SHOULD_DROP_RAW_EVENTS)
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
