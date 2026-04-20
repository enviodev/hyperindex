use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    executor::Command, project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};

fn set_envio_package_dir(dir: &Option<String>) {
    if let Some(d) = dir {
        std::env::set_var("ENVIO_PACKAGE_DIR", d);
    }
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
    let cwd = std::env::current_dir()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "<unknown>".to_string());
    let project_paths = ParsedProjectPaths::new(&project_root, "generated", &config)
        .map_err(|e| {
            napi::Error::from_reason(format!(
                "Failed parsing project paths (cwd={cwd}, root={project_root}, config={config}): {e}"
            ))
        })?;
    let system_config = SystemConfig::parse_from_project_files(&project_paths).map_err(|e| {
        napi::Error::from_reason(format!(
            "Config parse error (cwd={cwd}, config={}): {e}",
            project_paths.config.display()
        ))
    })?;
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

/// Outcome of a `run_cli` invocation. Serialized to JSON and returned to JS
/// instead of overloading the error channel with control-flow sentinels.
#[derive(serde::Serialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
enum RunCliOutcome<'a> {
    /// Clap printed help/version text to stdout. JS should exit(0).
    HelpOrVersion,
    /// Normal completion. JS should run each command in order.
    Ok { commands: &'a [Command] },
}

/// Run the envio CLI. Returns a JSON-serialized `RunCliOutcome`:
/// - `{"outcome":"helpOrVersion"}` — clap printed help/version, JS exits 0
/// - `{"outcome":"ok","commands":[["migration-up", {...}], ...]}` — JS runs each
///
/// The executor layer doesn't know about NAPI; it returns a `Vec<Command>` that
/// this shim serializes for the JS host. A pure-Rust host (tests, future
/// binary) could consume the same return value directly.
#[napi_derive::napi]
pub async fn run_cli(args: Vec<String>, envio_package_dir: Option<String>) -> napi::Result<String> {
    set_envio_package_dir(&envio_package_dir);

    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = match CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
    {
        Ok(m) => m,
        Err(e) if !e.use_stderr() => {
            // Help / version — clap writes to stdout; signal clean exit to JS.
            print!("{e}");
            return serialize_outcome(&RunCliOutcome::HelpOrVersion);
        }
        Err(e) => return Err(napi::Error::from_reason(format!("{e}"))),
    };

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let commands = crate::executor::execute(command_line_args)
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    serialize_outcome(&RunCliOutcome::Ok {
        commands: &commands,
    })
}

fn serialize_outcome(outcome: &RunCliOutcome<'_>) -> napi::Result<String> {
    serde_json::to_string(outcome)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing outcome: {e}")))
}
