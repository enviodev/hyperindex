use crate::{
    commands, config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

pub async fn run_codegen(project_paths: &ParsedProjectPaths) -> Result<()> {
    // Always purge the generated directory: there's no longer a persisted
    // version stamp to diff against, and the JS runtime handles DB
    // compatibility separately via `envio_info`.
    commands::codegen::remove_files_except_git(&project_paths.generated)
        .await
        .context("Failed purging generated")?;

    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;

    commands::codegen::run_codegen(&config).await?;

    Ok(())
}
