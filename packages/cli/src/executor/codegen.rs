use crate::{
    commands, config_parsing::system_config::SystemConfig, project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

/// Purge `generated/` and re-run codegen against the already-parsed config.
/// Shared by `envio dev` and `envio start` so both paths regenerate from a
/// clean slate before handing off to JS.
pub async fn purge_and_run(config: &SystemConfig) -> Result<()> {
    let generated = &config.parsed_project_paths.generated;
    // First-run / freshly-checked-out projects don't have a `generated/` yet;
    // `run_codegen` will create it. Only purge when it already exists.
    if generated.exists() {
        commands::codegen::remove_files_except_git(generated)
            .await
            .context("Failed purging generated")?;
    }
    commands::codegen::run_codegen(config)
        .await
        .context("Failed running codegen")?;
    Ok(())
}

pub async fn run_codegen(project_paths: &ParsedProjectPaths) -> Result<()> {
    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;
    purge_and_run(&config).await
}
