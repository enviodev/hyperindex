use std::error::Error;
use std::path::PathBuf;
use std::process::Command;

use clap::Parser;

use indexly::{
    cli_args, config_parsing, copy_directory, entity_parsing, event_parsing, generate_templates,
};

use cli_args::{CommandLineArgs, CommandType};

fn main() -> Result<(), Box<dyn Error>> {
    let command_line_args = CommandLineArgs::parse();

    match command_line_args.command {
        CommandType::Init => Ok(()),
        CommandType::Codegen(args) => {
            let project_root_path = PathBuf::from(&args.directory);
            let code_gen_path: PathBuf = project_root_path.join(&args.output_directory);
            let config_path: PathBuf = project_root_path.join(&args.config);
            let schema_path = project_root_path.join("schema.graphql"); //TODO: get this from the
                                                                        //config.yaml
            copy_directory("templates/static", &code_gen_path)?; //TODO: rewrite this
                                                                 // inclued static dir in binary

            let contract_types = event_parsing::get_contract_types_from_config(&config_path)?;
            let entity_types = entity_parsing::get_entity_record_types_from_schema(&schema_path)?;
            let chain_config_templates =
                config_parsing::convert_config_to_chain_configs(&config_path)?;

            generate_templates(
                contract_types,
                chain_config_templates,
                entity_types,
                &code_gen_path,
            )?;

            println!("installing packages... ");

            Command::new("pnpm")
                .arg("install")
                .current_dir(&code_gen_path)
                .spawn()?
                .wait()?;

            println!("clean build directory");

            Command::new("pnpm")
                .arg("clean")
                .current_dir(&code_gen_path)
                .spawn()?
                .wait()?;

            println!("formatting code");

            Command::new("pnpm")
                .arg("rescript")
                .arg("format")
                .arg("-all")
                .current_dir(&code_gen_path)
                .spawn()?
                .wait()?;

            println!("building code");

            Command::new("pnpm")
                .arg("build")
                .current_dir(&code_gen_path)
                .spawn()?
                .wait()?;

            println!("generate db bigrations");

            Command::new("pnpm")
                .arg("db-migrate")
                .current_dir(&code_gen_path)
                .spawn()?
                .wait()?;

            Ok(())
        }
    }
}
