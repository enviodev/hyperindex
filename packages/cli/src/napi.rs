use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};
use std::sync::Mutex;

fn set_envio_package_dir(dir: &Option<String>) {
    if let Some(d) = dir {
        std::env::set_var("ENVIO_PACKAGE_DIR", d);
    }
}

/// Commands queued by the executor for JS to handle after runCli returns.
/// Migrations and indexer start are queued here instead of executed in Rust,
/// because they need to run in the JS event loop (not in a NAPI async context).
static PENDING_COMMANDS: Mutex<Vec<(String, serde_json::Value)>> = Mutex::new(Vec::new());

/// Queue a command for JS to execute after runCli returns.
pub fn queue_command(command: &str, data: serde_json::Value) {
    PENDING_COMMANDS
        .lock()
        .unwrap()
        .push((command.to_string(), data));
}

#[napi_derive::napi]
pub fn get_config_json(
    config_path: Option<String>,
    directory: Option<String>,
    envio_package_dir: Option<String>,
) -> napi::Result<String> {
    set_envio_package_dir(&envio_package_dir);
    let project_root = directory.unwrap_or_else(|| ".".to_string());
    let config = config_path
        .or_else(|| std::env::var("ENVIO_CONFIG").ok())
        .unwrap_or_else(|| "config.yaml".to_string());
    let project_paths = ParsedProjectPaths::new(&project_root, "generated", &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;
    let system_config = SystemConfig::parse_from_project_files(&project_paths)
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;
    system_config
        .to_public_config_json()
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

/// Upsert persisted state to the database.
/// Called from JS after migrations have run (tables exist).
#[napi_derive::napi]
pub async fn upsert_persisted_state(json: String) -> napi::Result<()> {
    let state: crate::persisted_state::PersistedState = serde_json::from_str(&json)
        .map_err(|e| napi::Error::from_reason(format!("Failed to parse persisted state: {e}")))?;
    state
        .upsert_to_db()
        .await
        .map_err(|e| napi::Error::from_reason(format!("Failed to upsert persisted state: {e}")))?;
    Ok(())
}

/// Run the envio CLI. Returns a JSON array of commands for JS to execute:
/// `[["migration-up", {"reset": false}], ["start-indexer", {"indexPath": "..."}]]`
///
/// Rust handles config parsing, codegen, docker, persisted state — everything
/// that doesn't need JS. Migrations and indexer start are queued and returned
/// for JS to handle in its own event loop (no NAPI async limitations).
#[napi_derive::napi]
pub async fn run_cli(args: Vec<String>, envio_package_dir: Option<String>) -> napi::Result<String> {
    set_envio_package_dir(&envio_package_dir);

    // Clear any commands from a previous run
    PENDING_COMMANDS.lock().unwrap().clear();

    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
        .map_err(|e| {
            if e.use_stderr() {
                napi::Error::from_reason(format!("{e}"))
            } else {
                print!("{e}");
                napi::Error::from_reason("__exit_0__".to_string())
            }
        })?;

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    crate::executor::execute(command_line_args)
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    // Return queued commands for JS to execute
    let commands: Vec<(String, serde_json::Value)> =
        PENDING_COMMANDS.lock().unwrap().drain(..).collect();
    serde_json::to_string(&commands)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing commands: {e}")))
}
