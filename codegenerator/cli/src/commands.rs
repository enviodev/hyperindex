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
        let args = vec!["rescript", "clean", "-with-deps"];
        execute_command("pnpm", args, path).await
    }

    pub async fn format(path: &PathBuf) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript", "format", "-all"];
        execute_command("pnpm", args, path).await
    }
    pub async fn build(path: &PathBuf) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript", "build", "-with-deps"];
        execute_command("pnpm", args, path).await
    }
}

pub mod codegen {
    use super::{execute_command, rescript};
    use crate::{
        config_parsing::system_config::SystemConfig, constants::project_paths::ESBUILD_PATH,
        hbs_templating, persisted_state::PersistedState, project_paths::path_utils,
        template_dirs::TemplateDirs,
    };
    use anyhow::{anyhow, Context, Result};
    use pathdiff::diff_paths;
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

        let args = vec!["install", "--no-frozen-lockfile"];
        execute_command("pnpm", args, current_dir).await
    }

    // eg: pnpm esbuild --platform=node --bundle --minify --outdir=./esbuild-handlers --external:./* ../src/EventHandlers.ts ../src/another-file.ts
    pub async fn generate_esbuild_out(
        project_paths: &ParsedProjectPaths,
        all_handler_paths: Vec<PathBuf>,
    ) -> Result<std::process::ExitStatus> {
        let current_dir = &project_paths.generated;

        let config_directory = project_paths
            .config
            .parent()
            .ok_or_else(|| anyhow!("Unexpected config file should have a parent directory"))?;

        // let all_handler_paths_parent = all_handler_paths.clone();
        let all_handler_paths_string = all_handler_paths
            .clone()
            .into_iter()
            .map(|path| {
                let handler_path_joined = &config_directory.join(path);
                let absolute_path = path_utils::normalize_path(&handler_path_joined);

                let binding = diff_paths(absolute_path.clone(), &project_paths.generated)
                    .ok_or_else(|| anyhow!("could not find handler path relative to generated"))?;

                let relative_to_generated = binding
                    .to_str()
                    .ok_or_else(|| anyhow!("Handler path should be unicode"))?;

                Ok(relative_to_generated.to_string())
            })
            .collect::<Result<Vec<_>>>()
            .context("failed to get relative paths for handlers")?;

        let out_dir_arg = format!("--outdir={}", ESBUILD_PATH);

        let esbuild_cmd: Vec<String> = vec![
            "esbuild",
            "--platform=node",
            "--bundle",
            "--minify",
            &out_dir_arg,
            "--external:./*",
            "--log-level=warning",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();

        let esbuild_cmd_with_paths = esbuild_cmd
            .iter()
            .chain(all_handler_paths_string.iter())
            .into_iter()
            .map(|s| s.as_str())
            .collect::<Vec<&str>>();

        execute_command("pnpm", esbuild_cmd_with_paths, &current_dir).await
    }

    pub async fn run_post_codegen_command_sequence(
        project_paths: &ParsedProjectPaths,
        config: &SystemConfig,
    ) -> anyhow::Result<std::process::ExitStatus> {
        println!("installing packages... ");
        let exit1 = pnpm_install(project_paths).await?;
        if !exit1.success() {
            return Ok(exit1);
        }

        // create persisted state
        let persisted_state = PersistedState::get_current_state(config)
            .await
            .context("Failed creating default persisted state")?;

        let persisted_state_path = project_paths.generated.join("persisted_state.envio.json");
        // write persisted state to a file called persisted_state.json
        fs::write(
            persisted_state_path,
            serde_json::to_string(&persisted_state)
                .context("failed to serialize persisted state")?,
        )
        .await
        .context("Failed writing persisted state to file")?; // todo : check what write behaviour

        println!("clean build directory");
        let exit2 = rescript::clean(&project_paths.generated)
            .await
            .context("Failed running rescript clean")?;
        if !exit2.success() {
            return Ok(exit2);
        }

        //NOTE: Runing format before build was causing freezing on some
        //cases
        println!("building code");
        let exit3 = rescript::build(&project_paths.generated)
            .await
            .context("Failed running rescript build")?;
        if !exit3.success() {
            return Ok(exit3);
        }

        //NOTE: Runing format before build was causing freezing on some
        //cases
        println!("formatting code");
        let last_exit = rescript::format(&project_paths.generated)
            .await
            .context("Failed running rescript format")?;

        Ok(last_exit)
    }

    pub async fn run_codegen(
        config: &SystemConfig,
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<()> {
        let template_dirs = TemplateDirs::new();
        fs::create_dir_all(&project_paths.generated).await?;
        let template =
            hbs_templating::codegen_templates::ProjectTemplate::from_config(config, project_paths)
                .await
                .context("Failed creating project template")?;
        template_dirs
            .get_codegen_static_dir()?
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

        if exit.success() {
            persisted_state.upsert_to_db().await?;
        }
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

        if exit.success() {
            persisted_state.upsert_to_db().await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod test {

    use crate::{
        config_parsing::{entity_parsing::Schema, human_config, system_config::SystemConfig},
        project_paths::ParsedProjectPaths,
    };
    use anyhow::Context;
    use std::path::PathBuf;

    #[tokio::test]

    async fn commands_execute() {
        let cmd = "echo";
        let args = vec!["hello"];
        let current_dir = std::env::current_dir().unwrap();
        let exit = super::execute_command(cmd, args, &current_dir)
            .await
            .unwrap();
        assert!(exit.success());
    }

    #[tokio::test]
    #[ignore = "Needs esbuild to be installed globally"]
    async fn generate_esbuild_out_commands_execute() {
        println!("Needs esbuild to be installed globally");
        let root = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let path = format!("{}/configs/config.js.yaml", &root);
        let config_path = PathBuf::from(path);

        let human_cfg = human_config::deserialize_config_from_yaml(&config_path)
            .context("human cfg")
            .expect("result from human config");
        let system_cfg = SystemConfig::parse_from_human_cfg_with_schema(
            &human_cfg,
            Schema::empty(),
            &ParsedProjectPaths::new(&root, "generated", "config.js.yaml")
                .expect("parsed project paths"),
        )
        .context("system_cfg")
        .expect("result from system config");

        let all_handler_paths = system_cfg
            .get_all_paths_to_handlers()
            .context("Failed getting handler paths")
            .expect("handlers from the config");

        let exit = super::codegen::generate_esbuild_out(
            &system_cfg.parsed_project_paths,
            all_handler_paths,
        )
        .await
        .unwrap();
        assert!(exit.success());
    }

    #[tokio::test]
    #[ignore = "Needs esbuild to be installed globally"]
    async fn generate_esbuild_out_commands_execute_ts() {
        println!("Needs esbuild to be installed globally");
        let root = format!("{}/test", env!("CARGO_MANIFEST_DIR"));
        let path = format!("{}/configs/config.ts.yaml", &root);
        let config_path = PathBuf::from(path);

        let human_cfg = human_config::deserialize_config_from_yaml(&config_path)
            .context("human cfg")
            .expect("result from human config");
        let system_cfg = SystemConfig::parse_from_human_cfg_with_schema(
            &human_cfg,
            Schema::empty(),
            &ParsedProjectPaths::new(&root, "generated", "config.ts.yaml")
                .expect("parsed project paths"),
        )
        .context("system_cfg")
        .expect("result from system config");

        let all_handler_paths = system_cfg
            .get_all_paths_to_handlers()
            .context("Failed getting handler paths")
            .expect("handlers from the config");

        let exit = super::codegen::generate_esbuild_out(
            &system_cfg.parsed_project_paths,
            all_handler_paths,
        )
        .await
        .unwrap();
        assert!(exit.success());
    }
}
