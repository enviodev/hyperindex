use crate::{
    commands,
    config_parsing::system_config::SystemConfig,
    docker_env,
    executor::{build_start_command, Command, MigrateOpts},
    persisted_state::{self, PersistedState, PersistedStateExists},
    project_paths::ParsedProjectPaths,
    service_health::{self, EndpointHealth},
};
use anyhow::{anyhow, Context, Result};

pub async fn run_dev(project_paths: ParsedProjectPaths, restart: bool) -> Result<Command> {
    let config =
        SystemConfig::parse_from_project_files(&project_paths).context("Failed parsing config")?;

    let current_state = PersistedState::get_current_state(&config)
        .context("Failed getting current indexer state")?;

    let persisted_state_file =
        PersistedStateExists::get_persisted_state_file(&config.parsed_project_paths);

    let (should_run_codegen, changes_detected) = match &persisted_state_file {
        PersistedStateExists::Exists(persisted_state) => {
            current_state.should_run_codegen(persisted_state)
        }
        PersistedStateExists::NotExists | PersistedStateExists::Corrupted => (true, vec![]),
    };

    let print_changes_detected = |changes_detected: Vec<persisted_state::StateField>| {
        // `changes_detected` items render as "Config" / "Schema" / etc.
        let fields = changes_detected
            .iter()
            .map(|f| f.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        println!("Detected changes in {fields} — regenerating");
    };

    if should_run_codegen {
        match persisted_state_file {
            PersistedStateExists::NotExists => {
                println!("No generated files found — running codegen")
            }
            PersistedStateExists::Corrupted => {
                println!("Generated directory is in an invalid state — regenerating")
            }
            PersistedStateExists::Exists(_) => print_changes_detected(changes_detected),
        }

        match persisted_state_file {
            PersistedStateExists::Exists(ps)
                if ps.envio_version != persisted_state::current_version() =>
            {
                println!(
                    "Envio version changed ({} → {}) — regenerating from a clean directory",
                    &ps.envio_version,
                    persisted_state::current_version(),
                );
                commands::codegen::remove_files_except_git(&config.parsed_project_paths.generated)
                    .await
                    .context("Failed purging generated")?;
            }
            _ => (),
        };

        commands::codegen::run_codegen(&config)
            .await
            .context("Failed running codegen")?;
    }
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

    // DB compatibility and migration decisions now live in ReScript — we always
    // send a migrate opts, and the runtime reads `envio_info`, compares against
    // the current config, and either reuses the existing schema, initializes a
    // fresh one, or errors out on incompatible changes.
    let migrate = Some(MigrateOpts { reset: restart });

    let mut indexer_env = up_result.indexer_env.clone();
    indexer_env.push(("ENVIO_DEV_MODE".to_string(), "true".to_string()));

    build_start_command(&config, migrate, &indexer_env).context("Failed building start command")
}
