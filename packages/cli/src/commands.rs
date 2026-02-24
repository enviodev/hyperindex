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
    tokio::process::Command::new(cmd)
        .args(&args)
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

pub mod rescript {
    use super::execute_command;
    use anyhow::Result;
    use std::path::Path;

    pub async fn build(path: &Path) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript"];
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
    use super::{execute_command, to_js_path};
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::anyhow;
    use pathdiff::diff_paths;

    pub async fn start_indexer(config: &SystemConfig) -> anyhow::Result<()> {
        // Compute the relative path from project root to generated directory
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let index_path = format!("./{}/src/Index.res.mjs", to_js_path(&relative_generated));

        let cmd = "node";
        let args = vec!["--no-warnings", &index_path];

        // Run from project root to ensure proper cwd for handlers
        let exit =
            execute_command(cmd, args, &config.parsed_project_paths.project_root).await?;

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
pub mod docker {
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::anyhow;
    use std::io::ErrorKind;
    use std::path::Path;

    /// Result of trying to run a compose command
    enum RunResult {
        /// Command ran and exited with given status (output was visible to user)
        Exited(std::process::ExitStatus),
        /// Command binary not found
        NotFound,
        /// Other error spawning command
        SpawnError,
    }

    /// Try to run a compose command with visible output
    async fn run_compose(
        cmd: &str,
        compose_args: &[&str],
        current_dir: &Path,
        is_plugin: bool,
    ) -> RunResult {
        let args: Vec<&str> = if is_plugin {
            let mut v = vec!["compose"];
            v.extend(compose_args);
            v
        } else {
            compose_args.to_vec()
        };

        match tokio::process::Command::new(cmd)
            .args(&args)
            .current_dir(current_dir)
            .stdin(std::process::Stdio::null())
            // stdout/stderr inherited - user sees output
            .kill_on_drop(true)
            .spawn()
        {
            Ok(mut child) => match child.wait().await {
                Ok(status) => RunResult::Exited(status),
                Err(_) => RunResult::SpawnError,
            },
            Err(e) if e.kind() == ErrorKind::NotFound => RunResult::NotFound,
            Err(_) => RunResult::SpawnError,
        }
    }

    /// Check if compose plugin is available (silent, for fallback decisions)
    async fn has_compose_plugin(cmd: &str, is_plugin: bool) -> bool {
        let args: &[&str] = if is_plugin {
            &["compose", "version"]
        } else {
            &["version"]
        };

        match tokio::process::Command::new(cmd)
            .args(args)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
        {
            Ok(mut child) => child.wait().await.map(|s| s.success()).unwrap_or(false),
            Err(_) => false,
        }
    }

    /// Execute a compose command with automatic fallback.
    /// Tries docker compose first (happy path), then falls back to alternatives only if unavailable.
    async fn execute_compose_command(
        args: Vec<&str>,
        current_dir: &Path,
    ) -> anyhow::Result<std::process::ExitStatus> {
        // Tools to try in order: (command, is_plugin)
        let tools: &[(&str, bool)] = &[
            ("docker", true),          // docker compose (V2)
            ("docker-compose", false), // docker-compose (V1)
            ("podman", true),          // podman compose
            ("podman-compose", false), // podman-compose
        ];

        for &(cmd, is_plugin) in tools {
            match run_compose(cmd, &args, current_dir, is_plugin).await {
                RunResult::Exited(status) if status.success() => {
                    return Ok(status);
                }
                RunResult::Exited(status) => {
                    // Command ran but failed - check if compose is actually available
                    // If yes, this is a real error (user already saw output) - return it
                    // If no, the failure was due to missing compose plugin - try fallback
                    if has_compose_plugin(cmd, is_plugin).await {
                        return Ok(status);
                    }
                    // Compose not available, try next tool
                }
                RunResult::NotFound => {
                    // Binary not found, try next tool
                }
                RunResult::SpawnError => {
                    // Other spawn error (permissions, etc.), try next tool
                }
            }
        }

        Err(anyhow!(
            "Failed to start local development environment.\n\
             \n\
             A container compose tool is required. Supported options:\n\
             \n\
             • Docker Compose (recommended)\n\
               - Docker Desktop (includes Compose): https://docs.docker.com/desktop/\n\
               - Linux: sudo apt-get install docker-compose-plugin\n\
               - macOS: brew install docker-compose\n\
             \n\
             • Podman Compose\n\
               - Install: pip install podman-compose\n\
               - Or with Podman Desktop: https://podman-desktop.io/"
        ))
    }

    pub async fn docker_compose_up_d(
        config: &SystemConfig,
    ) -> anyhow::Result<std::process::ExitStatus> {
        let args = vec!["up", "-d"];
        let current_dir = &config.parsed_project_paths.generated;

        execute_compose_command(args, current_dir).await
    }

    pub async fn docker_compose_down_v(
        config: &SystemConfig,
    ) -> anyhow::Result<std::process::ExitStatus> {
        let args = vec!["down", "-v"];
        let current_dir = &config.parsed_project_paths.generated;

        execute_compose_command(args, current_dir).await
    }
}

pub mod db_migrate {
    use anyhow::{anyhow, Context};

    use std::process::ExitStatus;

    use super::{execute_command, to_js_path};
    use crate::{config_parsing::system_config::SystemConfig, persisted_state::PersistedState};
    use pathdiff::diff_paths;

    pub async fn run_up_migrations(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let migration_script = format!(
            "import(\"./{}/src/db/Migrations.res.mjs\").then(m => m.runUpMigrations(true))",
            to_js_path(&relative_generated)
        );
        let args = vec!["-e", &migration_script];
        let current_dir = &config.parsed_project_paths.project_root;
        let exit = execute_command("node", args, current_dir).await?;

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
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let migration_script = format!(
            "import(\"./{}/src/db/Migrations.res.mjs\").then(m => m.runDownMigrations(true))",
            to_js_path(&relative_generated)
        );
        let args = vec!["-e", &migration_script];
        let current_dir = &config.parsed_project_paths.project_root;
        execute_command("node", args, current_dir).await
    }

    pub async fn run_db_setup(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let migration_script = format!(
            "import(\"./{}/src/db/Migrations.res.mjs\").then(m => m.runUpMigrations(true, true))",
            to_js_path(&relative_generated)
        );
        let args = vec!["-e", &migration_script];
        let current_dir = &config.parsed_project_paths.project_root;
        let exit = execute_command("node", args, current_dir).await?;

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

pub mod benchmark {
    use super::{execute_command, to_js_path};
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::{anyhow, Result};
    use pathdiff::diff_paths;

    pub async fn print_summary(config: &SystemConfig) -> Result<()> {
        let relative_generated = diff_paths(
            &config.parsed_project_paths.generated,
            &config.parsed_project_paths.project_root,
        )
        .ok_or_else(|| anyhow!("Failed to compute relative path to generated directory"))?;

        let benchmark_script = format!(
            "import(\"./{}/src/Benchmark.res.mjs\").then(m => m.Summary.printSummary())",
            to_js_path(&relative_generated)
        );
        let args = vec!["-e", &benchmark_script];
        let current_dir = &config.parsed_project_paths.project_root;
        let exit = execute_command("node", args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!("Failed printing benchmark summary"));
        }

        Ok(())
    }
}

pub mod git {
    use super::execute_command;
    use anyhow::{anyhow, Result};
    use std::path::Path;

    /// Check if the given path is inside a git repository
    async fn is_inside_git_repo(path: &Path) -> bool {
        execute_command("git", vec!["rev-parse", "--is-inside-work-tree"], path)
            .await
            .map(|exit| exit.success())
            .unwrap_or(false)
    }

    /// Initialize a git repository if not already inside one
    pub async fn init(project_root: &Path) -> Result<()> {
        // Skip if already inside a git repository
        if is_inside_git_repo(project_root).await {
            return Ok(());
        }

        let exit = execute_command("git", vec!["init"], project_root).await?;

        if !exit.success() {
            return Err(anyhow!(
                "git init exited with code {}",
                exit.code().unwrap_or(-1)
            ));
        }

        Ok(())
    }
}
