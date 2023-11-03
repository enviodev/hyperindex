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
    use anyhow::{anyhow, Result};
    use std::path::PathBuf;

    pub async fn clean(path: &PathBuf) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript", "clean", "-with-deps"];
        //npx should work with any node package manager
        execute_command("npx", args, path).await
    }

    pub async fn format(path: &PathBuf) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript", "format", "-all"];
        //npx should work with any node package manager
        execute_command("npx", args, path).await
    }
    pub async fn build(path: &PathBuf) -> Result<std::process::ExitStatus> {
        let args = vec!["install"];
        //npx should work with any node package manager
        // Make sure that the top level repo is installed
        let status = execute_command("pnpm", args, path).await?;

        // TODO: re-evaluate the necessity for this check when better error-handling standards and guidelines have been created for this project.
        // Check if the first command was successful
        if !status.success() {
            return Err(anyhow!("pnpm install command failed"));
        }

        let args = vec!["rescript", "build", "-with-deps"];
        execute_command("npx", args, path).await
    }
}

pub mod codegen {
    use super::execute_command;
    use super::rescript;
    use crate::{config_parsing::config, hbs_templating};
    use anyhow::{self, Context, Result};
    use std::fs;
    use std::path::PathBuf;

    use crate::project_paths::ParsedProjectPaths;
    use include_dir::{include_dir, Dir};
    static CODEGEN_STATIC_DIR: Dir<'_> =
        include_dir!("$CARGO_MANIFEST_DIR/templates/static/codegen");

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
        let current_dir = &project_paths.generated;
        check_and_install_pnpm(current_dir).await?;

        let args = vec!["install", "--no-frozen-lockfile"];
        execute_command("pnpm", args, current_dir).await
    }

    pub async fn rescript_clean(
        project_paths: &ParsedProjectPaths,
    ) -> Result<std::process::ExitStatus> {
        rescript::clean(&project_paths.generated).await
    }
    pub async fn rescript_format(
        project_paths: &ParsedProjectPaths,
    ) -> Result<std::process::ExitStatus> {
        rescript::format(&project_paths.generated).await
    }
    pub async fn rescript_build(
        project_paths: &ParsedProjectPaths,
    ) -> Result<std::process::ExitStatus> {
        rescript::build(&project_paths.generated).await
    }

    pub async fn run_post_codegen_command_sequence(
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<std::process::ExitStatus> {
        println!("installing packages... ");
        let exit1 = pnpm_install(project_paths).await?;
        if !exit1.success() {
            return Ok(exit1);
        }

        println!("clean build directory");
        let exit2 = rescript_clean(project_paths).await?;
        if !exit2.success() {
            return Ok(exit2);
        }

        println!("formatting code");
        let exit3 = rescript_format(project_paths).await?;
        if !exit3.success() {
            return Ok(exit3);
        }

        println!("building code");
        let last_exit = rescript_build(project_paths).await?;

        Ok(last_exit)
    }

    pub async fn run_codegen(
        config: &config::Config,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<()> {
        fs::create_dir_all(&project_paths.generated)?;

        let template =
            hbs_templating::codegen_templates::ProjectTemplate::from_config(config, project_paths)
                .context("Failed creating project template")?;

        CODEGEN_STATIC_DIR
            .extract(&project_paths.generated)
            .context("Failed extracting static codegen files")?;

        template
            .generate_templates(project_paths)
            .context("Failed generating dynamic codegen files")?;

        Ok(())
    }
}

pub mod start {
    use super::execute_command;
    use crate::project_paths::ParsedProjectPaths;

    pub async fn start_indexer(
        project_paths: &ParsedProjectPaths,
        should_use_raw_events_worker: bool,
        should_open_hasura: bool,
    ) -> anyhow::Result<std::process::ExitStatus> {
        if should_open_hasura {
            println!("Opening Hasura console at http://localhost:8080 ...");
            if let Err(_) = open::that_detached("http://localhost:8080") {
                println!("Unable to open http://localhost:8080 in your browser automatically for you. You can open that link yourself to view hasura");
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

        execute_command(cmd, args, current_dir).await
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
    use super::execute_command;
    use crate::{persisted_state::PersistedState, project_paths::ParsedProjectPaths};

    pub async fn run_up_migrations(project_paths: &ParsedProjectPaths) -> anyhow::Result<()> {
        let cmd = "node";
        let args = vec![
            "-e",
            "require(`./src/Migrations.bs.js`).runUpMigrations(true)",
        ];

        let current_dir = &project_paths.generated;

        let exit = execute_command(cmd, args, current_dir).await?;

        if exit.success() {
            let has_run_db_migrations = true;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }

    pub async fn run_drop_schema(project_paths: &ParsedProjectPaths) -> anyhow::Result<()> {
        let cmd = "node";
        let args = vec![
            "-e",
            "require(`./src/Migrations.bs.js`).runDownMigrations(true)",
        ];

        let current_dir = &project_paths.generated;

        let exit = execute_command(cmd, args, current_dir).await?;
        if exit.success() {
            let has_run_db_migrations = false;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }

    pub async fn run_db_setup(
        project_paths: &ParsedProjectPaths,
        should_drop_raw_events: bool,
    ) -> anyhow::Result<()> {
        let cmd = "node";

        let last_arg = format!(
            "require(`./src/Migrations.bs.js`).setupDb({})",
            should_drop_raw_events
        );

        let args = vec!["-e", last_arg.as_str()];

        let current_dir = &project_paths.generated;

        let exit = execute_command(cmd, args, current_dir).await?;

        if exit.success() {
            let has_run_db_migrations = true;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }
}
