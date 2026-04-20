use crate::config_parsing::system_config::SystemConfig;
use anyhow::Context;
use std::path::Path;

/// Convert a path to a JS-compatible string with forward slashes.
/// PathBuf::display() emits platform-specific separators (backslashes on Windows)
/// which break JS imports. This helper ensures forward slashes for JS paths.
fn to_js_path(path: &Path) -> String {
    path.display().to_string().replace('\\', "/")
}

/// Produce the resolved public config as a `serde_json::Value` for embedding
/// in a `Command` payload. Parsing this once in Rust lets the JS host skip
/// the `getConfigJson` NAPI round-trip when it receives the command. The
/// NAPI endpoint is still kept for indexers that start outside the CLI flow.
fn resolved_config_json(config: &SystemConfig) -> anyhow::Result<serde_json::Value> {
    let json_string = config
        .to_public_config_json()
        .context("Failed serializing resolved config")?;
    serde_json::from_str(&json_string).context("Failed re-parsing resolved config")
}

async fn execute_command(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    execute_command_with_env(cmd, args, current_dir, &[]).await
}

/// Like execute_command, but lets the caller inject extra env vars into the
/// child process without clobbering the inherited environment. Used by the
/// dev flow to forward credentials for containers we just booted.
///
/// Precedence: `extra_env` values override identically-named vars inherited
/// from the parent process (including those loaded from `.env`).
async fn execute_command_with_env(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
    extra_env: &[(String, String)],
) -> anyhow::Result<std::process::ExitStatus> {
    tokio::process::Command::new(cmd)
        .args(&args)
        .envs(extra_env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .current_dir(current_dir)
        .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
        .kill_on_drop(true) //needed so that dropped threads calling this will also drop
        //the child process
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

/// Like execute_command, but suppresses stdout and stderr
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

pub mod rescript {
    use super::execute_command;
    use anyhow::Result;
    use std::path::Path;

    pub async fn build(path: &Path) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript-legacy"];
        execute_command("pnpm", args, path).await
    }
}

pub mod codegen {
    use super::{execute_command, rescript};
    use crate::{
        config_parsing::system_config::SystemConfig, hbs_templating, template_dirs::TemplateDirs,
    };
    use anyhow::{self, Context, Result};
    use std::path::Path;

    use crate::project_paths::ParsedProjectPaths;
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

    pub async fn check_and_install_pnpm(current_dir: &Path) -> Result<()> {
        // Check if pnpm is already installed
        let check_pnpm = execute_command("pnpm", vec!["--version"], current_dir).await;

        // If pnpm is not installed, run the installation command
        match check_pnpm {
            Ok(status) if status.success() => {
                println!("Package pnpm is already installed. Continuing...");
            }
            _ => {
                println!("Package pnpm is not installed. Installing now...");
                let args = vec!["install", "--global", "pnpm"];
                execute_command("npm", args, current_dir).await?;
            }
        }
        Ok(())
    }

    async fn pnpm_install(project_paths: &ParsedProjectPaths) -> Result<std::process::ExitStatus> {
        println!("Checking for pnpm package...");
        check_and_install_pnpm(&project_paths.generated).await?;

        execute_command(
            "pnpm",
            vec!["install", "--no-lockfile", "--prefer-offline"],
            &project_paths.generated,
        )
        .await?;
        execute_command(
            "pnpm",
            vec!["install", "--no-frozen-lockfile", "--prefer-offline"],
            &project_paths.project_root,
        )
        .await
    }

    async fn run_post_codegen_command_sequence(
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<std::process::ExitStatus> {
        println!("Installing packages... ");
        let exit1 = pnpm_install(project_paths).await?;
        if !exit1.success() {
            return Ok(exit1);
        }

        println!("Generating HyperIndex code...");
        let exit3 = rescript::build(&project_paths.generated)
            .await
            .context("Failed running rescript build")?;
        if !exit3.success() {
            return Ok(exit3);
        }

        Ok(exit3)
    }

    pub async fn run_codegen(
        config: &SystemConfig,
        envio_package_dir: Option<&str>,
    ) -> anyhow::Result<()> {
        let template_dirs = TemplateDirs::new();
        fs::create_dir_all(&config.parsed_project_paths.generated).await?;

        let template = hbs_templating::codegen_templates::ProjectTemplate::from_config(
            config,
            envio_package_dir,
        )
        .context("Failed creating project template")?;

        template_dirs
            .get_codegen_static_dir()?
            .extract(&config.parsed_project_paths.generated)
            .context("Failed extracting static codegen files")?;

        template
            .generate_templates(&config.parsed_project_paths)
            .context("Failed generating dynamic codegen files")?;

        run_post_codegen_command_sequence(&config.parsed_project_paths)
            .await
            .context("Failed running post codegen command sequence")?;

        Ok(())
    }
}

pub mod start {
    use super::to_js_path;
    use crate::{config_parsing::system_config::SystemConfig, executor::Command};
    use anyhow::anyhow;
    use pathdiff::diff_paths;

    pub async fn start_indexer(
        config: &SystemConfig,
        extra_env: &[(String, String)],
    ) -> anyhow::Result<Command> {
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let index_path = format!("./{}/src/Index.res.mjs", to_js_path(&relative_generated));

        let abs_index_path = config
            .parsed_project_paths
            .project_root
            .join(&index_path)
            .canonicalize()
            .unwrap_or_else(|_| config.parsed_project_paths.project_root.join(&index_path));

        let config_path = config
            .parsed_project_paths
            .config
            .to_string_lossy()
            .into_owned();

        let mut env_map = serde_json::Map::new();
        env_map.insert("ENVIO_CONFIG".to_string(), config_path.into());
        for (k, v) in extra_env {
            env_map.insert(k.clone(), v.clone().into());
        }

        Ok(Command::new(
            "start-indexer",
            serde_json::json!({
                "indexPath": to_js_path(&abs_index_path),
                "cwd": config.parsed_project_paths.project_root.to_string_lossy(),
                "env": env_map,
                "config": super::resolved_config_json(config)?,
            }),
        ))
    }
}
pub mod db_migrate {
    use crate::{
        config_parsing::system_config::SystemConfig, executor::Command,
        persisted_state::PersistedState,
    };

    pub async fn run_up_migrations(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<Command> {
        Ok(Command::new(
            "migration-up",
            serde_json::json!({
                "reset": false,
                "persistedState": persisted_state,
                "config": super::resolved_config_json(config)?,
            }),
        ))
    }

    pub async fn run_drop_schema(config: &SystemConfig) -> anyhow::Result<Command> {
        Ok(Command::new(
            "migration-down",
            serde_json::json!({
                "config": super::resolved_config_json(config)?,
            }),
        ))
    }

    pub async fn run_db_setup(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<Command> {
        Ok(Command::new(
            "migration-up",
            serde_json::json!({
                "reset": true,
                "persistedState": persisted_state,
                "config": super::resolved_config_json(config)?,
            }),
        ))
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
