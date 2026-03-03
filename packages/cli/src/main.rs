use anyhow::{Context, Result};
use clap::{CommandFactory, FromArgMatches};
use envio::{
    clap_definitions::CommandLineArgs,
    config_parsing::system_config::runtime_version, executor,
};

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
