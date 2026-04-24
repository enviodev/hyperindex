use anyhow::Context;
use std::io::IsTerminal;
use std::path::Path;

/// Spawns `cmd` with piped stdio forwarded to the host `print!`/`eprint!`.
/// The pipe hides the TTY from the child, so we forward the host's TTY state
/// via `FORCE_COLOR`/`CLICOLOR_FORCE` so package managers still render colors.
async fn execute_command(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    let mut command = tokio::process::Command::new(cmd);
    command
        .args(&args)
        .current_dir(current_dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    if std::io::stdout().is_terminal() {
        command
            .env("FORCE_COLOR", "1")
            .env("CLICOLOR_FORCE", "1")
            .env("npm_config_color", "always");
    }

    let mut child = command.spawn().context(format!(
        "Failed to spawn command {} {} at {} as child process",
        cmd,
        args.join(" "),
        current_dir.to_str().unwrap_or("bad_path")
    ))?;

    let stdout = child.stdout.take();
    let stderr = child.stderr.take();

    let stdout_task = tokio::spawn(async move {
        if let Some(mut s) = stdout {
            use tokio::io::AsyncReadExt;
            let mut buf = [0u8; 4096];
            while let Ok(n) = s.read(&mut buf).await {
                if n == 0 {
                    break;
                }
                print!("{}", String::from_utf8_lossy(&buf[..n]));
            }
        }
    });
    let stderr_task = tokio::spawn(async move {
        if let Some(mut s) = stderr {
            use tokio::io::AsyncReadExt;
            let mut buf = [0u8; 4096];
            while let Ok(n) = s.read(&mut buf).await {
                if n == 0 {
                    break;
                }
                eprint!("{}", String::from_utf8_lossy(&buf[..n]));
            }
        }
    });

    let exit = child.wait().await.context(format!(
        "Failed to exit command {} {} at {} from child process",
        cmd,
        args.join(" "),
        current_dir.to_str().unwrap_or("bad_path")
    ))?;
    let _ = stdout_task.await;
    let _ = stderr_task.await;
    Ok(exit)
}

/// `install` + `run build` wrappers for a user-selected package manager.
///
/// `run` prepends the literal `run` token so `npm run <script>` works;
/// pnpm/yarn/bun tolerate the extra `run`.
pub mod pm {
    use super::execute_command;
    use crate::cli_args::init_config::PackageManager;
    use anyhow::{anyhow, Result};
    use std::path::Path;

    pub async fn install(pm: PackageManager, cwd: &Path) -> Result<()> {
        let exit = execute_command(pm.cmd(), vec!["install"], cwd).await?;
        if !exit.success() {
            return Err(anyhow!(
                "{} install exited with code {}",
                pm.cmd(),
                exit.code().unwrap_or(-1),
            ));
        }
        Ok(())
    }

    pub async fn run_script(pm: PackageManager, script: &str, cwd: &Path) -> Result<()> {
        let exit = execute_command(pm.cmd(), vec!["run", script], cwd).await?;
        if !exit.success() {
            return Err(anyhow!(
                "{} run {} exited with code {}",
                pm.cmd(),
                script,
                exit.code().unwrap_or(-1),
            ));
        }
        Ok(())
    }
}

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
    use crate::{config_parsing::system_config::SystemConfig, hbs_templating};
    use anyhow::{self, bail, Context};
    use std::path::{Path, PathBuf};

    pub async fn run_codegen(config: &SystemConfig) -> anyhow::Result<()> {
        // The legacy `generated/` package no longer exists. If user code still
        // imports from it, codegen would silently produce a project that fails
        // at runtime — bail with a migration hint instead.
        check_no_stale_generated_imports(&config.parsed_project_paths.project_root)
            .context("Found leftover imports from the removed `generated` package")?;

        let template = hbs_templating::codegen_templates::ProjectTemplate::from_config(config)
            .context("Failed creating project template")?;

        template
            .generate_templates(&config.parsed_project_paths)
            .context("Failed generating codegen files")?;

        Ok(())
    }

    fn check_no_stale_generated_imports(project_root: &Path) -> anyhow::Result<()> {
        let mut offenders: Vec<PathBuf> = Vec::new();
        for sub in ["src", "test"] {
            let dir = project_root.join(sub);
            if dir.exists() {
                scan_for_stale_generated_imports(&dir, &mut offenders)?;
            }
        }
        if offenders.is_empty() {
            return Ok(());
        }
        let list = offenders
            .iter()
            .map(|p| format!("  - {}", p.display()))
            .collect::<Vec<_>>()
            .join("\n");
        bail!(
            "Found `from \"generated\"` imports in:\n{list}\n\nReplace with `from \"envio\"` — \
             the project-bound types are now augmented onto the `envio` module via \
             `envio-env.d.ts`. The legacy `generated/` directory is no longer produced."
        );
    }

    fn scan_for_stale_generated_imports(
        dir: &Path,
        offenders: &mut Vec<PathBuf>,
    ) -> anyhow::Result<()> {
        for entry in
            std::fs::read_dir(dir).with_context(|| format!("Failed reading {}", dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                // Skip vendored / build / cache trees.
                if matches!(
                    name.as_ref(),
                    "node_modules" | ".envio" | "build" | "dist" | "lib" | ".git"
                ) {
                    continue;
                }
                scan_for_stale_generated_imports(&path, offenders)?;
            } else if file_type.is_file()
                && matches!(
                    path.extension().and_then(|e| e.to_str()),
                    Some("ts" | "tsx" | "mts" | "cts" | "js" | "mjs" | "cjs")
                )
            {
                let content = match std::fs::read_to_string(&path) {
                    Ok(c) => c,
                    Err(_) => continue,
                };
                if content.contains("from \"generated\"") || content.contains("from 'generated'") {
                    offenders.push(path);
                }
            }
        }
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
