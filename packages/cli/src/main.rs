use anyhow::{Context, Result};
use clap::{CommandFactory, FromArgMatches};
use envio::{
    clap_definitions::CommandLineArgs,
    config_parsing::system_config::read_version_from_package_json, executor,
};

fn runtime_version() -> &'static str {
    static VERSION: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    VERSION.get_or_init(|| {
        read_version_from_package_json().unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string())
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    let command_line_args = CommandLineArgs::from_arg_matches(
        &CommandLineArgs::command()
            .version(runtime_version())
            .get_matches(),
    )
    .context("Failed parsing command line arguments")?;
    executor::execute(command_line_args)
        .await
        .context("Failed cli execution")?;

    Ok(())
}
