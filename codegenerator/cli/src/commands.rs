pub mod rescript {
    use std::{error::Error, path::PathBuf};
    use tokio::process::Command;

    pub async fn clean(path: &PathBuf) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("clean")
            .arg("-with-deps")
            .current_dir(path)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn format(path: &PathBuf) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        //npx should work with any node package manager
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("format")
            .arg("-all")
            .current_dir(path)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn build(path: &PathBuf) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        // TODO: make a separate function for `pnpm install` and compose them rather
        // Make suer that the top level repo is installed
        let status = Command::new("pnpm")
            .arg("install")
            .current_dir(&path)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            .spawn()?
            .wait()
            .await?;

        // TODO: re-evaluate the necessity for this check when better error-handling standards and guidelines have been created for this project.
        // Check if the first command was successful
        if !status.success() {
            return Err(Box::new(std::io::Error::new(
                std::io::ErrorKind::Other,
                "pnpm install command failed",
            )));
        }

        Ok(Command::new("npx")
            .arg("rescript")
            .arg("build")
            .arg("-with-deps")
            .current_dir(path)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            .spawn()?
            .wait()
            .await?)
    }
}

pub mod codegen {

    use crate::{
        commands::rescript,
        config_parsing::{self, entity_parsing, event_parsing},
        hbs_templating::codegen_templates::{
            entities_to_map, generate_templates, EventRecordTypeTemplate,
        },
        linked_hashmap::{LinkedHashMap, RescriptRecordHierarchyLinkedHashMap, RescriptRecordKey},
        project_paths::ParsedPaths,
    };
    use std::error::Error;
    use std::fs;
    use tokio::process::Command;

    use crate::project_paths::ProjectPaths;
    use include_dir::{include_dir, Dir};
    static CODEGEN_STATIC_DIR: Dir<'_> =
        include_dir!("$CARGO_MANIFEST_DIR/templates/static/codegen");

    pub async fn check_and_install_pnpm() -> std::io::Result<()> {
        // Check if pnpm is already installed
        let check_pnpm = Command::new("pnpm")
            .arg("--version")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();

        // If pnpm is not installed, run the installation command
        match check_pnpm.await {
            Ok(status) if status.success() => {
                println!("Package pnpm is already installed. Continuing...");
            }
            _ => {
                println!("Package pnpm is not installed. Installing now...");
                Command::new("npm")
                    .arg("install")
                    .arg("--global")
                    .arg("--force")
                    .arg("pnpm")
                    .status()
                    .await?;
            }
        }
        Ok(())
    }

    pub async fn pnpm_install(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("pnpm")
            .arg("install")
            .arg("--no-frozen-lockfile")
            .current_dir(&project_paths.generated)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn rescript_clean(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        rescript::clean(&project_paths.generated).await
    }
    pub async fn rescript_format(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        rescript::format(&project_paths.generated).await
    }
    pub async fn rescript_build(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        rescript::build(&project_paths.generated).await
    }

    pub async fn run_post_codegen_command_sequence(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        println!("Checking for pnpm package...");
        check_and_install_pnpm().await?;

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

    pub async fn run_codegen(parsed_paths: &ParsedPaths) -> Result<(), Box<dyn Error>> {
        let project_paths = &parsed_paths.project_paths;
        fs::create_dir_all(&project_paths.generated)?;

        let entity_types = entity_parsing::get_entity_record_types_from_schema(parsed_paths)?;

        let contract_types = event_parsing::get_contract_types_from_config(
            parsed_paths,
            &entities_to_map(entity_types.clone()),
        )?;

        let chain_config_templates =
            config_parsing::convert_config_to_chain_configs(parsed_paths).await?;

        //Used to create project specific configuration during deployment
        let project_name = config_parsing::get_project_name_from_config(parsed_paths)?;

        //NOTE: This structure is no longer used int event parsing since it has been refactored
        //to use an inline tuple type for parsed structs. However this is being left until it
        //is decided to completely remove the need for subrecords in which case the entire
        //linked_hashmap module can be removed.
        let rescript_subrecord_dependencies: LinkedHashMap<
            RescriptRecordKey,
            EventRecordTypeTemplate,
        > = RescriptRecordHierarchyLinkedHashMap::new();

        let sub_record_dependencies: Vec<EventRecordTypeTemplate> = rescript_subrecord_dependencies
            .iter()
            .collect::<Vec<EventRecordTypeTemplate>>();

        CODEGEN_STATIC_DIR.extract(&project_paths.generated)?;

        generate_templates(
            sub_record_dependencies,
            contract_types,
            chain_config_templates,
            entity_types,
            parsed_paths,
            project_name,
        )?;

        Ok(())
    }
}

pub mod start {

    use std::error::Error;
    use tokio::process::Command;

    use crate::project_paths::ProjectPaths;

    pub async fn start_indexer(
        project_paths: &ProjectPaths,
        should_open_hasura: bool,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        if should_open_hasura {
            open::that("http://localhost:8080")?;
        }
        //TODO: put the start script in the generated package.json
        //and run from there.
        Ok(Command::new("npm")
            .arg("run")
            .arg("start")
            .current_dir(&project_paths.project_root)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?)
    }
}
pub mod docker {

    use std::error::Error;
    use tokio::process::Command;

    use crate::project_paths::ProjectPaths;

    pub async fn docker_compose_up_d(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("docker")
            .arg("compose")
            .arg("up")
            .arg("-d")
            .current_dir(&project_paths.generated)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn docker_compose_down_v(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("docker")
            .arg("compose")
            .arg("down")
            .arg("-v")
            .current_dir(&project_paths.generated)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?)
    }
}

pub mod db_migrate {

    use std::error::Error;
    use tokio::process::Command;

    use crate::{persisted_state::PersistedState, project_paths::ProjectPaths};
    pub async fn run_up_migrations(project_paths: &ProjectPaths) -> Result<(), Box<dyn Error>> {
        let exit = Command::new("node")
            .arg("-e")
            .arg("require(`./src/Migrations.bs.js`).runUpMigrations(true)")
            .current_dir(&project_paths.generated)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?;

        if exit.success() {
            let has_run_db_migrations = true;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }

    pub async fn run_drop_schema(project_paths: &ProjectPaths) -> Result<(), Box<dyn Error>> {
        let exit = Command::new("node")
            .arg("-e")
            .arg("require(`./src/Migrations.bs.js`).runDownMigrations(true)")
            .current_dir(&project_paths.generated)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?;
        if exit.success() {
            let has_run_db_migrations = false;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }

    pub async fn run_db_setup(
        project_paths: &ProjectPaths,
        should_drop_raw_events: bool,
    ) -> Result<(), Box<dyn Error>> {
        let exit = Command::new("node")
            .arg("-e")
            .arg(format!(
                "require(`./src/Migrations.bs.js`).setupDb({})",
                should_drop_raw_events
            ))
            .current_dir(&project_paths.generated)
            .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
            .kill_on_drop(true) //needed so that dropped threads calling this will also drop
            //the child process
            .spawn()?
            .wait()
            .await?;
        if exit.success() {
            let has_run_db_migrations = true;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }
}
