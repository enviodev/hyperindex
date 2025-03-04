use crate::{
    commands,
    config_parsing::system_config::SystemConfig,
    persisted_state::{self, PersistedState, PersistedStateExists, CURRENT_CRATE_VERSION},
    project_paths::ParsedProjectPaths,
    service_health::{self, EndpointHealth},
};
use anyhow::{anyhow, Context, Result};

pub async fn run_dev(project_paths: ParsedProjectPaths) -> Result<()> {
    let config =
        SystemConfig::parse_from_project_files(&project_paths).context("Failed parsing config")?;

    let current_state = PersistedState::get_current_state(&config)
        .context("Failed getting current indexer state")?;

    let persisted_state_file = PersistedStateExists::get_persisted_state_file(&project_paths);

    let (should_run_codegen, changes_detected) = match &persisted_state_file {
        PersistedStateExists::Exists(persisted_state) => {
            current_state.should_run_codegen(persisted_state)
        }
        PersistedStateExists::NotExists | PersistedStateExists::Corrupted => (true, vec![]),
    };

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
        match persisted_state_file {
            PersistedStateExists::NotExists => println!("No generated files detected"),
            PersistedStateExists::Corrupted => println!("Persisted state is invalid"),
            PersistedStateExists::Exists(_) => print_changes_detected(changes_detected),
        }

        match persisted_state_file {
            PersistedStateExists::Exists(ps) if ps.envio_version != CURRENT_CRATE_VERSION => {
                println!(
                    "Envio version '{}' does not match the previous version '{}' used in the \
                     generated directory",
                    CURRENT_CRATE_VERSION, &ps.envio_version
                );
                println!("Purging generated directory",);
                commands::codegen::remove_files_except_git(&project_paths.generated)
                    .await
                    .context("Failed purging generated")?;
            }
            _ => (),
        };

        println!("Running codegen");

        commands::codegen::run_codegen(&config, &project_paths)
            .await
            .context("Failed running codegen")?;
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
            //Get the persisted state from the db
            let persisted_state_db = PersistedStateExists::read_from_db()
                .await
                .context("Failed to read persisted state from the DB")?;

            let (should_run_db_migrations, changes_detected) = match &persisted_state_db {
                PersistedStateExists::Exists(persisted_state) =>
                //In the case where the persisted state exists, compare it to current state
                //determine whether to run migrations and which changes have occured to
                //cause that.
                {
                    let (should_run_db_migrations, changes_detected) =
                        current_state.should_run_db_migrations(persisted_state);

                    (should_run_db_migrations, changes_detected)
                }
                //Otherwise we should run db migrations
                PersistedStateExists::NotExists | PersistedStateExists::Corrupted => (true, vec![]),
            };

            if should_run_db_migrations {
                match persisted_state_db {
                    PersistedStateExists::NotExists => {
                        println!("Db Migrations have not been run")
                    }
                    PersistedStateExists::Corrupted => println!("Invalid DB persisted state"),
                    PersistedStateExists::Exists(_) => print_changes_detected(changes_detected),
                }
                println!("Running db migrations");

                commands::db_migrate::run_db_setup(&project_paths, &current_state)
                    .await
                    .context("Failed running db setup command")?;
            }

            println!("Starting indexer");

            commands::start::start_indexer(&project_paths, should_open_hasura_console)
                .await
                .context("Failed running start on the indexer")?;
        }
    }

    Ok(())
}
