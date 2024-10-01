use anyhow::Context;
use std::path::Path;

async fn execute_command(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    Ok(tokio::process::Command::new(cmd)
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
        ))?)
}

pub mod rescript {
    use super::execute_command;
    use anyhow::Result;
    use std::path::PathBuf;

    pub async fn clean(path: &PathBuf) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript", "clean"];
        execute_command("pnpm", args, path).await
    }

    pub async fn build(path: &PathBuf) -> Result<std::process::ExitStatus> {
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
    use std::path::PathBuf;

    use crate::project_paths::ParsedProjectPaths;
    use tokio::fs;

    pub async fn remove_files_except_git(directory: &PathBuf) -> Result<()> {
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

    pub async fn check_and_install_pnpm(current_dir: &PathBuf) -> Result<()> {
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

    pub async fn pnpm_install(
        project_paths: &ParsedProjectPaths,
    ) -> Result<std::process::ExitStatus> {
        println!("Checking for pnpm package...");
        let current_dir = &project_paths.project_root;
        check_and_install_pnpm(current_dir).await?;

        let args = vec!["install", "--no-frozen-lockfile", "--prefer-offline"];
        execute_command("pnpm", args, current_dir).await
    }

    async fn run_post_codegen_command_sequence(
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<std::process::ExitStatus> {
        println!("Installing packages... ");
        let exit1 = pnpm_install(project_paths).await?;
        if !exit1.success() {
            return Ok(exit1);
        }

        println!("Clean build directory");
        let exit2 = rescript::clean(&project_paths.generated)
            .await
            .context("Failed running rescript clean")?;
        if !exit2.success() {
            return Ok(exit2);
        }

        println!("Building code");
        let exit3 = rescript::build(&project_paths.generated)
            .await
            .context("Failed running rescript build")?;
        if !exit3.success() {
            return Ok(exit3);
        }

        Ok(exit3)
    }

    pub async fn npx_codegen(
        envio_version: String,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<()> {
        let package = format!("envio@{}", envio_version);
        let args = vec!["--yes", package.as_str(), "codegen"];
        execute_command("npx", args, &project_paths.project_root)
            .await
            .context(format!(
                "Failed to run codegen for the envio version {}",
                envio_version
            ))?;
        Ok(())
    }

    pub async fn run_codegen(
        config: &SystemConfig,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<()> {
        let template_dirs = TemplateDirs::new();
        fs::create_dir_all(&project_paths.generated).await?;

        let template =
            hbs_templating::codegen_templates::ProjectTemplate::from_config(config, project_paths)
                .context("Failed creating project template")?;

        template_dirs
            .get_codegen_static_dir()?
            .extract(&project_paths.generated)
            .context("Failed extracting static codegen files")?;

        template
            .generate_templates(project_paths)
            .context("Failed generating dynamic codegen files")?;

        run_post_codegen_command_sequence(project_paths)
            .await
            .context("Failed running post codegen command sequence")?;

        Ok(())
    }
}

pub mod start {
    use super::execute_command;
    use crate::project_paths::ParsedProjectPaths;
    use anyhow::anyhow;

    pub async fn start_indexer(
        project_paths: &ParsedProjectPaths,
        should_use_raw_events_worker: bool,
        should_open_hasura: bool,
    ) -> anyhow::Result<()> {
        if should_open_hasura {
            println!("Opening Hasura console at http://localhost:8080 ...");
            if let Err(_) = open::that_detached("http://localhost:8080") {
                println!(
                    "Unable to open http://localhost:8080 in your browser automatically for you. \
                     You can open that link yourself to view hasura"
                );
            }
        }
        let cmd = "npm";
        let mut args = vec!["run", "start"];
        let current_dir = &project_paths.project_root;

        //TODO: put the start script in the generated package.json
        //and run from there.
        if should_use_raw_events_worker {
            args.push("--");
            args.push("--sync-from-raw-events");
        }

        let exit = execute_command(cmd, args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!(
                "Indexer has failed to run. Please see error logs for more details"
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
    use super::execute_command;
    use crate::project_paths::ParsedProjectPaths;

    pub async fn docker_compose_up_d(
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<std::process::ExitStatus> {
        let cmd = "docker";
        let args = vec!["compose", "up", "-d"];
        let current_dir = &project_paths.generated;

        execute_command(cmd, args, current_dir).await
    }
    pub async fn docker_compose_down_v(
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<std::process::ExitStatus> {
        let cmd = "docker";
        let args = vec!["compose", "down", "-v"];
        let current_dir = &project_paths.generated;

        execute_command(cmd, args, current_dir).await
    }
}

pub mod db_migrate {
    use anyhow::{anyhow, Context};

    use std::process::ExitStatus;

    use super::execute_command;
    use crate::{persisted_state::PersistedState, project_paths::ParsedProjectPaths};

    pub async fn run_up_migrations(
        project_paths: &ParsedProjectPaths,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let args = vec!["db-up"];
        let current_dir = &project_paths.generated;
        let exit = execute_command("pnpm", args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!("Failed to run db migrations"));
        }

        persisted_state
            .upsert_to_db()
            .await
            .context("Failed to upsert persisted state table")?;
        Ok(())
    }

    pub async fn run_drop_schema(project_paths: &ParsedProjectPaths) -> anyhow::Result<ExitStatus> {
        let args = vec!["db-down"];
        let current_dir = &project_paths.generated;
        execute_command("pnpm", args, current_dir).await
    }

    pub async fn run_db_setup(
        project_paths: &ParsedProjectPaths,
        should_drop_raw_events: bool,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let arg = if should_drop_raw_events {
            "db-setup"
        } else {
            "db-setup-keep-raw-events"
        };
        let args = vec![arg];
        let current_dir = &project_paths.generated;
        let exit = execute_command("pnpm", args, current_dir).await?;

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
    use super::execute_command;
    use crate::project_paths::ParsedProjectPaths;
    use anyhow::{anyhow, Result};

    pub async fn print_summary(project_paths: &ParsedProjectPaths) -> Result<()> {
        let args = vec!["print-benchmark-summary"];
        let current_dir = &project_paths.generated;
        let exit = execute_command("pnpm", args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!("Failed printing benchmark summary"));
        }

        Ok(())
    }
}
