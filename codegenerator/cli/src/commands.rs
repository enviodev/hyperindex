use anyhow::Context;
use std::path::Path;

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

/// Execute a command with String arguments (needed for dynamic package manager commands)
async fn execute_command_string_args(
    cmd: &str,
    args: Vec<String>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    execute_command(cmd, args_refs, current_dir).await
}

pub mod rescript {
    use super::execute_command_string_args;
    use crate::package_manager::PackageManagerConfig;
    use anyhow::Result;
    use std::path::Path;

    pub async fn build(
        path: &Path,
        pm_config: &PackageManagerConfig,
    ) -> Result<std::process::ExitStatus> {
        let pm = &pm_config.package_manager;
        execute_command_string_args(pm.command(), pm.run_script_args("rescript"), path).await
    }
}

pub mod codegen {
    use super::{execute_command, rescript};
    use crate::{
        config_parsing::system_config::SystemConfig, hbs_templating,
        package_manager::PackageManagerConfig, template_dirs::TemplateDirs,
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

    /// Check if the package manager is available, and auto-install if supported
    pub async fn check_package_manager(
        pm_config: &PackageManagerConfig,
        current_dir: &Path,
    ) -> Result<()> {
        let pm = &pm_config.package_manager;
        let check = execute_command(pm.command(), vec!["--version"], current_dir).await;

        match check {
            Ok(status) if status.success() => {
                println!("{} is available. Continuing...", pm.display_name());
            }
            _ => {
                if pm.can_auto_install() {
                    println!(
                        "{} is not installed. Installing now...",
                        pm.display_name()
                    );
                    let args = vec!["install", "--global", pm.command()];
                    execute_command("npm", args, current_dir).await?;
                } else {
                    return Err(anyhow::anyhow!(
                        "{} is not installed. Please install it first.",
                        pm.display_name()
                    ));
                }
            }
        }
        Ok(())
    }

    async fn install_dependencies(
        project_paths: &ParsedProjectPaths,
        pm_config: &PackageManagerConfig,
    ) -> Result<std::process::ExitStatus> {
        let pm = &pm_config.package_manager;
        println!("Checking for {} package...", pm.display_name());
        check_package_manager(pm_config, &project_paths.generated).await?;

        // Install in generated directory (without lockfile)
        execute_command(
            pm.command(),
            pm.install_args_no_lockfile(),
            &project_paths.generated,
        )
        .await?;

        // Install in project root (with lockfile preservation)
        execute_command(
            pm.command(),
            pm.install_args_optimized(),
            &project_paths.project_root,
        )
        .await
    }

    /// Fix the node_modules/generated symlink for bun projects.
    ///
    /// Bun copies local file dependencies instead of symlinking them, which causes
    /// module duplication issues when the handler files import from "generated".
    /// This ensures node_modules/generated is a symlink to ./generated.
    fn fix_bun_generated_symlink(project_paths: &ParsedProjectPaths) -> anyhow::Result<()> {
        let node_modules_generated = project_paths.project_root.join("node_modules/generated");

        // Check if node_modules/generated exists
        if node_modules_generated.exists() {
            // Check if it's already a symlink
            if node_modules_generated.is_symlink() {
                // Already a symlink, nothing to do
                return Ok(());
            }

            // It's a directory (bun copied instead of symlinking)
            // Remove the directory
            std::fs::remove_dir_all(&node_modules_generated).with_context(|| {
                format!(
                    "Failed to remove node_modules/generated directory at {}",
                    node_modules_generated.display()
                )
            })?;
        }

        // Create symlink from node_modules/generated -> ../generated
        // Use relative path for portability
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("../generated", &node_modules_generated).with_context(
                || {
                    format!(
                        "Failed to create symlink at {}",
                        node_modules_generated.display()
                    )
                },
            )?;
        }

        #[cfg(windows)]
        {
            // On Windows, use junction for directory symlinks (doesn't require admin)
            std::os::windows::fs::symlink_dir(
                project_paths.project_root.join("generated"),
                &node_modules_generated,
            )
            .with_context(|| {
                format!(
                    "Failed to create symlink at {}",
                    node_modules_generated.display()
                )
            })?;
        }

        Ok(())
    }

