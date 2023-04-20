use std::error::Error;
use std::fs;
use std::os::unix::fs::PermissionsExt; // NOTE: This probably won't be the same on Windows.
use std::path::PathBuf;

use handlebars::Handlebars;

use include_dir::{Dir, DirEntry};
use serde::Serialize;

pub mod config_parsing;

pub use config_parsing::{entity_parsing, event_parsing, ChainConfigTemplate};

pub mod capitalization;
pub mod cli_args;

use capitalization::CapitalizedOptions;
#[derive(Serialize, Debug, PartialEq, Clone)]
struct ParamType {
    key: String,
    type_: String,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
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

#[derive(Serialize, Debug)]
pub struct HandlerPaths {
    absolute: String,
    relative_to_generated_src: String,
}

#[derive(Serialize)]
pub struct Contract {
    name: CapitalizedOptions,
    events: Vec<EventTemplate>,
    handler: HandlerPaths,
}

type EntityTemplate = RecordType;

#[derive(Serialize)]
struct TypesTemplate {
    contracts: Vec<Contract>,
    entities: Vec<EntityTemplate>,
    chain_configs: Vec<ChainConfigTemplate>,
    codegen_out_path: String,
}

pub fn generate_templates(
    contracts: Vec<Contract>,
    chain_configs: Vec<ChainConfigTemplate>,
    entity_types: Vec<RecordType>,
    codegen_path: &PathBuf,
) -> Result<(), Box<dyn Error>> {
    let mut handlebars = Handlebars::new();

    handlebars.set_strict_mode(true);
    handlebars.register_escape_fn(handlebars::no_escape);

    let codegen_path_str = codegen_path.to_str().ok_or("invalid codegen path")?;
    let codegen_out_path = format!("{}/*", codegen_path_str);

    let types_data = TypesTemplate {
        contracts,
        entities: entity_types,
        chain_configs,
        codegen_out_path,
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
    let rendered_string_gitignore =
        handlebars.render_template(include_str!("../templates/dynamic/.gitignore"), &types_data)?;
    let rendered_string_index = handlebars.render_template(
        include_str!("../templates/dynamic/src/Index.res"),
        &types_data,
    )?;

    write_to_file_in_generated(".gitignore", &rendered_string_gitignore, codegen_path)?;
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
    write_to_file_in_generated("src/Index.res", &rendered_string_index, codegen_path)?;

    make_file_executable("register_tables_with_hasura.sh", codegen_path)?;

    Ok(())
}

fn write_to_file_in_generated(
    filename: &str,
    content: &str,
    codegen_path: &PathBuf,
) -> std::io::Result<()> {
    fs::create_dir_all(codegen_path)?;
    let file_path = codegen_path.join(filename);
    fs::write(file_path, content)
}

/// This function allows files to be executed as a script
fn make_file_executable(filename: &str, codegen_path: &PathBuf) -> std::io::Result<()> {
    let file_path = codegen_path.join(filename);

    let mut permissions = fs::metadata(&file_path)?.permissions();
    permissions.set_mode(0o755); // Set the file permissions to -rwxr-xr-x
    fs::set_permissions(&file_path, permissions)?;

    Ok(())
}

pub fn copy_dir(from: &Dir, to_root: &PathBuf) -> Result<(), std::io::Error> {
    for entry in from.entries().iter() {
        match entry {
            DirEntry::Dir(dir) => {
                let path = dir.path();
                let to_path = to_root.join(path);

                fs::create_dir_all(&to_path)?;
                copy_dir(&dir, &to_root)?;
            }
            DirEntry::File(file) => {
                let path = file.path();
                let to_path = to_root.join(path);

                let file_content = file.contents();
                fs::write(&to_path, file_content)?;
            }
        }
    }

    Ok(())
}
