use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    hbs_templating::codegen_templates::ProjectTemplate, project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};
use std::collections::HashMap;

#[derive(Default)]
#[napi_derive::napi(object)]
pub struct FromUserApiOptions {
    pub schema: Option<String>,
    pub env: Option<HashMap<String, String>>,
    pub files: Option<HashMap<String, String>>,
    /// Also generate the `.envio/types.d.ts` contents, so a caller can
    /// type-check handlers against the config's generated `indexer` surface.
    pub with_indexer_types: Option<bool>,
}

#[napi_derive::napi(object)]
pub struct FromUserApiResult {
    /// The public config JSON, the same shape `get_config_json` returns.
    pub config: String,
    /// The generated `.envio/types.d.ts`, present only when
    /// `with_indexer_types` was requested.
    pub indexer_types: Option<String>,
}

fn serialize_config_result(config: anyhow::Result<SystemConfig>) -> napi::Result<String> {
    let system_config =
        config.map_err(|e| napi::Error::from_reason(format!("Config parse error: {e:#}")))?;
    system_config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

#[napi_derive::napi]
pub fn get_config_json(
    config_path: Option<String>,
    directory: Option<String>,
) -> napi::Result<String> {
    let project_root = directory.unwrap_or_else(|| ".".to_string());
    let config = config_path
        .or_else(|| std::env::var("ENVIO_CONFIG").ok())
        .unwrap_or_else(|| "config.yaml".to_string());
    let project_paths = ParsedProjectPaths::new(&project_root, &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;
    serialize_config_result(SystemConfig::parse_from_project_files(&project_paths))
}

/// Parses an inline indexer config the way a user's project would, without
/// consulting the filesystem or process environment. Schema text, interpolation
/// variables, and ABI/IDL file bodies are supplied explicitly so callers can use
/// this from any working directory. With `with_indexer_types`, also returns the
/// generated `.envio/types.d.ts` — the same TypeScript production codegen writes
/// — from the single parse, so a caller can type-check handlers against the
/// config's `indexer` surface without re-parsing.
#[napi_derive::napi]
pub fn from_user_api(
    yaml: String,
    options: Option<FromUserApiOptions>,
) -> napi::Result<FromUserApiResult> {
    let options = options.unwrap_or_default();
    let env = options.env.unwrap_or_default();
    let files = options.files.unwrap_or_default();
    let config = SystemConfig::parse_yaml(&yaml, options.schema.as_deref(), &env, &files, false)
        .map_err(|e| napi::Error::from_reason(format!("Config parse error: {e:#}")))?;

    let config_json = config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))?;

    let indexer_types = if options.with_indexer_types.unwrap_or(false) {
        let template = ProjectTemplate::from_config(&config).map_err(|e| {
            napi::Error::from_reason(format!("Failed generating indexer types: {e:#}"))
        })?;
        Some(template.indexer_types_dts().to_string())
    } else {
        None
    };

    Ok(FromUserApiResult {
        config: config_json,
        indexer_types,
    })
}

/// Requests graceful shutdown of a Rust-owned long-running command. Node
/// installs the process signal handlers because libuv owns SIGINT/SIGTERM in
/// the CLI host; Tokio's OS signal future alone is not notified reliably when
/// it runs inside the NAPI async runtime.
#[napi_derive::napi]
pub fn request_shutdown() {
    crate::serve::request_shutdown();
}

/// Returns a JSON-encoded `Command` for JS to dispatch, or `None` when
/// Rust has handled the command end-to-end (help/version, codegen, init,
/// serve, stop, docker up/down). The Node process then exits with code 0.
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
