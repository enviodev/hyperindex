use clap::Parser;
use envio::{cli_args::CommandLineArgs, executor};

use anyhow::{Context, Result};

#[tokio::main]
async fn main() -> Result<()> {
    let command_line_args = CommandLineArgs::try_parse().context("Failed parsing cli args")?;
    executor::execute(command_line_args)
        .await
        .context("Failed cli execution")?;

    Ok(())
}
