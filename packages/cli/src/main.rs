use anyhow::{Context, Result};
use clap::{CommandFactory, FromArgMatches};
use envio::{clap_definitions::CommandLineArgs, config_parsing::system_config::VERSION, executor};

// Standalone binary used only for `script` subcommands (Makefile uses it
// for `print-config-json-schema`, `print-cli-help-md`, `print-missing-networks`).
// Real user flows (init / codegen / dev / start) run via the NAPI host.
//
// We pass `envio_package_dir = None`: those script paths don't call
// `get_envio_version`, so there's nothing to resolve; a user accidentally
// running init/codegen via the binary gets a clear error from `get_envio_version`
// instead of a guessy filesystem walk.
#[tokio::main]
async fn main() -> Result<()> {
    let command_line_args = CommandLineArgs::from_arg_matches(
        &CommandLineArgs::command().version(VERSION).get_matches(),
    )
    .context("Failed parsing command line arguments")?;
    executor::execute(command_line_args, None)
        .await
        .context("Failed cli execution")?;

    Ok(())
}