    async fn run_post_codegen_command_sequence(
        project_paths: &ParsedProjectPaths,
        pm_config: &PackageManagerConfig,
    ) -> anyhow::Result<std::process::ExitStatus> {
        println!("Installing packages... ");
        let exit1 = install_dependencies(project_paths, pm_config).await?;
        if !exit1.success() {
            return Ok(exit1);
        }

        // Fix bun's module duplication issue by ensuring node_modules/generated is a symlink
        // Bun copies local file dependencies instead of symlinking them, which breaks
        // module identity when handler files import from "generated"
        if pm_config.is_bun_runtime() {
            fix_bun_generated_symlink(project_paths)?;
        }

        println!("Generating HyperIndex code...");
        let exit3 = rescript::build(&project_paths.generated, pm_config)
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

        // Create bunfig.toml for bun projects in generated folder
        if config.package_manager_config.is_bun_runtime() {
            let bunfig_content = r#"# Bun configuration file

[install]
# Disable telemetry
telemetry = false

# Use node_modules (default behavior)
linkStrategy = "node"
linker = "hoisted"

# Save exact versions
save = "exact"
"#;
            std::fs::write(
                config.parsed_project_paths.generated.join("bunfig.toml"),
                bunfig_content,
            )
            .context("Failed to create bunfig.toml in generated folder")?;
        }

        run_post_codegen_command_sequence(
            &config.parsed_project_paths,
            &config.package_manager_config,
        )
        .await
        .context("Failed running post codegen command sequence")?;

        Ok(())
    }
}

pub mod start {
    use super::execute_command_string_args;
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::anyhow;

    pub async fn start_indexer(
        config: &SystemConfig,
        should_open_hasura: bool,
    ) -> anyhow::Result<()> {
        if should_open_hasura {
            println!("Opening Hasura console at http://localhost:8080 ...");
            if open::that_detached("http://localhost:8080").is_err() {
                println!(
                    "Unable to open http://localhost:8080 in your browser automatically for you. \
                     You can open that link yourself to view hasura"
                );
            }
        }
        let pm = &config.package_manager_config.package_manager;
        let exit = execute_command_string_args(
            pm.command(),
            pm.run_script_args("start"),
            &config.parsed_project_paths.generated,
        )
        .await?;

        if !exit.success() {
            return Err(anyhow!(
                "Indexer crashed. For more details see the error logs above the TUI. Can't find \
                 them? Restart the indexer with the 'TUI_OFF=true {} start' command.",
                pm.command()
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

    use super::execute_command_string_args;
    use crate::{config_parsing::system_config::SystemConfig, persisted_state::PersistedState};

    pub async fn run_up_migrations(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let pm = &config.package_manager_config.package_manager;
        let current_dir = &config.parsed_project_paths.generated;
        let exit =
            execute_command_string_args(pm.command(), pm.run_script_args("db-up"), current_dir)
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
        let pm = &config.package_manager_config.package_manager;
        let current_dir = &config.parsed_project_paths.generated;
        execute_command_string_args(pm.command(), pm.run_script_args("db-down"), current_dir).await
    }

    pub async fn run_db_setup(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let pm = &config.package_manager_config.package_manager;
        let current_dir = &config.parsed_project_paths.generated;
        let exit =
            execute_command_string_args(pm.command(), pm.run_script_args("db-setup"), current_dir)
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

pub mod benchmark {
    use super::execute_command_string_args;
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::{anyhow, Result};

    pub async fn print_summary(config: &SystemConfig) -> Result<()> {
        let pm = &config.package_manager_config.package_manager;
        let current_dir = &config.parsed_project_paths.generated;
        let exit = execute_command_string_args(
            pm.command(),
            pm.run_script_args("print-benchmark-summary"),
            current_dir,
        )
        .await?;

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
