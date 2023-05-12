use std::error::Error;
use std::fs;
use std::path::Path;

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

pub trait HasName {
    fn set_name(&mut self, name: CapitalizedOptions);
}

#[derive(Serialize, Debug, PartialEq, Clone)]
struct EventParamType {
    key: String,
    type_rescript: String,
}
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventRecordType {
    name: CapitalizedOptions,
    params: Vec<EventParamType>,
}
impl HasName for EventRecordType {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
struct EntityParamType {
    key: String,
    type_rescript: String,
    type_pg: String,
}
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRecordType {
    name: CapitalizedOptions,
    params: Vec<EntityParamType>,
}

impl HasName for EntityRecordType {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq)]
pub struct RequiredEntityTemplate {
    name: CapitalizedOptions,
    labels: Vec<String>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct EventTemplate {
    name: CapitalizedOptions,
    params: Vec<EventParamType>,
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

#[derive(Serialize)]
struct TypesTemplate {
    sub_record_dependencies: Vec<EventRecordType>,
    contracts: Vec<Contract>,
    entities: Vec<EntityRecordType>,
    chain_configs: Vec<ChainConfigTemplate>,
    codegen_out_path: String,
}

pub fn generate_templates(
    sub_record_dependencies: Vec<EventRecordType>,
    contracts: Vec<Contract>,
    chain_configs: Vec<ChainConfigTemplate>,
    entity_types: Vec<EntityRecordType>,
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
    let templates = [
        (
            "src/Types.res",
            include_str!("../templates/dynamic/src/Types.res"),
        ),
        (
            "src/Abis.res",
            include_str!("../templates/dynamic/src/Abis.res"),
        ),
        (
            "src/Handlers.res",
            include_str!("../templates/dynamic/src/Handlers.res"),
        ),
        (
            "src/DbFunctions.res",
            include_str!("../templates/dynamic/src/DbFunctions.res"),
        ),
        (
            "src/EventProcessing.res",
            include_str!("../templates/dynamic/src/EventProcessing.res"),
        ),
        (
            "src/Config.res",
            include_str!("../templates/dynamic/src/Config.res"),
        ),
        (
            "src/IO.res",
            include_str!("../templates/dynamic/src/IO.res"),
        ),
        (
            "src/Converters.res",
            include_str!("../templates/dynamic/src/Converters.res"),
        ),
        (
            "src/EventSyncing.res",
            include_str!("../templates/dynamic/src/EventSyncing.res"),
        ),
        (
            "src/Context.res",
            include_str!("../templates/dynamic/src/Context.res"),
        ),
        (
            "register_tables_with_hasura.sh",
            include_str!("../templates/dynamic/register_tables_with_hasura.sh"),
        ),
        (
            ".gitignore",
            include_str!("../templates/dynamic/.gitignore"),
        ),
        (
            "src/Index.res",
            include_str!("../templates/dynamic/src/Index.res"),
        ),
        (
            "src/Migrations.res",
            include_str!("../templates/dynamic/src/Migrations.res"),
        ),
        (
            "src/DbFunctionsImplementation.js",
            include_str!("../templates/dynamic/src/DbFunctionsImplementation.js.hbs"),
        ),
    ];

    for (template_path, template_content) in &templates {
        let rendered_string = handlebars.render_template(template_content, &types_data)?;
        write_to_file_in_generated(template_path, &rendered_string, project_paths)?;
    }

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

#[cfg(unix)]
fn set_executable_permissions(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(&path)?.permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&path, permissions)?;
    Ok(())
}

#[cfg(windows)]
///Impossible to set an executable mode on windows
///This function is simply for the hasura script for now
///So we can add some manual wsl steps for windows users
fn set_executable_permissions(path: &Path) -> std::io::Result<()> {
    let mut permissions = fs::metadata(&path)?.permissions();
    permissions.set_readonly(false);
    fs::set_permissions(&path, permissions)?;

    Ok(())
}

fn make_file_executable(filename: &str, project_paths: &ProjectPaths) -> std::io::Result<()> {
    let file_path = &project_paths.generated.join(filename);

    set_executable_permissions(&file_path)
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
