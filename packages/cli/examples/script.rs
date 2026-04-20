// Dev-only entry point for `envio script ...` subcommands
// (`print-config-json-schema`, `print-cli-help-md`, `print-missing-networks`).
//
// The envio crate is a NAPI cdylib — real user flows run inside a Node host
// (`packages/envio/bin.mjs`). These scripts exist purely to regenerate
// committed build artifacts (json schemas, CommandLineHelp.md) from the
// Makefile, so they live as a cargo example instead of a standalone bin.
//
// Invoked via: `cargo run --example script -- script <subcommand>`
use anyhow::{Context, Result};
use clap::{CommandFactory, FromArgMatches};
use envio::{
    clap_definitions::{CommandLineArgs, CommandType},
    config_parsing::system_config::VERSION,
    executor,
};

#[tokio::main]
async fn main() -> Result<()> {
    let command_line_args = CommandLineArgs::from_arg_matches(
        &CommandLineArgs::command().version(VERSION).get_matches(),
    )
    .context("Failed parsing command line arguments")?;

    // Guard against accidental misuse — only `script` subcommands go through
    // this path. Everything else (init/codegen/dev/start/...) runs via the
    // NAPI host and would be missing the JS dispatch side if invoked here.
    if !matches!(command_line_args.command, CommandType::Script(_)) {
        anyhow::bail!(
            "This example only supports `script` subcommands. Run envio via the NAPI host \
             (packages/envio/bin.mjs) for init/codegen/dev/start/etc."
        );
    }

    executor::execute(command_line_args, None)
        .await
        .context("Failed cli execution")?;

    Ok(())
}
