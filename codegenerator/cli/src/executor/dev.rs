use crate::{
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    persisted_state::{self, PersistedState},
    project_paths::ParsedProjectPaths,
    service_health::{self, EndpointHealth},
};
use anyhow::{anyhow, Context, Result};

pub async fn run_dev(project_paths: ParsedProjectPaths) -> Result<()> {
    let human_config = human_config::deserialize_config_from_yaml(&project_paths.config)
        .context("Failed deserializing config")?;

    let config = SystemConfig::parse_from_human_config(&human_config, &project_paths)
        .context("Failed parsing config")?;

    let current_state = PersistedState::get_current_state(&config)
        .context("Failed getting current indexer state")?;

    let opt_persisted_state_file = PersistedState::get_persisted_state_file(&project_paths)
        .context("Failed getting persisted state file from generated folder")?;

    let (should_run_codegen, changes_detected) = opt_persisted_state_file
        .as_ref()
        .map_or((true, vec![]), |p| current_state.should_run_codegen(&p));

    let print_changes_detected = |changes_detected: Vec<persisted_state::StateField>| {
        println!(
            "Changes to {} detected",
            //Changes will "Config" or "Schema" etc.
            changes_detected
                .iter()
                .map(|f| f.to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
    };

    if should_run_codegen {
        if opt_persisted_state_file.is_none() {
            println!("No generated files detected");
        } else {
            print_changes_detected(changes_detected);
        }
        println!("Running codegen");

        commands::codegen::run_codegen(&config, &project_paths)
            .await
            .context("Failed running codegen")?;
        commands::codegen::run_post_codegen_command_sequence(&project_paths)
            .await
            .context("Failed running post codegen command sequence")?;
    }
    // if hasura healhz check returns not found assume docker isnt running and start it up {
    let hasura_health_check_is_error = service_health::fetch_hasura_healthz().await.is_err();

    let should_open_hasura_console = if hasura_health_check_is_error {
        //Run docker commands to spin up container
        commands::docker::docker_compose_up_d(&project_paths)
            .await
            .context("Failed running docker compose up after server liveness check")?;
        true
    } else {
        false
    };

    let hasura_health = service_health::fetch_hasura_healthz_with_retry().await;

    match hasura_health {
        EndpointHealth::Unhealthy(err_message) => {
            Err(anyhow!(err_message)).context("Failed to start hasura")?;
        }
        EndpointHealth::Healthy => {
            {
                println!("healthy, continuing");

                let opt_persisted_state_db = PersistedState::read_from_db()
                    .await
                    .context("Failed to read persisted state from the DB")?;

                let (should_run_db_migrations, changes_detected) =
                    opt_persisted_state_db.as_ref().map_or((true, vec![]), |p| {
                        current_state.should_run_db_migrations(&p)
                    });

                let should_sync_from_raw_events = opt_persisted_state_db
                    .as_ref()
                    .map_or(false, |p| current_state.should_sync_from_raw_events(&p));

                if should_run_db_migrations {
                    //print changes and running db migrations
                    if opt_persisted_state_db.is_some() {
                        print_changes_detected(changes_detected);
                    }
                    println!("Running db migrations");

                    let should_drop_raw_events = !should_sync_from_raw_events;

                    commands::db_migrate::run_db_setup(
                        &project_paths,
                        should_drop_raw_events,
                        &current_state,
                    )
                    .await
                    .context("Failed running db setup command")?;
                }

                if should_sync_from_raw_events {
                    println!("Resyncing from raw_events");
                }

                println!("Starting indexer");

                commands::start::start_indexer(
                    &project_paths,
                    should_sync_from_raw_events,
                    should_open_hasura_console,
                )
                .await
                .context("Failed running start on the indexer")?;
            }
        }
    }

    Ok(())
}
