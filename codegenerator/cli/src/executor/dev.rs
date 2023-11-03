use crate::{
    commands,
    config_parsing::{
        human_config::{self, is_rescript},
        system_config::SystemConfig,
    },
    persisted_state::{
        check_user_file_diff_match, handler_file_has_changed, persisted_state_file_exists,
        ExistingPersistedState, PersistedState, RerunOptions,
    },
    project_paths::ParsedProjectPaths,
    service_health::{self, EndpointHealth},
};
use anyhow::{anyhow, Context, Result};

pub async fn run_dev(project_paths: ParsedProjectPaths) -> Result<()> {
    let human_config = human_config::deserialize_config_from_yaml(&project_paths.config)
        .context("Failed deserializing config")?;

    let config = SystemConfig::parse_from_human_config(&human_config, &project_paths)
        .context("Failed parsing config")?;
    // if hasura healhz check returns not found assume docker isnt running and start it up {
    let hasura_health_check_is_error = service_health::fetch_hasura_healthz().await.is_err();

    let mut docker_started_on_run = false;

    if hasura_health_check_is_error {
        //Run docker commands to spin up container
        commands::docker::docker_compose_up_d(&project_paths).await?;
        docker_started_on_run = true;
    }

    let hasura_health = service_health::fetch_hasura_healthz_with_retry().await;

    match hasura_health {
        EndpointHealth::Unhealthy(err_message) => {
            Err(anyhow!(err_message)).context("Failed to start hasura")?;
        }
        EndpointHealth::Healthy => {
            {
                let existing_persisted_state = if persisted_state_file_exists(&project_paths) {
                    let persisted_state = PersistedState::get_from_generated_file(&project_paths)?;
                    ExistingPersistedState::ExistingFile(persisted_state)
                } else {
                    ExistingPersistedState::NoFile
                };

                if handler_file_has_changed(&existing_persisted_state, &config)
                    .context("Failed checking if handler file has changes")?
                    && is_rescript(&config)
                        .context("Failed checking if handler file is rescript")?
                {
                    commands::rescript::build(&project_paths.project_root).await?;
                }

                match check_user_file_diff_match(
                    &existing_persisted_state,
                    &config,
                    &project_paths,
                )? {
                    RerunOptions::CodegenAndSyncFromRpc => {
                        println!("Running codegen and resyncing from source");
                        commands::codegen::run_codegen(&config, &project_paths).await?;
                        commands::codegen::run_post_codegen_command_sequence(&project_paths)
                            .await?;
                        const SHOULD_DROP_RAW_EVENTS: bool = true;
                        commands::db_migrate::run_db_setup(&project_paths, SHOULD_DROP_RAW_EVENTS)
                            .await?;

                        const SHOULD_SYNC_FROM_RAW_EVENTS: bool = false;
                        commands::start::start_indexer(
                            &project_paths,
                            SHOULD_SYNC_FROM_RAW_EVENTS,
                            docker_started_on_run,
                        )
                        .await?;
                    }
                    RerunOptions::CodegenAndResyncFromStoredEvents => {
                        println!("Running codegen and resyncing from cached events");
                        //TODO: Implement command for rerunning from stored events
                        //and action from this match arm
                        commands::codegen::run_codegen(&config, &project_paths).await?;
                        commands::codegen::run_post_codegen_command_sequence(&project_paths)
                            .await?;
                        const SHOULD_DROP_RAW_EVENTS: bool = false;
                        commands::db_migrate::run_db_setup(&project_paths, SHOULD_DROP_RAW_EVENTS)
                            .await?;

                        const SHOULD_SYNC_FROM_RAW_EVENTS: bool = true;
                        commands::start::start_indexer(
                            &project_paths,
                            SHOULD_SYNC_FROM_RAW_EVENTS,
                            docker_started_on_run,
                        )
                        .await?;
                    }
                    RerunOptions::ResyncFromStoredEvents => {
                        println!("Resyncing from cached events");
                        //TODO: Implement command for rerunning from stored events
                        //and action from this match arm
                        const SHOULD_DROP_RAW_EVENTS: bool = false;
                        commands::db_migrate::run_db_setup(&project_paths, SHOULD_DROP_RAW_EVENTS)
                            .await?; // does this need to be run?
                        const SHOULD_SYNC_FROM_RAW_EVENTS: bool = true;
                        commands::start::start_indexer(
                            &project_paths,
                            SHOULD_SYNC_FROM_RAW_EVENTS,
                            docker_started_on_run,
                        )
                        .await?;
                    }
                    RerunOptions::ContinueSync => {
                        println!("Continuing sync");
                        let has_run_db_migrations = match existing_persisted_state {
                            ExistingPersistedState::NoFile => false,
                            ExistingPersistedState::ExistingFile(ps) => ps.has_run_db_migrations,
                        };

                        if !has_run_db_migrations || docker_started_on_run {
                            const SHOULD_DROP_RAW_EVENTS: bool = true;
                            commands::db_migrate::run_db_setup(
                                &project_paths,
                                SHOULD_DROP_RAW_EVENTS,
                            )
                            .await?;
                        }
                        const SHOULD_SYNC_FROM_RAW_EVENTS: bool = false;
                        commands::start::start_indexer(
                            &project_paths,
                            SHOULD_SYNC_FROM_RAW_EVENTS,
                            docker_started_on_run,
                        )
                        .await?;
                    }
                }
            }
        }
    }

    Ok(())
}
