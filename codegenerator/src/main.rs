use std::error::Error;
use std::process::Command;

use rust_code_gen::{
    config_parsing, copy_directory, entity_parsing, event_parsing, generate_types,
};

const CODE_GEN_PATH: &str = "../scenarios/test_codegen/generated";
const PROJECT_ROOT_PATH: &str = "../scenarios/test_codegen";

fn main() -> Result<(), Box<dyn Error>> {
    copy_directory("templates/static", CODE_GEN_PATH)?;
    let config = config_parsing::get_config_from_yaml(PROJECT_ROOT_PATH)?;
    let contract_types = event_parsing::get_contract_types_from_config(PROJECT_ROOT_PATH, config)?;
    let entity_types = entity_parsing::get_entity_record_types_from_schema(PROJECT_ROOT_PATH)?;

    generate_types(contract_types, entity_types, CODE_GEN_PATH)?;

    println!("installing packages... ");

    Command::new("pnpm")
        .arg("install")
        .current_dir(CODE_GEN_PATH)
        .spawn()?
        .wait()?;

    print!("formatting code");

    Command::new("pnpm")
        .arg("rescript")
        .arg("format")
        .arg("-all")
        .current_dir(CODE_GEN_PATH)
        .spawn()?
        .wait()?;

    print!("building code");

    Command::new("pnpm")
        .arg("build")
        .current_dir(CODE_GEN_PATH)
        .spawn()?
        .wait()?;

    Ok(())
}
