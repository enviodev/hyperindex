use crate::{
    cli_args::clap_definitions::{DbMigrateSubcommands, LocalCommandTypes, LocalDockerSubcommands},
    commands,
    config_parsing::system_config::SystemConfig,
    persisted_state::PersistedState,
    project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

pub async fn run_local(
    local_commands: &LocalCommandTypes,
    project_paths: &ParsedProjectPaths,
) -> Result<()> {
    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;

    match local_commands {
        LocalCommandTypes::Docker(subcommand) => match subcommand {
            LocalDockerSubcommands::Up => {
                commands::docker::docker_compose_up_d(&config).await?;
            }
            LocalDockerSubcommands::Down => {
                commands::docker::docker_compose_down_v(&config).await?;
            }
        },
        LocalCommandTypes::DbMigrate(subcommand) => {
            //Use a closure just so running local dow doesn't need to construct persisted state
            let get_persisted_state = || -> Result<PersistedState> {
                let persisted_state = PersistedState::get_current_state(&config)
                    .context("Failed constructing persisted state")?;

                Ok(persisted_state)
            };

            match subcommand {
                DbMigrateSubcommands::Up => {
                    let persisted_state = get_persisted_state()?;
                    commands::db_migrate::run_up_migrations(&config, &persisted_state).await?;
                }

                DbMigrateSubcommands::Down => {
                    commands::db_migrate::run_drop_schema(&config).await?;
                }

                DbMigrateSubcommands::Setup => {
                    let persisted_state = get_persisted_state()?;
                    commands::db_migrate::run_db_setup(&config, &persisted_state).await?;
                }
            }
        }
    }
    Ok(())
}
