use crate::{
    cli_args::clap_definitions::{DbMigrateSubcommands, LocalCommandTypes, LocalDockerSubcommands},
    config_parsing::system_config::SystemConfig,
    docker_env,
    executor::{public_config_value, Command},
    persisted_state::PersistedState,
    project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

pub async fn run_local(
    local_commands: &LocalCommandTypes,
    project_paths: &ParsedProjectPaths,
) -> Result<Option<Command>> {
    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;

    match local_commands {
        LocalCommandTypes::Docker(subcommand) => match subcommand {
            LocalDockerSubcommands::Up => {
                // local docker up intentionally doesn't propagate indexer_env
                // since it doesn't spawn the indexer — callers are expected
                // to run `envio start`/`envio dev` afterwards, which will
                // compute the indexer_env fresh.
                docker_env::up(docker_env::UpOptions {
                    project_root: &config.parsed_project_paths.project_root,
                    clickhouse: config.storage.clickhouse,
                })
                .await
                .map(|_| ())?;
                Ok(None)
            }
            LocalDockerSubcommands::Down => {
                docker_env::down().await?;
                Ok(None)
            }
        },
        LocalCommandTypes::DbMigrate(subcommand) => match subcommand {
            DbMigrateSubcommands::Up => {
                let persisted_state = PersistedState::get_current_state(&config)
                    .context("Failed constructing persisted state")?;
                Ok(Some(Command::Migrate {
                    reset: false,
                    persisted_state,
                    config: public_config_value(&config)?,
                }))
            }

            DbMigrateSubcommands::Down => Ok(Some(Command::DropSchema {
                config: public_config_value(&config)?,
            })),

            DbMigrateSubcommands::Setup => {
                let persisted_state = PersistedState::get_current_state(&config)
                    .context("Failed constructing persisted state")?;
                Ok(Some(Command::Migrate {
                    reset: true,
                    persisted_state,
                    config: public_config_value(&config)?,
                }))
            }
        },
    }
}
