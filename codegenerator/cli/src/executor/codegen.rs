use crate::{
    commands,
    config_parsing::system_config::SystemConfig,
    persisted_state::{PersistedStateExists, CURRENT_CRATE_VERSION},
    project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

pub async fn run_codegen(project_paths: &ParsedProjectPaths) -> Result<()> {
    //Manage purging of gengerated folder
    match PersistedStateExists::get_persisted_state_file(&project_paths) {
        PersistedStateExists::Exists(ps) if &ps.envio_version != CURRENT_CRATE_VERSION => {
            println!(
                "Envio version '{}' does not match the previous version '{}' used in the \
                 generated directory",
                CURRENT_CRATE_VERSION, &ps.envio_version
            );
            println!("Purging generated directory",);
            commands::codegen::remove_files_except_git(&project_paths.generated)
                .await
                .context("Failed purging generated")?;
        }
        _ => (),
    };

    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;

    commands::codegen::run_codegen(&config, project_paths).await?;

    Ok(())
}
