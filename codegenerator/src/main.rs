use std::error::Error;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use clap::Parser;

use indexly::{
    cli_args, config_parsing, copy_dir, entity_parsing, event_parsing, generate_templates,
    linked_hashmap::RescriptRecordHierarchyLinkedHashMap, RecordType,
};

use cli_args::{CommandLineArgs, CommandType, Template};
use include_dir::{include_dir, Dir};

static CODEGEN_STATIC_DIR: Dir<'_> = include_dir!("templates/static/codegen");
static GRAVATAR_TEMPLATE_STATIC_DIR: Dir<'_> = include_dir!("templates/static/gravatar_template");

fn main() -> Result<(), Box<dyn Error>> {
    let command_line_args = CommandLineArgs::parse();

    match command_line_args.command {
        CommandType::Init(args) => {
            let project_root_path = PathBuf::from(&args.directory);
            fs::create_dir_all(&project_root_path)?;
            match args.template {
                Template::Gravatar => copy_dir(&GRAVATAR_TEMPLATE_STATIC_DIR, &project_root_path)?,
            }

            Ok(())
        }
        CommandType::Codegen(args) => {
            // TODO: could make a "path manager" module that holds all of this with some nice helper functions/api.
            //       Then just pass around that object whenever path related stuff is needed.
            let project_root_path = PathBuf::from(&args.directory);
            let code_gen_path: PathBuf = project_root_path.join(&args.output_directory);
            let config_path: PathBuf = project_root_path.join(&args.config);
            let schema_path = project_root_path.join("schema.graphql"); //TODO: get this from the
                                                                        //config.yaml
            fs::create_dir_all(&code_gen_path)?;

            let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
            let contract_types = event_parsing::get_contract_types_from_config(
                &config_path,
                &project_root_path,
                &code_gen_path,
                &mut rescript_subrecord_dependencies,
            )?;
            let entity_types = entity_parsing::get_entity_record_types_from_schema(&schema_path)?;
            let chain_config_templates =
                config_parsing::convert_config_to_chain_configs(&config_path)?;
            let sub_record_dependencies = rescript_subrecord_dependencies
                .iter()
                .collect::<Vec<RecordType>>();

            copy_dir(&CODEGEN_STATIC_DIR, &code_gen_path)?;

            generate_templates(
                sub_record_dependencies,
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
