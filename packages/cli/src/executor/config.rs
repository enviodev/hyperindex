use crate::{config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths};
use anyhow::{Context, Result};

pub fn run_view(parsed_project_paths: &ParsedProjectPaths) -> Result<()> {
    let config = SystemConfig::parse_from_project_files(parsed_project_paths)
        .context("Failed parsing config")?;
    println!("{}", config.to_view_json()?);
    Ok(())
}
