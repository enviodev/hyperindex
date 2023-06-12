pub mod codegen {

    use std::{error::Error, process::Command};

    use crate::project_paths::ProjectPaths;

    pub fn pnpm_install(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("pnpm")
            .arg("install")
            .arg("--no-frozen-lockfile")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }
    pub fn pnpm_clean(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("pnpm")
            .arg("clean")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }
    pub fn rescript_format(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        //npx should work with any node package manager
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("format")
            .arg("-all")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }
    pub fn rescript_build(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        //npx should work with any node package manager
        Ok(Command::new("npx")
            .arg("rescript")
            .arg("build")
            .arg("-with-deps")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }

    pub fn run_codegen_command_sequence(
        project_paths: &ProjectPaths,
    ) -> Result<(), Box<dyn Error>> {
        println!("installing packages... ");
        pnpm_install(project_paths)?;

        println!("clean build directory");
        pnpm_clean(project_paths)?;

        println!("formatting code");
        rescript_format(project_paths)?;

        println!("building code");
        rescript_build(project_paths)?;

        Ok(())
    }
}
pub mod docker {

    use std::{error::Error, process::Command};

    use crate::project_paths::ProjectPaths;

    pub fn docker_compose_up_d(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("docker")
            .arg("compose")
            .arg("up")
            .arg("-d")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }
    pub fn docker_compose_down_v(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("docker")
            .arg("compose")
            .arg("down")
            .arg("-v")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }
}

pub mod db_migrate {

    use std::{error::Error, process::Command};

    use crate::project_paths::ProjectPaths;
    pub fn run_up_migrations(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("node")
            .arg("-e")
            .arg("'require(`./src/Migrations.bs.js`).runUpMigrations(true)'")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }

    pub fn run_drop_schema(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("node")
            .arg("-e")
            .arg("'require(`./src/Migrations.bs.js`).runDownMigrations(true)'")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }

    pub fn run_db_setup(
        project_paths: &ProjectPaths,
    ) -> Result<std::process::ExitStatus, Box<dyn Error>> {
        Ok(Command::new("node")
            .arg("-e")
            .arg("'require(`./src/Migrations.bs.js`).setupDb()'")
            .current_dir(&project_paths.generated)
            .spawn()?
            .wait()?)
    }
}
