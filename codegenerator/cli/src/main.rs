use anyhow::{Context, Result};
use clap::Parser;
use envio::{clap_definitions::CommandLineArgs, executor};

#[tokio::main]
async fn main() -> Result<()> {
    let command_line_args = CommandLineArgs::parse();
    executor::execute(command_line_args)
        .await
        .context("Failed cli execution")?;

    Ok(())
}
