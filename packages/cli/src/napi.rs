use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};

/// Set up the envio package directory for version resolution.
///
/// When running as a NAPI addon, `get_envio_version()` can't find
/// `packages/envio` by walking up from `current_exe()` (which is Node)
/// or `current_dir()` (which may be a temp dir). The JS caller passes
/// its own package directory (resolved from `import.meta.url`) so Rust
/// can find it.
fn set_envio_package_dir(dir: &Option<String>) {
    if let Some(d) = dir {
        std::env::set_var("ENVIO_PACKAGE_DIR", d);
    }
}

/// Get the resolved indexer config as a JSON string.
///
/// Synchronous — no tokio runtime needed. Reads `config.yaml` (or the path
/// given in `config_path` / `ENVIO_CONFIG` env var), parses it through the
/// full `SystemConfig` pipeline, and serialises the public config JSON that
/// the Node runtime consumes.
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

/// Run the envio CLI with the given arguments.
///
/// Async — NAPI manages the tokio runtime automatically. This is the entry
/// point used by `bin.mjs` to run any CLI command in-process (no child
/// process spawn).
#[napi_derive::napi]
pub async fn run_cli(args: Vec<String>, envio_package_dir: Option<String>) -> napi::Result<i32> {
    set_envio_package_dir(&envio_package_dir);

    // Prepend a fake argv[0] so clap's arg parser sees the expected layout
    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
        .map_err(|e| {
            // Clap prints help/version to stdout and returns Err — surface
            // these as a zero-exit rather than an error.
            if e.use_stderr() {
                napi::Error::from_reason(format!("{e}"))
            } else {
                print!("{e}");
                napi::Error::from_reason("__exit_0__".to_string())
            }
        })?;

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    crate::executor::execute(command_line_args)
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    Ok(0)
}
