use crate::{
    commands,
    config_parsing::{human_config, system_config::SystemConfig},
    project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

pub async fn run_codegen(project_paths: &ParsedProjectPaths) -> Result<()> {
    let yaml_config = human_config::deserialize_config_from_yaml(&project_paths.config)
        .context("Failed deserializing config")?;

    let config = SystemConfig::parse_from_human_config(&yaml_config, project_paths)
        .context("Failed parsing config")?;

    commands::codegen::run_codegen(&config, project_paths).await?;
    commands::codegen::run_post_codegen_command_sequence(&project_paths).await?;

    Ok(())
}
