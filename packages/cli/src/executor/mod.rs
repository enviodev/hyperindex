use crate::{
    clap_definitions::{JsonSchema, Script},
    cli_args::clap_definitions::{CommandLineArgs, CommandType},
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    docker_env,
    persisted_state::{self, PersistedState, PersistedStateExists},
    project_paths::ParsedProjectPaths,
    scripts,
};

mod codegen;
mod dev;
pub mod init;
mod local;

use anyhow::{Context, Result};
use schemars::schema_for;

/// A deferred work item the executor asks its host to run after Rust returns.
///
/// Rust handles config parsing, codegen, docker, persisted state — everything
/// that doesn't need JS. Work that must run in the JS event loop (migrations
/// + indexer start, which load `envio/src/*.res.mjs` modules) is returned as
/// `Command`s. The CLI layer knows nothing about how the host dispatches
/// them: the NAPI shim forwards them to JS, a test harness could run them
/// inline, a future standalone binary could spawn a Node subprocess, etc.
///
/// Wire format: `[name, data]` tuple — tuple structs serialize as JSON
/// arrays by default.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Command(pub String, pub serde_json::Value);

impl Command {
    pub fn new(name: impl Into<String>, data: serde_json::Value) -> Self {
        Self(name.into(), data)
    }
}

pub async fn execute(command_line_args: CommandLineArgs) -> Result<Vec<Command>> {
    let global_project_paths = command_line_args.project_paths;
    let parsed_project_paths = ParsedProjectPaths::try_from(global_project_paths.clone())
        .context("Failed parsing project paths")?;

    let mut commands: Vec<Command> = Vec::new();

    match command_line_args.command {
        CommandType::Init(init_args) => {
            init::run_init_args(init_args, &global_project_paths).await?;
        }

        CommandType::Codegen => {
            codegen::run_codegen(&parsed_project_paths).await?;
        }

        CommandType::Dev(dev_args) => {
            commands.extend(dev::run_dev(parsed_project_paths, dev_args.restart).await?);
        }

        CommandType::Stop => {
            docker_env::down().await?;
        }

        CommandType::Start(start_args) => {
            //Add warnings to start command
            match PersistedStateExists::get_persisted_state_file(&parsed_project_paths) {
                PersistedStateExists::Exists(ps)
                    if ps.envio_version != persisted_state::current_version() =>
                {
                    println!(
                        "WARNING: Envio version '{}' is currently being used. It does not match \
                         the version '{}' that was used to create generated directory previously. \
                         Please consider rerunning envio codegen, or running the same version of \
                         envio. ",
                        persisted_state::current_version(),
                        &ps.envio_version
                    )
                }
                PersistedStateExists::NotExists => println!(
                    "WARNING: Generated directory not detected. Consider running envio codegen \
                     first"
                ),
                PersistedStateExists::Corrupted => println!(
                    "WARNING: Generated directory is corrupted. Consider running envio codegen \
                     first"
                ),
                PersistedStateExists::Exists(_) => (),
            };

            let config = SystemConfig::parse_from_project_files(&parsed_project_paths)
                .context("Failed parsing config")?;

            if start_args.restart {
                let persisted_state = PersistedState::get_current_state(&config)
                    .context("Failed constructing persisted state")?;

                commands.push(commands::db_migrate::run_db_setup(&config, &persisted_state).await?);
            }
            // `envio start` doesn't manage Docker — users are expected to
            // have their own services and env vars set up (e.g. via .env).
            commands.push(commands::start::start_indexer(&config, &[]).await?);
        }

        CommandType::Local(local_commands) => {
            commands.extend(local::run_local(&local_commands, &parsed_project_paths).await?);
        }

        CommandType::Script(Script::PrintCliHelpMd) => {
            println!("{}", CommandLineArgs::generate_markdown_help());
        }
        CommandType::Script(Script::PrintConfigJsonSchema(json_schema)) => match json_schema {
            JsonSchema::Evm => {
                let schema = schema_for!(human_config::evm::HumanConfig);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&schema)
                        .context("Failed serializing evm json schema")?
                );
            }
            JsonSchema::Fuel => {
                let schema = schema_for!(human_config::fuel::HumanConfig);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&schema)
                        .context("Failed serializing fuel json schema")?
                );
            }
            JsonSchema::Svm => {
                let schema = schema_for!(human_config::svm::HumanConfig);
                println!(
                    "{}",
                    serde_json::to_string_pretty(&schema)
                        .context("Failed serializing svm json schema")?
                );
            }
        },
        CommandType::Script(Script::PrintMissingNetworks) => {
            scripts::print_missing_networks::run()
                .await
                .context("Failed print missing networks script")?;
        }
    };

    Ok(commands)
}
