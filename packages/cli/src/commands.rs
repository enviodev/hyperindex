use anyhow::Context;
use std::path::Path;

/// Convert a path to a JS-compatible string with forward slashes.
/// PathBuf::display() emits platform-specific separators (backslashes on Windows)
/// which break JS imports. This helper ensures forward slashes for JS paths.
fn to_js_path(path: &Path) -> String {
    path.display().to_string().replace('\\', "/")
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

        run_post_codegen_command_sequence(&config.parsed_project_paths)
            .await
            .context("Failed running post codegen command sequence")?;

        Ok(())
    }
}

pub mod start {
    use super::{execute_command_with_env, to_js_path};
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::anyhow;
    use pathdiff::diff_paths;

    pub async fn start_indexer(
        config: &SystemConfig,
        extra_env: &[(String, String)],
    ) -> anyhow::Result<()> {
        // Compute the relative path from project root to generated directory
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let index_path = format!("./{}/src/Index.res.mjs", to_js_path(&relative_generated));

        let cmd = "node";
        let args = vec!["--no-warnings", &index_path];

        // Forward the resolved config.yaml path so the NAPI addon in the
        // child Node process finds the same file.
        let config_path = config
            .parsed_project_paths
            .config
            .to_string_lossy()
            .into_owned();
        let mut env: Vec<(String, String)> = extra_env.to_vec();
        env.push(("ENVIO_CONFIG".to_string(), config_path));

        // Run from project root to ensure proper cwd for handlers
        let exit =
            execute_command_with_env(cmd, args, &config.parsed_project_paths.project_root, &env)
                .await?;

        if !exit.success() {
            return Err(anyhow!(
                "Indexer crashed. For more details see the error logs above the TUI. Can't find \
                 them? Restart the indexer with the 'TUI_OFF=true envio start' command."
            ));
        }
        println!(
            "\nIndexer has successfully finished processing all events on all chains. Exiting \
             process."
        );
        Ok(())
    }
}
pub mod db_migrate {
    use anyhow::{anyhow, Context};

    use std::process::ExitStatus;

    use crate::{config_parsing::system_config::SystemConfig, persisted_state::PersistedState};

    async fn execute_migration(script: &str, config: &SystemConfig) -> anyhow::Result<ExitStatus> {
        // The Node runtime loads config in-process via the NAPI addon
        // (Core.getConfigJson → Config.fromConfigView). We forward the
        // config.yaml path through `ENVIO_CONFIG` so the addon finds the
        // same file even when cwd differs.
        let current_dir = &config.parsed_project_paths.project_root;
        let config_path = config
            .parsed_project_paths
            .config
            .to_string_lossy()
            .into_owned();
        tokio::process::Command::new("node")
            .args(["-e", script])
            .env("ENVIO_CONFIG", &config_path)
            .current_dir(current_dir)
            .stdin(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("Failed to spawn node process for migration")?
            .wait()
            .await
            .context("Failed to wait for migration process")
    }

    pub async fn run_up_migrations(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let exit = execute_migration(
            "import('envio/src/Migrations.res.mjs').then(m => m.runUpMigrations(true))",
            config,
        )
        .await?;

        if !exit.success() {
            return Err(anyhow!("Failed to run db migrations"));
        }

        persisted_state
            .upsert_to_db()
            .await
            .context("Failed to upsert persisted state table")?;
        Ok(())
    }

    pub async fn run_drop_schema(config: &SystemConfig) -> anyhow::Result<ExitStatus> {
        execute_migration(
            "import('envio/src/Migrations.res.mjs').then(m => m.runDownMigrations(true))",
            config,
        )
        .await
    }

    pub async fn run_db_setup(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let exit = execute_migration(
            "import('envio/src/Migrations.res.mjs').then(m => m.runUpMigrations(true, true))",
            config,
        )
        .await?;

        if !exit.success() {
            return Err(anyhow!("Failed to run db migrations"));
        }

        persisted_state
            .upsert_to_db()
            .await
            .context("Failed to upsert persisted state table")?;
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
