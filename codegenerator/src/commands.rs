pub mod codegen {

    use crate::{
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
    static CODEGEN_STATIC_DIR: Dir<'_> = include_dir!("templates/static/codegen");

    pub async fn pnpm_install(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("pnpm")
            .arg("install")
            .arg("--no-frozen-lockfile")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn rescript_clean(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("clean")
            .arg("-with-deps")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn rescript_format(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        //npx should work with any node package manager
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("format")
            .arg("-all")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()
            .await?)
    }
    pub async fn rescript_build(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        //npx should work with any node package manager
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("build")
            .arg("-with-deps")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()
            .await?)
    }

    pub async fn run_post_codegen_command_sequence(
        project_paths: &ProjectPaths,
    ) -> Result<(), Box<dyn Error>> {
        println!("installing packages... ");
        pnpm_install(project_paths).await?;

        println!("clean build directory");
        rescript_clean(project_paths).await?;

        println!("formatting code");
        rescript_format(project_paths).await?;

        println!("building code");
        rescript_build(project_paths).await?;

        Ok(())
    }

    pub fn run_codegen(parsed_paths: &ParsedPaths) -> Result<(), Box<dyn Error>> {
        let project_paths = &parsed_paths.project_paths;
        fs::create_dir_all(&project_paths.generated)?;

        let entity_types = entity_parsing::get_entity_record_types_from_schema(&parsed_paths)?;

        let contract_types = event_parsing::get_contract_types_from_config(
            &parsed_paths,
            &entities_to_map(entity_types.clone()),
        )?;

        let chain_config_templates =
            config_parsing::convert_config_to_chain_configs(&parsed_paths)?;

        //Used to create project specific configuration during deployment
        let project_name = config_parsing::get_project_name_from_config(&parsed_paths)?;

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
            &parsed_paths,
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
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        //TODO: put the start script in the generated package.json
        //and run from there.
        Ok(Command::new("npm")
            .arg("run")
            .arg("start")
            .current_dir(&project_paths.project_root)
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
            .spawn()?
            .wait()
            .await?;
        if exit.success() {
            let has_run_db_migrations = false;
            PersistedState::set_has_run_db_migrations(project_paths, has_run_db_migrations)?;
        }
        Ok(())
    }

    pub async fn run_db_setup(project_paths: &ProjectPaths) -> Result<(), Box<dyn Error>> {
        let exit = Command::new("node")
            .arg("-e")
            .arg("require(`./src/Migrations.bs.js`).setupDb()")
            .current_dir(&project_paths.generated)
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
