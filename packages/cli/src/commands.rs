use anyhow::Context;
use std::path::Path;

/// Spawns `cmd` silently (stdout/stderr/stdin nulled).
async fn execute_command_silent(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    tokio::process::Command::new(cmd)
        .args(&args)
        .current_dir(current_dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context(format!(
            "Failed to spawn command {} {} at {} as child process",
            cmd,
            args.join(" "),
            current_dir.to_str().unwrap_or("bad_path")
        ))?
        .wait()
        .await
        .context(format!(
            "Failed to exit command {} {} at {} from child process",
            cmd,
            args.join(" "),
            current_dir.to_str().unwrap_or("bad_path")
        ))
}

pub mod codegen {
    use crate::{
        config_parsing::system_config::SystemConfig, hbs_templating, template_dirs::TemplateDirs,
    };
    use anyhow::{self, Context, Result};
    use std::path::Path;

    use tokio::fs;

    pub async fn remove_files_except_git(directory: &Path) -> Result<()> {
        let mut entries = fs::read_dir(directory).await?;
        while let Some(entry) = entries.next_entry().await? {
            let file_type = entry.file_type().await?;
            let path = entry.path();

            if path.ends_with(".git") {
                continue;
            }

            if file_type.is_dir() {
                fs::remove_dir_all(&path).await?;
            } else {
                fs::remove_file(&path).await?;
            }
        }

        Ok(())
    }

    pub async fn run_codegen(config: &SystemConfig) -> anyhow::Result<()> {
        let template_dirs = TemplateDirs::new();
        fs::create_dir_all(&config.parsed_project_paths.generated).await?;

        let template = hbs_templating::codegen_templates::ProjectTemplate::from_config(config)
            .context("Failed creating project template")?;

        template_dirs
            .get_codegen_static_dir()?
            .extract(&config.parsed_project_paths.generated)
            .context("Failed extracting static codegen files")?;

        template
            .generate_templates(&config.parsed_project_paths)
            .context("Failed generating dynamic codegen files")?;

        Ok(())
    }
}

pub mod git {
    use super::execute_command_silent;
    use anyhow::{anyhow, Result};
    use std::path::Path;

    /// Check if the given path is inside a git repository
    async fn is_inside_git_repo(path: &Path) -> bool {
        execute_command_silent("git", vec!["rev-parse", "--is-inside-work-tree"], path)
            .await
            .map(|exit| exit.success())
            .unwrap_or(false)
    }

    /// Initialize a git repository if not already inside one.
    /// Returns true if a new repository was created, false if already inside one.
    pub async fn init(project_root: &Path) -> Result<bool> {
        // Skip if already inside a git repository
        if is_inside_git_repo(project_root).await {
            return Ok(false);
        }

        let exit = execute_command_silent("git", vec!["init"], project_root).await?;

        if !exit.success() {
            return Err(anyhow!(
                "git init exited with code {}",
                exit.code().unwrap_or(-1)
            ));
        }

        Ok(true)
    }
}
