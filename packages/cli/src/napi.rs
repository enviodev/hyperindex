use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    hbs_templating::codegen_templates::ProjectTemplate, project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};
use std::collections::HashMap;

#[derive(Default)]
#[napi_derive::napi(object)]
pub struct ParseConfigYamlOptions {
    pub schema: Option<String>,
    pub env: Option<HashMap<String, String>>,
    pub files: Option<HashMap<String, String>>,
    pub is_rescript: Option<bool>,
}

fn serialize_config_result(config: anyhow::Result<SystemConfig>) -> napi::Result<String> {
    let system_config =
        config.map_err(|e| napi::Error::from_reason(format!("Config parse error: {e:#}")))?;
    system_config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

fn parse_yaml_from_options(
    yaml: &str,
    options: ParseConfigYamlOptions,
) -> anyhow::Result<SystemConfig> {
    let env = options.env.unwrap_or_default();
    let files = options.files.unwrap_or_default();
    SystemConfig::parse_yaml(
        yaml,
        options.schema.as_deref(),
        &env,
        &files,
        options.is_rescript.unwrap_or(false),
    )
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

/// Parses an indexer config without consulting the filesystem or process
/// environment. Schema text, interpolation variables, and ABI/IDL file bodies
/// are supplied explicitly so callers can use this from any working directory.
#[napi_derive::napi]
pub fn parse_config_yaml(
    yaml: String,
    options: Option<ParseConfigYamlOptions>,
) -> napi::Result<String> {
    serialize_config_result(parse_yaml_from_options(&yaml, options.unwrap_or_default()))
}

/// Generates the `.envio/types.d.ts` contents for an inline config, without
/// touching the filesystem. Mirrors `parse_config_yaml`'s inputs; returns the
/// same TypeScript the production codegen writes, so a caller can type-check
/// handlers against a config's generated `indexer` surface.
#[napi_derive::napi]
pub fn generate_indexer_types(
    yaml: String,
    options: Option<ParseConfigYamlOptions>,
) -> napi::Result<String> {
    let config = parse_yaml_from_options(&yaml, options.unwrap_or_default())
        .map_err(|e| napi::Error::from_reason(format!("Config parse error: {e:#}")))?;
    let template = ProjectTemplate::from_config(&config)
        .map_err(|e| napi::Error::from_reason(format!("Failed generating indexer types: {e:#}")))?;
    Ok(template.indexer_types_dts().to_string())
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
