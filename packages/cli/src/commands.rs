use anyhow::Context;
use std::path::Path;

/// Spawns `cmd` with piped stdio forwarded to the host `print!`/`eprint!`.
/// Loses the TTY signal (so package managers render without colors) but
/// works inside the NAPI addon, where tokio-spawned child processes can't
/// inherit fds cleanly — their output would otherwise disappear.
async fn execute_command(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    let mut child = tokio::process::Command::new(cmd)
        .args(&args)
        .current_dir(current_dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context(format!(
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
