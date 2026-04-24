use crate::{
    commands, config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

pub async fn run_codegen(project_paths: &ParsedProjectPaths) -> Result<()> {
    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;

    commands::codegen::run_codegen(&config).await?;

    Ok(())
}
