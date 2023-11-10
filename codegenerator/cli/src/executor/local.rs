use crate::{
    cli_args::clap_definitions::{DbMigrateSubcommands, LocalCommandTypes, LocalDockerSubcommands},
    commands,
    project_paths::ParsedProjectPaths,
};
use anyhow::Result;

pub async fn run_local(
    local_commands: &LocalCommandTypes,
    project_paths: &ParsedProjectPaths,
) -> Result<()> {
    match local_commands {
        LocalCommandTypes::Docker(subcommand) => match subcommand {
            LocalDockerSubcommands::Up => {
                commands::docker::docker_compose_up_d(&project_paths).await?;
            }
            LocalDockerSubcommands::Down => {
                commands::docker::docker_compose_down_v(&project_paths).await?;
            }
        },
        LocalCommandTypes::DbMigrate(subcommand) => match subcommand {
            DbMigrateSubcommands::Up => {
                commands::db_migrate::run_up_migrations(&project_paths).await?;
            }

            DbMigrateSubcommands::Down => {
                commands::db_migrate::run_drop_schema(&project_paths).await?;
            }

            DbMigrateSubcommands::Setup => {
                const SHOULD_DROP_RAW_EVENTS: bool = true;
                commands::db_migrate::run_db_setup(&project_paths, SHOULD_DROP_RAW_EVENTS).await?;
            }
        },
    }
    Ok(())
}
