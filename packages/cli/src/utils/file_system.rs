use anyhow::{Context, Result};
use std::{fs, path::PathBuf};

pub async fn write_file_string_to_system(file_string: String, fs_file_path: PathBuf) -> Result<()> {
    let file_path_str = fs_file_path.to_str().unwrap_or("unknown file path");
    // Create the directory if it doesn't exist
    if let Some(parent_dir) = fs_file_path.parent() {
        fs::create_dir_all(parent_dir)
            .with_context(|| format!("Failed to create directory for {} file", file_path_str))?;
    }
    fs::write(&fs_file_path, file_string)
        .with_context(|| format!("Failed to write {} file", file_path_str))?;

    Ok(())
}
