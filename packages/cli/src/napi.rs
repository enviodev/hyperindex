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
    /// Also generate the `.envio/types.d.ts` and `Indexer.res` contents, so a
    /// caller can type-check handlers against the config's generated `indexer`
    /// surface, or assert on the generated ReScript.
    pub with_indexer_types: Option<bool>,
}

#[napi_derive::napi(object)]
pub struct FromUserApiResult {
    /// The public config JSON, the same shape `get_config_json` returns.
    pub config: String,
    /// The generated `.envio/types.d.ts`, present only when
    /// `with_indexer_types` was requested.
    pub indexer_types: Option<String>,
    /// The generated `Indexer.res`, present only when `with_indexer_types` was
    /// requested and the config isn't SVM (which has no ReScript surface).
    /// Same production codegen output, from the same parse.
    pub indexer_code: Option<String>,
}

fn serialize_config_result(config: anyhow::Result<SystemConfig>) -> napi::Result<String> {
    let system_config = config.map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;
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
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let config_json = config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))?;

    let (indexer_types, indexer_code) = if options.with_indexer_types.unwrap_or(false) {
        let template = ProjectTemplate::from_config(&config).map_err(|e| {
            napi::Error::from_reason(format!("Failed generating indexer types: {e:#}"))
        })?;
        (
            Some(template.indexer_types_dts().to_string()),
            template.indexer_code().map(str::to_string),
        )
    } else {
        (None, None)
    };

    Ok(FromUserApiResult {
        config: config_json,
        indexer_types,
        indexer_code,
    })
}

#[napi_derive::napi]
pub fn load_ts(path: String) -> napi::Result<String> {
    crate::ts_loader::load(std::path::Path::new(&path)).map_err(napi::Error::from_reason)
}

#[napi_derive::napi]
pub fn ts_check_handler_format(path: String) -> napi::Result<()> {
    crate::ts_loader::check_handler_format(std::path::Path::new(&path))
        .map_err(napi::Error::from_reason)
}

#[napi_derive::napi]
pub fn ts_resolve_candidates(specifier: String, parent_url: Option<String>) -> Vec<String> {
    crate::ts_loader::resolve_candidates(&specifier, parent_url.as_deref())
}

#[napi_derive::napi]
pub fn ts_not_found_candidates(code: String, url: Option<String>, message: String) -> Vec<String> {
    crate::ts_loader::not_found_candidates(&code, url.as_deref(), &message)
}

/// Returns a JSON-encoded `Command` for JS to dispatch, or `None` when
/// Rust has handled the command end-to-end (help/version, codegen, init,
/// stop, docker up/down). The Node process then exits with code 0.
///
/// A command Rust finishes is reported to telemetry here; one it hands to JS
/// is reported by the runtime, through `telemetry_heartbeat` or
/// `telemetry_finish_command`.
#[napi_derive::napi]
pub async fn run_cli(
    args: Vec<String>,
    envio_package_dir: Option<String>,
    node_version: Option<String>,
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

    crate::telemetry::begin(&command_line_args, node_version.as_deref());
    let command = crate::executor::execute(command_line_args, envio_package_dir.as_deref()).await;
    match &command {
        Ok(Some(_)) => {}
        Ok(None) => crate::telemetry::finish_command(crate::telemetry::Outcome::Success, None),
        Err(err) => crate::telemetry::finish_command_with_error(err),
    }
    let command = command.map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    match command {
        None => Ok(None),
        Some(cmd) => serde_json::to_string(&cmd)
            .map(Some)
            .map_err(|e| napi::Error::from_reason(format!("Failed serializing command: {e}"))),
    }
}

#[napi_derive::napi(object)]
pub struct TelemetryHeartbeat {
    /// `start`, `interval` or `crash`.
    pub reason: String,
    /// Features only the running indexer sees, such as `effects`.
    pub features: Vec<String>,
    pub synced: bool,
    pub uptime_seconds: f64,
    pub events_processed: f64,
    /// Error counts by class since the previous heartbeat.
    pub errors: HashMap<String, u32>,
}

/// Sends nothing unless a `start` or `dev` in this process set up the
/// indexer's profile, and telemetry is on.
#[napi_derive::napi]
pub fn telemetry_heartbeat(heartbeat: TelemetryHeartbeat) {
    crate::telemetry::heartbeat(crate::telemetry::RuntimeReport {
        reason: &heartbeat.reason,
        features: &heartbeat.features,
        synced: heartbeat.synced,
        uptime_seconds: heartbeat.uptime_seconds,
        events_processed: heartbeat.events_processed,
        errors: &heartbeat.errors,
    });
}

/// Reports the command `run_cli` handed to JS, when it ends before the
/// indexer's first heartbeat: a migration, or a start that failed to come up.
#[napi_derive::napi]
pub fn telemetry_finish_command(error_class: Option<String>) {
    use std::str::FromStr;
    match error_class {
        None => crate::telemetry::finish_command(crate::telemetry::Outcome::Success, None),
        Some(class) => crate::telemetry::finish_command(
            crate::telemetry::Outcome::Failure,
            Some(
                crate::telemetry::ErrorClass::from_str(&class)
                    .unwrap_or(crate::telemetry::ErrorClass::Other),
            ),
        ),
    }
}
