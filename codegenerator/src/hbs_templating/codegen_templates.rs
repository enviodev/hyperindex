use std::collections::HashMap;
use std::error::Error;

use super::hbs_dir_generator::HandleBarsDirGenerator;
use crate::capitalization::Capitalize;
use crate::config_parsing::ChainConfigTemplate;
use crate::project_paths::handler_paths::HandlerPathsTemplate;
use crate::project_paths::ProjectPaths;
use crate::{capitalization::CapitalizedOptions, make_file_executable};
use include_dir::{include_dir, Dir};
use serde::Serialize;

pub trait HasName {
    fn set_name(&mut self, name: CapitalizedOptions);
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventParamTypeTemplate {
    pub key: String,
    pub type_rescript: String,
}
#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EventRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EventParamTypeTemplate>,
}
impl HasName for EventRecordTypeTemplate {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
#[serde(rename_all = "lowercase")]
pub enum RelationshipTypeTemplate {
    Object,
    Array,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRelationalTypesTemplate {
    pub relational_key: CapitalizedOptions,
    pub mapped_entity: CapitalizedOptions,
    pub relationship_type: RelationshipTypeTemplate,
    pub is_array: bool,
    pub is_optional: bool,
    pub derived_from_field_key: Option<CapitalizedOptions>,
}

pub trait HasIsDerivedFrom {
    fn get_is_derived_from(&self) -> bool;
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct FilteredTemplateLists<T: HasIsDerivedFrom> {
    pub all: Vec<T>,
    pub filtered_not_derived_from: Vec<T>,
}

impl<T: HasIsDerivedFrom + Clone> FilteredTemplateLists<T> {
    pub fn new(unfiltered: Vec<T>) -> Self {
        let filtered_not_derived_from = unfiltered
            .iter()
            .filter(|item| !item.get_is_derived_from())
            .cloned()
            .collect::<Vec<T>>();

        FilteredTemplateLists {
            all: unfiltered,
            filtered_not_derived_from,
        }
    }

    #[cfg(test)]
    pub fn empty() -> Self {
        FilteredTemplateLists {
            all: Vec::new(),
            filtered_not_derived_from: Vec::new(),
        }
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityParamTypeTemplate {
    pub key: String,
    pub is_optional: bool,
    pub type_rescript: String,
    pub type_rescript_non_optional: String,
    pub type_pg: String,
    pub maybe_entity_name: Option<CapitalizedOptions>,
    ///Used in template to tell whether it is a field looked up from another table or a value in
    ///the table
    pub is_derived_from: bool,
}

impl HasIsDerivedFrom for EntityRelationalTypesTemplate {
    fn get_is_derived_from(&self) -> bool {
        match self.derived_from_field_key {
            None => false,
            Some(_) => true,
        }
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct EntityRecordTypeTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EntityParamTypeTemplate>,
    pub relational_params: FilteredTemplateLists<EntityRelationalTypesTemplate>,
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct SyncConfigTemplate {
    pub initial_block_interval: u32,
    pub backoff_multiplicative: f32,
    pub acceleration_additive: u32,
    pub interval_ceiling: u32,
    pub backoff_millis: u32,
    pub query_timeout_millis: u32,
}

impl HasName for EntityRecordTypeTemplate {
    fn set_name(&mut self, name: CapitalizedOptions) {
        self.name = name;
    }
}

#[derive(Serialize, Debug, PartialEq, Clone)]
pub struct RequiredEntityEntityFieldTemplate {
    pub field_name: CapitalizedOptions,
    pub type_name: CapitalizedOptions,
    pub is_optional: bool,
    pub is_array: bool,
    pub is_derived_from: bool,
}

impl HasIsDerivedFrom for RequiredEntityEntityFieldTemplate {
    fn get_is_derived_from(&self) -> bool {
        self.is_derived_from
    }
}

#[derive(Serialize, Debug, PartialEq)]
pub struct RequiredEntityTemplate {
    pub name: CapitalizedOptions,
    pub labels: Vec<String>,
    pub entity_fields_of_required_entity: FilteredTemplateLists<RequiredEntityEntityFieldTemplate>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct EventTemplate {
    pub name: CapitalizedOptions,
    pub params: Vec<EventParamTypeTemplate>,
    pub required_entities: Vec<RequiredEntityTemplate>,
}

#[derive(Serialize)]
pub struct ContractTemplate {
    pub name: CapitalizedOptions,
    pub events: Vec<EventTemplate>,
    pub handler: HandlerPathsTemplate,
}

#[derive(Serialize)]
struct TypesTemplate {
    project_name: String,
    sub_record_dependencies: Vec<EventRecordTypeTemplate>,
    contracts: Vec<ContractTemplate>,
    entities: Vec<EntityRecordTypeTemplate>,
    chain_configs: Vec<ChainConfigTemplate>,
    codegen_out_path: String,
    sync_config: SyncConfigTemplate,
}

/// transform entities into a map from entity name to a list of all linked entities (entity fields) on that entity.
pub fn entities_to_map(
    entities: Vec<EntityRecordTypeTemplate>,
) -> HashMap<String, Vec<RequiredEntityEntityFieldTemplate>> {
    let mut map: HashMap<String, Vec<RequiredEntityEntityFieldTemplate>> = HashMap::new();

    for entity in entities {
        let entity_name = entity.name.capitalized;

        let mut related_entities = vec![];
        for param in entity.params {
            if let Some(entity_name) = param.maybe_entity_name {
                let required_entity = RequiredEntityEntityFieldTemplate {
                    is_array: param.type_rescript.starts_with("array"),
                    field_name: param.key.to_owned().to_capitalized_options(),
                    type_name: entity_name,
                    is_optional: param.is_optional,
                    is_derived_from: param.is_derived_from,
                };
                related_entities.push(required_entity);
            }
        }

        map.insert(entity_name, related_entities);
    }

    map
}

pub fn generate_templates(
    sub_record_dependencies: Vec<EventRecordTypeTemplate>,
    contracts: Vec<ContractTemplate>,
    chain_configs: Vec<ChainConfigTemplate>,
    entity_types: Vec<EntityRecordTypeTemplate>,
    project_paths: &ProjectPaths,
    sync_config: SyncConfigTemplate,
    project_name: String,
) -> Result<(), Box<dyn Error>> {
    static CODEGEN_DYNAMIC_DIR: Dir<'_> = include_dir!("templates/dynamic/codegen");
    let mut handlebars = handlebars::Handlebars::new();
    handlebars.set_strict_mode(true);
    handlebars.register_escape_fn(handlebars::no_escape);

    //TODO: make this a method in path handlers
    let gitignore_generated_path = project_paths.generated.join("*");
    let gitignore_path_str = gitignore_generated_path
        .to_str()
        .ok_or("invalid codegen path")?
        .to_string();

    let types_data = TypesTemplate {
        sub_record_dependencies,
        contracts,
        entities: entity_types,
        chain_configs,
        codegen_out_path: gitignore_path_str,
        sync_config,
        project_name,
    };

    let hbs =
        HandleBarsDirGenerator::new(&CODEGEN_DYNAMIC_DIR, &types_data, &project_paths.generated);
    hbs.generate_hbs_templates()?;

    make_file_executable("register_tables_with_hasura.sh", project_paths)?;

    Ok(())
}
