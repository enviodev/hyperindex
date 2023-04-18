use std::error::Error;
use std::fs;
use std::os::unix::fs::PermissionsExt; // NOTE: This probably won't be the same on Windows.
use std::path::{Path, PathBuf};

use handlebars::Handlebars;

use serde::Serialize;

pub mod config_parsing;

pub use config_parsing::{entity_parsing, event_parsing, ChainConfigTemplate};

pub mod capitalization;
pub mod cli_args;

use capitalization::CapitalizedOptions;
#[derive(Serialize, Debug, PartialEq)]
struct ParamType {
    key: String,
    type_: String,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct RecordType {
    name: CapitalizedOptions,
    params: Vec<ParamType>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct RequiredEntityTemplate {
    name: CapitalizedOptions,
    labels: Vec<String>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct EventTemplate {
    name: CapitalizedOptions,
    params: Vec<ParamType>,
    required_entities: Vec<RequiredEntityTemplate>,
}

#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    events: Vec<EventTemplate>,
}

type EntityTemplate = RecordType;

#[derive(Serialize)]
struct TypesTemplate {
    contracts: Vec<Contract>,
    entities: Vec<EntityTemplate>,
    chain_configs: Vec<ChainConfigTemplate>,
}

pub fn generate_templates(
    contracts: Vec<Contract>,
    chain_configs: Vec<ChainConfigTemplate>,
    entity_types: Vec<RecordType>,
    codegen_path: &str,
) -> Result<(), Box<dyn Error>> {
    let mut handlebars = Handlebars::new();

    handlebars.set_strict_mode(true);
    handlebars.register_escape_fn(handlebars::no_escape);

    let types_data = TypesTemplate {
        contracts,
        entities: entity_types,
        chain_configs,
    };

    let rendered_string_types = handlebars.render_template(
        include_str!("../templates/dynamic/src/Types.res"),
        &types_data,
    )?;
    let rendered_string_abi = handlebars.render_template(
        include_str!("../templates/dynamic/src/Abis.res"),
        &types_data,
    )?;
    let rendered_string_handlers = handlebars.render_template(
        include_str!("../templates/dynamic/src/Handlers.res"),
        &types_data,
    )?;
    let rendered_string_db_functions = handlebars.render_template(
        include_str!("../templates/dynamic/src/DbFunctions.res"),
        &types_data,
    )?;
    let rendered_string_event_processing = handlebars.render_template(
        include_str!("../templates/dynamic/src/EventProcessing.res"),
        &types_data,
    )?;
    let rendered_string_config = handlebars.render_template(
        include_str!("../templates/dynamic/src/Config.res"),
        &types_data,
    )?;
    let rendered_string_io =
        handlebars.render_template(include_str!("../templates/dynamic/src/IO.res"), &types_data)?;
    let rendered_string_db_schema = handlebars.render_template(
        include_str!("../templates/dynamic/src/DbSchema.res"),
        &types_data,
    )?;
    let rendered_string_converters = handlebars.render_template(
        include_str!("../templates/dynamic/src/Converters.res"),
        &types_data,
    )?;
    let rendered_string_event_syncing = handlebars.render_template(
        include_str!("../templates/dynamic/src/EventSyncing.res"),
        &types_data,
    )?;
    let rendered_string_context = handlebars.render_template(
        include_str!("../templates/dynamic/src/Context.res"),
        &types_data,
    )?;
    let rendered_string_register_tables_with_hasura = handlebars.render_template(
        include_str!("../templates/dynamic/register_tables_with_hasura.sh"),
        &types_data,
    )?;

    write_to_file_in_generated("src/Types.res", &rendered_string_types, codegen_path)?;
    write_to_file_in_generated("src/Config.res", &rendered_string_config, codegen_path)?;
    write_to_file_in_generated("src/Abis.res", &rendered_string_abi, codegen_path)?;
    write_to_file_in_generated("src/Handlers.res", &rendered_string_handlers, codegen_path)?;
    write_to_file_in_generated(
        "src/DbFunctions.res",
        &rendered_string_db_functions,
        codegen_path,
    )?;
    write_to_file_in_generated(
        "src/EventProcessing.res",
        &rendered_string_event_processing,
        codegen_path,
    )?;
    write_to_file_in_generated("src/IO.res", &rendered_string_io, codegen_path)?;
    write_to_file_in_generated("src/DbSchema.res", &rendered_string_db_schema, codegen_path)?;
    write_to_file_in_generated(
        "src/Converters.res",
        &rendered_string_converters,
        codegen_path,
    )?;
    write_to_file_in_generated(
        "src/EventSyncing.res",
        &rendered_string_event_syncing,
        codegen_path,
    )?;
    write_to_file_in_generated("src/Context.res", &rendered_string_context, codegen_path)?;
    write_to_file_in_generated(
        "register_tables_with_hasura.sh",
        &rendered_string_register_tables_with_hasura,
        codegen_path,
    )?;
    make_file_executable("register_tables_with_hasura.sh", codegen_path)?;
    Ok(())
}

fn write_to_file_in_generated(
    filename: &str,
    content: &str,
    codegen_path: &str,
) -> std::io::Result<()> {
    fs::create_dir_all(codegen_path)?;
    fs::write(format! {"{}/{}", codegen_path, filename}, content)
}

/// This function allows files to be executed as
fn make_file_executable(filename: &str, codegen_path: &str) -> std::io::Result<()> {
    let file_path = format!("{}/{}", codegen_path, filename);

    let mut permissions = fs::metadata(&file_path)?.permissions();
    permissions.set_mode(0o755); // Set the file permissions to -rwxr-xr-x
    fs::set_permissions(&file_path, permissions)?;

    Ok(())
}

pub fn copy_directory<U: AsRef<Path>, V: AsRef<Path>>(
    from: U,
    to: V,
) -> Result<(), std::io::Error> {
    let mut stack = Vec::new();
    stack.push(PathBuf::from(from.as_ref()));

    let output_root = PathBuf::from(to.as_ref());
    let input_root = PathBuf::from(from.as_ref()).components().count();

    while let Some(working_path) = stack.pop() {
        println!("process: {:?}", &working_path);

        // Generate a relative path
        let src: PathBuf = working_path.components().skip(input_root).collect();

        // Create a destination if missing
        let dest = if src.components().count() == 0 {
            output_root.clone()
        } else {
            output_root.join(&src)
        };
        if fs::metadata(&dest).is_err() {
            println!(" mkdir: {:?}", dest);
            fs::create_dir_all(&dest)?;
        }

        for entry in fs::read_dir(working_path)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                match path.file_name() {
                    Some(filename) => {
                        let dest_path = dest.join(filename);
                        println!("  copy: {:?} -> {:?}", &path, &dest_path);
                        fs::copy(&path, &dest_path)?;
                    }
                    None => {
                        println!("failed: {:?}", path);
                    }
                }
            }
        }
    }

    Ok(())
}
