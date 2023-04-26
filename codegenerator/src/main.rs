use std::error::Error;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

use clap::Parser;

use envio::{
    cli_args::{self, JsFlavor},
    config_parsing, entity_parsing, event_parsing, generate_templates,
    linked_hashmap::RescriptRecordHierarchyLinkedHashMap,
    project_paths::ParsedPaths,
    RecordType,
};

use cli_args::{CommandLineArgs, CommandType, Template, ToProjectPathsArgs};
use include_dir::{include_dir, Dir};

static CODEGEN_STATIC_DIR: Dir<'_> = include_dir!("templates/static/codegen");
static GRAVATAR_TEMPLATE_STATIC_SHARED_DIR: Dir<'_> =
    include_dir!("templates/static/gravatar_template/shared");
static GRAVATAR_TEMPLATE_STATIC_RESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/gravatar_template/rescript");
static GRAVATAR_TEMPLATE_STATIC_TYPESCRIPT_DIR: Dir<'_> =
    include_dir!("templates/static/gravatar_template/typescript");
// static GRAVATAR_TEMPLATE_STATIC_JAVASCRIPT_DIR: Dir<'_> =
//     include_dir!("templates/static/gravatar_template/javascript");

fn main() -> Result<(), Box<dyn Error>> {
    let command_line_args = CommandLineArgs::parse();

    match command_line_args.command {
        CommandType::Init(init_args) => {
            let args = init_args.get_init_args_interactive()?;
            let project_root_path = PathBuf::from(&args.directory);
            fs::create_dir_all(&project_root_path)?;
            match args.template {
                Template::Gravatar => {
                    GRAVATAR_TEMPLATE_STATIC_SHARED_DIR.extract(&project_root_path)?;
                    match &args.js_flavor {
                        JsFlavor::Rescript => {
                            GRAVATAR_TEMPLATE_STATIC_RESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        JsFlavor::Typescript => {
                            GRAVATAR_TEMPLATE_STATIC_TYPESCRIPT_DIR.extract(&project_root_path)?;
                        }
                        JsFlavor::Javascript => return Err("Js not yet handled".into()),
                    }
                }
                Template::OtherPlaceHolder => (),
            }

            Ok(())
        }

        CommandType::Codegen(args) => {
            let parsed_paths = ParsedPaths::new(args.to_project_paths_args())?;
            let project_paths = &parsed_paths.project_paths;

            fs::create_dir_all(&project_paths.generated)?;

            let mut rescript_subrecord_dependencies = RescriptRecordHierarchyLinkedHashMap::new();
            let contract_types = event_parsing::get_contract_types_from_config(
                &parsed_paths,
                &mut rescript_subrecord_dependencies,
            )?;

            let entity_types = entity_parsing::get_entity_record_types_from_schema(&parsed_paths)?;
            let chain_config_templates =
                config_parsing::convert_config_to_chain_configs(&parsed_paths)?;
            let sub_record_dependencies = rescript_subrecord_dependencies
                .iter()
                .collect::<Vec<RecordType>>();

            CODEGEN_STATIC_DIR.extract(&project_paths.generated)?;

            generate_templates(
                sub_record_dependencies,
                contract_types,
                chain_config_templates,
                entity_types,
                &project_paths,
            )?;

            println!("installing packages... ");

            Command::new("pnpm")
                .arg("install")
                .current_dir(&project_paths.generated)
                .spawn()?
                .wait()?;

            println!("clean build directory");

            Command::new("pnpm")
                .arg("clean")
                .current_dir(&project_paths.generated)
                .spawn()?
                .wait()?;

            println!("formatting code");

            Command::new("pnpm")
                .arg("rescript")
                .arg("format")
                .arg("-all")
                .current_dir(&project_paths.generated)
                .spawn()?
                .wait()?;

            println!("building code");

            Command::new("pnpm")
                .arg("build")
                .current_dir(&project_paths.generated)
                .spawn()?
                .wait()?;

            println!("generate db bigrations");

            Command::new("pnpm")
                .arg("db-migrate")
                .current_dir(&project_paths.generated)
                .spawn()?
                .wait()?;

            Ok(())
        }
    }
}
