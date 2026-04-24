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

    //Get the persisted state from the db.
    //Skip the read entirely when restarting — we don't use the result.
    let persisted_state_db = if restart {
        None
    } else {
        Some(
            PersistedStateExists::read_from_db()
                .await
                .context("Failed to read persisted state from the DB")?,
        )
    };

    // When the DB already has indexer state for this project, refuse to silently
    // wipe it — the user must explicitly opt in with `envio dev -r`.
    if let Some(PersistedStateExists::Exists(persisted_state)) = &persisted_state_db {
        let (_, changes_detected) = current_state.should_run_db_migrations(persisted_state);
        if !changes_detected.is_empty() {
            let fields = changes_detected
                .iter()
                .map(|f| f.to_string())
                .collect::<Vec<_>>()
                .join(", ");
            return Err(anyhow!(
                "Incompatible change detected in {fields}. To continue:\n\
                 \n  \
                 1. Revert the change    # keep indexing with the existing state\n  \
                 2. envio dev -r         # clear the database and re-index from scratch"
            ));
        }
    }

    let needs_migration = match &persisted_state_db {
        None => {
            println!("Resetting the database for a fresh indexer run");
            true
        }
        Some(PersistedStateExists::NotExists) => {
            println!("No existing database schema found — creating one");
            true
        }
        Some(PersistedStateExists::Corrupted) => {
            println!("Could not read the previous indexer state from the database — resetting");
            true
        }
        // `Exists` with a diff returned above; this arm means no diff, so the
        // existing indexer state is reused and no migrations are needed.
        Some(PersistedStateExists::Exists(_)) => false,
    };

    let migrate = if needs_migration {
        Some(MigrateOpts {
            // `envio dev` always does a full reset when migrations are needed
            // (matches prior behavior of `run_db_setup`).
            reset: true,
            persisted_state: current_state,
        })
    } else {
        None
    };

    let mut indexer_env = up_result.indexer_env.clone();
    indexer_env.push(("ENVIO_DEV_MODE".to_string(), "true".to_string()));

    build_start_command(&config, migrate, &indexer_env).context("Failed building start command")
}
