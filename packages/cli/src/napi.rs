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
) -> napi::Result<String> {
    let project_root = directory.unwrap_or_else(|| ".".to_string());
    let config = config_path
        .or_else(|| std::env::var("ENVIO_CONFIG").ok())
        .unwrap_or_else(|| "config.yaml".to_string());
    // Error messages intentionally omit absolute paths (cwd / resolved config
    // path) — the JS caller already knows its cwd and what it passed in, and
    // we don't want to leak filesystem layout into logs shipped off-host.
    let project_paths = ParsedProjectPaths::new(&project_root, "generated", &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;
    let system_config = SystemConfig::parse_from_project_files(&project_paths)
        .map_err(|e| napi::Error::from_reason(format!("Config parse error: {e}")))?;
    system_config
        .to_public_config_json()
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

/// Returns a JSON-encoded `Command` for JS to dispatch, or `None` when
/// Rust has handled the command end-to-end (help/version, codegen, init,
/// stop, docker up/down). The Node process then exits with code 0.
#[napi_derive::napi]
pub async fn run_cli(
    args: Vec<String>,
    envio_package_dir: Option<String>,
) -> napi::Result<Option<String>> {
    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = match CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
    {
        Ok(m) => m,
        Err(e) if !e.use_stderr() => {
            // Help / version — clap writes to stdout; nothing for JS to do.
            print!("{e}");
            return Ok(None);
        }
        Err(e) => return Err(napi::Error::from_reason(format!("{e}"))),
    };

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let command = crate::executor::execute(command_line_args, envio_package_dir.as_deref())
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    match command {
        None => Ok(None),
        Some(cmd) => serde_json::to_string(&cmd)
            .map(Some)
            .map_err(|e| napi::Error::from_reason(format!("Failed serializing command: {e}"))),
    }
}
