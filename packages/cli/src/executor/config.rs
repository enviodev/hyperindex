use crate::config_parsing::system_config::VERSION;
use anyhow::{Context, Result};

pub fn run_view() -> Result<()> {
    let payload = serde_json::json!({ "version": VERSION });
    println!(
        "{}",
        serde_json::to_string_pretty(&payload).context("Failed serializing config view JSON")?
    );
    Ok(())
}
