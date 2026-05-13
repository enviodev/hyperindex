use crate::{
    config_parsing::{
        public_config_json::StorageConfig,
        system_config::{SystemConfig, VERSION},
    },
    project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigView<'a> {
    version: &'a str,
    storage: StorageConfig,
}

pub fn run_view(parsed_project_paths: &ParsedProjectPaths) -> Result<()> {
    let config = SystemConfig::parse_from_project_files(parsed_project_paths)
        .context("Failed parsing config")?;

    let payload = ConfigView {
        version: VERSION,
        storage: (&config.storage).into(),
    };

    println!(
        "{}",
        serde_json::to_string_pretty(&payload).context("Failed serializing config view JSON")?
    );
    Ok(())
}
