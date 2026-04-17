use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    project_paths::ParsedProjectPaths,
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
    let project_paths = ParsedProjectPaths::new(&project_root, "generated", &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;
    let system_config = SystemConfig::parse_from_project_files(&project_paths)
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;
    system_config
        .to_public_config_json()
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

#[napi_derive::napi]
pub async fn run_cli(args: Vec<String>, envio_package_dir: Option<String>) -> napi::Result<i32> {
    set_envio_package_dir(&envio_package_dir);

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
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    crate::executor::execute(command_line_args)
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e}")))?;

    Ok(0)
}
