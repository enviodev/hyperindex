use std::error::Error;
use std::fs;
use std::os::unix::fs::PermissionsExt; // NOTE: This probably won't be the same on Windows.

use handlebars::Handlebars;

use serde::Serialize;

pub mod config_parsing;
pub mod linked_hashmap;
pub mod project_paths;

use project_paths::{handler_paths::HandlerPathsTemplate, ProjectPaths};

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
    handler: HandlerPathsTemplate,
}

type EntityTemplate = RecordType;

#[derive(Serialize)]
struct TypesTemplate {
    sub_record_dependencies: Vec<RecordType>,
    contracts: Vec<Contract>,
    entities: Vec<EntityTemplate>,
    chain_configs: Vec<ChainConfigTemplate>,
    codegen_out_path: String,
}

pub fn generate_templates(
    sub_record_dependencies: Vec<RecordType>,
    contracts: Vec<Contract>,
    chain_configs: Vec<ChainConfigTemplate>,
    entity_types: Vec<RecordType>,
    project_paths: &ProjectPaths,
) -> Result<(), Box<dyn Error>> {
    let mut handlebars = Handlebars::new();

    handlebars.set_strict_mode(true);
    handlebars.register_escape_fn(handlebars::no_escape);

    //TODO: make this a method in path handlers
    let gitignore_generated_path = project_paths.generated.join("*");
    let gitignoer_path_str = gitignore_generated_path
        .to_str()
        .ok_or("invalid codegen path")?
        .to_string();

    let types_data = TypesTemplate {
        sub_record_dependencies,
        contracts,
        entities: entity_types,
        chain_configs,
        codegen_out_path: gitignoer_path_str,
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

    write_to_file_in_generated(".gitignore", &rendered_string_gitignore, project_paths)?;
    write_to_file_in_generated("src/Types.res", &rendered_string_types, project_paths)?;
    write_to_file_in_generated("src/Config.res", &rendered_string_config, project_paths)?;
    write_to_file_in_generated("src/Abis.res", &rendered_string_abi, project_paths)?;
    write_to_file_in_generated("src/Handlers.res", &rendered_string_handlers, project_paths)?;
    write_to_file_in_generated(
        "src/DbFunctions.res",
        &rendered_string_db_functions,
        project_paths,
    )?;
    write_to_file_in_generated(
        "src/EventProcessing.res",
        &rendered_string_event_processing,
        project_paths,
    )?;
    write_to_file_in_generated("src/IO.res", &rendered_string_io, project_paths)?;
    write_to_file_in_generated(
        "src/DbSchema.res",
        &rendered_string_db_schema,
        project_paths,
    )?;
    write_to_file_in_generated(
        "src/Converters.res",
        &rendered_string_converters,
        project_paths,
    )?;
    write_to_file_in_generated(
        "src/EventSyncing.res",
        &rendered_string_event_syncing,
        project_paths,
    )?;
    write_to_file_in_generated("src/Context.res", &rendered_string_context, project_paths)?;
    write_to_file_in_generated(
        "register_tables_with_hasura.sh",
        &rendered_string_register_tables_with_hasura,
        project_paths,
    )?;
    write_to_file_in_generated("src/Index.res", &rendered_string_index, project_paths)?;

    make_file_executable("register_tables_with_hasura.sh", project_paths)?;

    Ok(())
}

fn write_to_file_in_generated(
    filename: &str,
    content: &str,
    project_paths: &ProjectPaths,
) -> std::io::Result<()> {
    fs::create_dir_all(&project_paths.generated)?;
    let file_path = &project_paths.generated.join(filename);
    fs::write(file_path, content)
}

/// This function allows files to be executed as a script
fn make_file_executable(filename: &str, project_paths: &ProjectPaths) -> std::io::Result<()> {
    let file_path = &project_paths.generated.join(filename);

    let mut permissions = fs::metadata(&file_path)?.permissions();
    permissions.set_mode(0o755); // Set the file permissions to -rwxr-xr-x
    fs::set_permissions(&file_path, permissions)?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    #[test]
    fn wildcard_path_join() {
        let expected_string = "my_dir/*";
        let parent_path = PathBuf::from("my_dir");
        let wild_card_path = PathBuf::from("*");
        let joined = parent_path.join(wild_card_path);
        let joined_str = joined.to_str().unwrap();

        assert_eq!(expected_string, joined_str);
    }
}
