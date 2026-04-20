use crate::{
    commands,
    config_parsing::system_config::SystemConfig,
    docker_env,
    executor::Command,
    persisted_state::{self, PersistedState, PersistedStateExists},
    project_paths::ParsedProjectPaths,
    service_health::{self, EndpointHealth},
};
use anyhow::{anyhow, Context, Result};

pub async fn run_dev(
    project_paths: ParsedProjectPaths,
    restart: bool,
    envio_package_dir: Option<&str>,
) -> Result<Vec<Command>> {
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
            PersistedStateExists::Exists(ps)
                if ps.envio_version != persisted_state::current_version() =>
            {
                println!(
                    "Envio version '{}' does not match the previous version '{}' used in the \
                     generated directory",
                    persisted_state::current_version(),
                    &ps.envio_version
                );
                println!("Purging generated directory",);
                commands::codegen::remove_files_except_git(&config.parsed_project_paths.generated)
                    .await
                    .context("Failed purging generated")?;
            }
            _ => (),
        };

        println!("Running codegen");

        commands::codegen::run_codegen(&config, envio_package_dir)
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

    let (should_run_db_migrations, changes_detected) = match &persisted_state_db {
        None => (true, vec![]),
        Some(PersistedStateExists::Exists(persisted_state)) =>
        //In the case where the persisted state exists, compare it to current state
        //determine whether to run migrations and which changes have occured to
        //cause that.
        {
            let (should_run_db_migrations, changes_detected) =
                current_state.should_run_db_migrations(persisted_state);

            (should_run_db_migrations, changes_detected)
        }
        //Otherwise we should run db migrations
        Some(PersistedStateExists::NotExists) | Some(PersistedStateExists::Corrupted) => {
            (true, vec![])
        }
    };

    let mut queued: Vec<Command> = Vec::new();

    if should_run_db_migrations {
        match persisted_state_db {
            None => println!("Restarting indexing from scratch"),
            Some(PersistedStateExists::NotExists) => {
                println!("Db Migrations have not been run")
            }
            Some(PersistedStateExists::Corrupted) => println!("Invalid DB persisted state"),
            Some(PersistedStateExists::Exists(_)) => print_changes_detected(changes_detected),
        }
        println!("Running db migrations");

        queued.push(
            commands::db_migrate::run_db_setup(&config, &current_state)
                .await
                .context("Failed running db setup command")?,
        );
    }

    println!("Starting indexer");

    let mut indexer_env = up_result.indexer_env.clone();
    indexer_env.push(("ENVIO_DEV_MODE".to_string(), "true".to_string()));

    queued.push(
        commands::start::start_indexer(&config, &indexer_env)
            .await
            .context("Failed running start on the indexer")?,
    );

    Ok(queued)
}
