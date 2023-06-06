use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::path::Path;

use handlebars::Handlebars;

use include_dir::{include_dir, Dir, DirEntry};
use serde::Serialize;

pub mod config_parsing;
pub mod linked_hashmap;
pub mod project_paths;

use project_paths::{handler_paths::HandlerPathsTemplate, ProjectPaths};

pub use config_parsing::{entity_parsing, event_parsing, ChainConfigTemplate};

pub mod capitalization;
pub mod cli_args;

use capitalization::{Capitalize, CapitalizedOptions};

use crate::project_paths::path_utils::normalize_path;

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
struct EntityRelationalTypes {
    relational_key: CapitalizedOptions,
    mapped_entity: CapitalizedOptions,
    relationship_type: String,
    is_optional: bool,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
struct EntityParamType {
    key: String,
    is_optional: bool,
    type_rescript: String,
    type_pg: String,
    maybe_entity_name: Option<CapitalizedOptions>,
}
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRecordType {
    name: CapitalizedOptions,
    params: Vec<EntityParamType>,
    relational_params: Vec<EntityRelationalTypes>,
}

impl HasName for EntityRecordType {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct RequiredEntityEntityField {
    field_name: CapitalizedOptions,
    type_name: CapitalizedOptions,
    is_optional: bool,
    is_array: bool,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct RequiredEntityTemplate {
    name: CapitalizedOptions,
    labels: Vec<String>,
    entity_fields_of_required_entity: Vec<RequiredEntityEntityField>,
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

/// transform entities into a map from entity name to a list of all linked entities (entity fields) on that entity.
pub fn entities_to_map(
    entities: Vec<EntityRecordType>,
) -> HashMap<String, Vec<RequiredEntityEntityField>> {
    let mut map: HashMap<String, Vec<RequiredEntityEntityField>> = HashMap::new();

    for entity in entities {
        let entity_name = entity.name.capitalized;

        let mut related_entities = vec![];
        for param in entity.params {
            if let Some(entity_name) = param.maybe_entity_name {
                let required_entity: RequiredEntityEntityField = RequiredEntityEntityField {
                    is_array: param.type_rescript.starts_with("array"),
                    field_name: param.key.to_owned().to_capitalized_options(),
                    type_name: entity_name,
                    is_optional: param.is_optional,
                };
                related_entities.push(required_entity);
            }
        }

        map.insert(entity_name, related_entities);
    }

    map
}

pub fn generate_templates(
    sub_record_dependencies: Vec<EventRecordType>,
    contracts: Vec<Contract>,
    chain_configs: Vec<ChainConfigTemplate>,
    entity_types: Vec<EntityRecordType>,
    project_paths: &ProjectPaths,
) -> Result<(), Box<dyn Error>> {
    static CODEGEN_DYNAMIC_DIR: Dir<'_> = include_dir!("templates/dynamic/codegen");
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

    let hbs =
        HandleBarsDirGenerator::new(&CODEGEN_DYNAMIC_DIR, &types_data, &project_paths.generated);
    hbs.generate_hbs_templates()?;

    make_file_executable("register_tables_with_hasura.sh", project_paths)?;

    Ok(())
}

pub struct HandleBarsDirGenerator<'a, T: Serialize> {
    handlebars: handlebars::Handlebars<'a>,
    templates_dir: &'a Dir<'a>,
    rs_template: &'a T,
    output_dir: &'a Path,
}

impl<'a, T: Serialize> HandleBarsDirGenerator<'a, T> {
    pub fn new(templates_dir: &'a Dir, rs_template: &'a T, output_dir: &'a Path) -> Self {
        let mut handlebars = Handlebars::new();
        handlebars.set_strict_mode(true);
        handlebars.register_escape_fn(handlebars::no_escape);

        HandleBarsDirGenerator {
            handlebars,
            templates_dir,
            rs_template,
            output_dir,
        }
    }

    fn generate_hbs_templates_internal_recersive(
        &self,
        hbs_templates_root_dir: &Dir,
    ) -> Result<(), String> {
        for entry in hbs_templates_root_dir.entries() {
            match entry {
                DirEntry::File(file) => {
                    let path = file.path();
                    let is_hbs_file = path.extension().map_or(false, |ext| ext == "hbs");

                    if is_hbs_file {
                        // let get_path_str = |path: AsRef<Path>>| path.to_str().unwrap_or_else(|| "bad path");
                        let path_str = path.to_str().ok_or_else(|| {
                            "Could not cast path to str in generate_hbs_templates"
                        })?;
                        //Get the parent of the file src/MyTemplate.res.hbs -> src/
                        let parent = path
                            .parent()
                            .ok_or_else(|| format!("Could not produce parent of {}", path_str))?;

                        //Get the file stem src/MyTemplate.res.hbs -> MyTemplate.res
                        let file_stem = path
                            .file_stem()
                            .ok_or_else(|| format!("Could not produce filestem of {}", path_str))?;

                        //Read the template file contents
                        let file_str = file.contents_utf8().ok_or_else(|| {
                            format!("Could not produce file contents of {}", path_str)
                        })?;

                        //Render the template
                        let rendered_file = self
                            .handlebars
                            .render_template(file_str, &self.rs_template)
                            .map_err(|e| {
                                format!("Could not render file at {} error: {}", path_str, e)
                            })?;

                        //Setup output directory
                        let output_dir_path =
                            normalize_path(self.output_dir.join(parent).as_path());
                        let output_dir_path_str = output_dir_path.to_str().ok_or_else(|| {
                            "Could not cast output path to str in generate_hbs_templates"
                        })?;

                        //ensure the dir exists or is created
                        fs::create_dir_all(&output_dir_path).map_err(|e| {
                            format!(
                                "create_dir_all failed at {} error: {}",
                                &output_dir_path_str, e
                            )
                        })?;

                        //append the filename
                        let output_file_path = output_dir_path.join(file_stem);

                        //Write the file
                        fs::write(&output_file_path, rendered_file).map_err(|e| {
                            format!("file write failed at {} error: {}", &output_dir_path_str, e)
                        })?;
                    }
                }
                DirEntry::Dir(dir) => Self::generate_hbs_templates_internal_recersive(self, &dir)?,
            }
        }
        Ok(())
    }
    pub fn generate_hbs_templates(&self) -> Result<(), String> {
        Self::generate_hbs_templates_internal_recersive(&self, self.templates_dir)
    }
}

#[derive(Serialize)]
pub struct InitTemplates {
    project_name: String,
    is_rescript: bool,
    is_typescript: bool,
    is_javascript: bool,
}

impl InitTemplates {
    pub fn new(project_name: String, lang: &cli_args::Language) -> Self {
        let template = InitTemplates {
            project_name,
            is_rescript: false,
            is_typescript: false,
            is_javascript: false,
        };

        use cli_args::Language;
        match lang {
            Language::Rescript => InitTemplates {
                is_rescript: true,
                ..template
            },

            Language::Typescript => InitTemplates {
                is_typescript: true,
                ..template
            },
            Language::Javascript => InitTemplates {
                is_javascript: true,
                ..template
            },
        }
    }
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
