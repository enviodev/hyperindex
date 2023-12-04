use anyhow::{Context, Result};
use clap::Parser;
use envio::{clap_definitions::CommandLineArgs, executor};

#[tokio::main]
async fn main() -> Result<()> {
    let command_line_args = CommandLineArgs::try_parse().context("Failed parsing cli args")?;
    executor::execute(command_line_args)
        .await
        .context("Failed cli execution")?;

    Ok(())
}
