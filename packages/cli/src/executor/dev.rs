use crate::{
    config_parsing::system_config::SystemConfig,
    docker_env,
    executor::{build_start_command, codegen, Command},
    project_paths::ParsedProjectPaths,
    service_health::{self, EndpointHealth},
};
use anyhow::{anyhow, Context, Result};

pub async fn run_dev(project_paths: ParsedProjectPaths, restart: bool) -> Result<Command> {
    let config =
        SystemConfig::parse_from_project_files(&project_paths).context("Failed parsing config")?;

    // Always regenerate from a clean directory — the JS runtime now does the
    // config-vs-DB compatibility check, so there's no separate file-based
    // codegen-staleness gate to maintain.
    codegen::purge_and_run(&config).await?;

    let up_result = docker_env::up(docker_env::UpOptions {
        project_root: &config.parsed_project_paths.project_root,
        clickhouse: config.storage.clickhouse,
    })
    .await
    .context("Failed starting Docker containers")?;

    if up_result.hasura_enabled {
        let hasura_health = service_health::fetch_hasura_healthz_with_retry().await;

        match hasura_health {
            EndpointHealth::Unhealthy(err_message) => {
                Err(anyhow!(err_message)).context("Failed to start hasura")?;
            }
            EndpointHealth::Healthy => {}
        }
    }

    // DB compatibility and migration decisions live in ReScript: the runtime
    // reads `envio_info`, compares against the current config, and either
    // reuses the existing schema, initializes a fresh one, or errors out on
    // incompatible changes. `restart` only forces a reset.
    let mut indexer_env = up_result.indexer_env.clone();
    indexer_env.push(("ENVIO_DEV_MODE".to_string(), "true".to_string()));

    build_start_command(&config, restart, &indexer_env).context("Failed building start command")
}
