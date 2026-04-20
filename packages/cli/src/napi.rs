use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};

#[napi_derive::napi]
pub fn get_config_json(
    config_path: Option<String>,
    directory: Option<String>,
    _envio_package_dir: Option<String>,
) -> napi::Result<String> {
    // `_envio_package_dir` is accepted for NAPI signature compatibility but
    // unused here — `get_config_json` doesn't need the envio JS package
    // location. It's threaded through `run_cli` for `get_envio_version`.
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

/// Run the envio CLI. Returns a JSON-encoded array of `Command`s for JS to
/// dispatch in order. An empty array means there's nothing left to do — JS
/// drops out of its loop and the Node process exits naturally with code 0
/// (covers both `--help`/`--version` and commands like `envio codegen` /
/// `envio init` that finish entirely in Rust).
///
/// The executor layer doesn't know about NAPI; it returns a `Vec<Command>`
/// that this shim serializes for the JS host. A pure-Rust host (tests,
/// future binary) could consume the same return value directly.
#[napi_derive::napi]
pub async fn run_cli(args: Vec<String>, envio_package_dir: Option<String>) -> napi::Result<String> {
    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = match CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
    {
        Ok(m) => m,
        Err(e) if !e.use_stderr() => {
            // Help / version — clap writes to stdout; return an empty
            // command list so JS exits cleanly.
            print!("{e}");
            return serialize_commands(&[]);
        }
        Err(e) => return Err(napi::Error::from_reason(format!("{e}"))),
    };

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let commands = crate::executor::execute(command_line_args, envio_package_dir.as_deref())
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    serialize_commands(&commands)
}

fn serialize_commands(commands: &[crate::executor::Command]) -> napi::Result<String> {
    serde_json::to_string(commands)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing commands: {e}")))
}
