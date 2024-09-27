use super::{
    postgres_types::{Field as PGField, Primitive as PGPrimitive},
    validation::{
        check_enums_for_internal_reserved_words, check_names_from_schema_for_reserved_words,
        is_valid_postgres_db_name,
    },
};
use crate::{
    constants::project_paths::DEFAULT_SCHEMA_PATH,
    hbs_templating::codegen_templates::DerivedFieldTemplate,
    project_paths::{path_utils, ParsedProjectPaths},
    rescript_types::RescriptTypeIdent,
    utils::{text::Capitalize, unique_hashmap},
};
use anyhow::{anyhow, Context};
use ethers::abi::ethabi::ParamType as EthAbiParamType;
use graphql_parser::schema::{
    Definition, Directive, Document, EnumType, Field as ObjField, ObjectType, Type as ObjType,
    TypeDefinition, Value,
};
use itertools::Itertools;
use serde::{Serialize, Serializer};
use std::{
    collections::{HashMap, HashSet},
    fmt::{self},
    path::PathBuf,
};
use subenum::subenum;

#[derive(Debug, Clone, PartialEq)]
pub struct Schema {
    pub entities: HashMap<String, Entity>,
    pub enums: HashMap<String, GraphQLEnum>,
}

enum TypeDef<'a> {
    Entity(&'a Entity),
    Enum,
}

#[derive(thiserror::Error, Debug)]
enum SchemaParseError {
    #[error("Failed parsing entity '{entity_name}': {err}")]
    EntityParseError {
        err: EntityParseError,
        entity_name: String,
    },
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl Schema {
    pub fn empty() -> Self {
        Schema {
            entities: HashMap::new(),
            enums: HashMap::new(),
        }
    }

    pub fn new(entities: Vec<Entity>, enums: Vec<GraphQLEnum>) -> anyhow::Result<Self> {
        let entities = unique_hashmap::from_vec_no_duplicates(
            entities.into_iter().map(|e| (e.name.clone(), e)).collect(),
        )
        .context("Found entities with duplicate names")?;
        let enums = unique_hashmap::from_vec_no_duplicates(
            enums.into_iter().map(|e| (e.name.clone(), e)).collect(),
        )
        .context("Found enums with duplicate names")?;

        Self { entities, enums }.validate()
    }

    fn from_document(document: Document<String>) -> Result<Self, SchemaParseError> {
        let entities = document
            .definitions
            .iter()
            .filter_map(|d| match d {
                Definition::TypeDefinition(type_def) => Some(type_def),
                _ => None,
            })
            .filter_map(|type_def| match type_def {
                TypeDefinition::Object(obj) => Some(obj),
                _ => None,
            })
            .map(|obj| {
                Entity::from_object(obj).map_err(|err| SchemaParseError::EntityParseError {
                    err,
                    entity_name: obj.name.clone(),
                })
            })
            .collect::<Result<Vec<Entity>, _>>()?;

        let enums = document
            .definitions
            .iter()
            .filter_map(|d| match d {
                Definition::TypeDefinition(type_def) => Some(type_def),
                _ => None,
            })
            .filter_map(|type_def| match type_def {
                TypeDefinition::Enum(obj) => Some(obj),
                _ => None,
            })
            .map(|obj| GraphQLEnum::from_enum(obj))
            .collect::<anyhow::Result<Vec<GraphQLEnum>>>()
            .context("Failed constructing enums in schema from document")?;

        Ok(Self::new(entities, enums)?)
    }

    pub fn parse_from_file(
        project_paths: &ParsedProjectPaths,
        maybe_custom_path: &Option<String>,
    ) -> anyhow::Result<Self> {
        let relative_schema_path_from_config = match maybe_custom_path {
            Some(custom_path) => custom_path.clone(),
            None => DEFAULT_SCHEMA_PATH.to_string(),
        };

        let schema_path = path_utils::get_config_path_relative_to_root(
            project_paths,
            PathBuf::from(relative_schema_path_from_config),
        )
        .context("Failed creating a relative path to schema")?;

        let schema_string = std::fs::read_to_string(&schema_path).context(format!(
            "EE200: Failed to read schema file at {}. Please ensure that the schema file is \
             placed correctly in the directory.",
            &schema_path.to_str().unwrap_or_else(|| "bad file path"),
        ))?;

        let schema_doc = graphql_parser::parse_schema::<String>(&schema_string)
            .context("EE201: Failed to parse schema as document")?;

        Self::from_document(schema_doc).context("Failed converting schema doc to schema struct")
    }

    fn validate(self) -> anyhow::Result<Self> {
        self.check_enum_type_defs()?
            .check_schema_for_reserved_words()?
            .check_duplicate_naming_between_enums_and_entities()?
            .check_related_type_defs_exist()?
            .validate_entity_field_types()
    }

    fn get_all_enum_type_names(&self) -> Vec<String> {
        self.enums.keys().cloned().collect()
    }
    fn get_all_enum_values(&self) -> Vec<String> {
        self.enums.values().flat_map(|v| v.values.clone()).collect()
    }
    fn get_all_entity_type_names(&self) -> Vec<String> {
        self.entities.keys().cloned().collect()
    }
    fn get_all_entity_field_names(&self) -> Vec<String> {
        self.entities
            .values()
            .flat_map(|v| v.fields.values())
            .map(|v| v.name.clone())
            .collect()
    }

    fn check_enum_type_defs(self) -> anyhow::Result<Self> {
        match check_enums_for_internal_reserved_words(self.get_all_enum_type_names()) {
            reserved_enum_types_used if reserved_enum_types_used.is_empty() => Ok(self),
            reserved_enum_types_used => Err(anyhow!(
                "EE212: Schema contains the following reserved enum names: {}",
                reserved_enum_types_used.join(", ")
            )),
        }
    }

    fn check_schema_for_reserved_words(self) -> anyhow::Result<Self> {
        let all_names = vec![
            self.get_all_enum_type_names(),
            self.get_all_enum_values(),
            self.get_all_entity_type_names(),
            self.get_all_entity_field_names(),
        ]
        .concat();

        match check_names_from_schema_for_reserved_words(all_names) {
            reserved_enum_types_used if reserved_enum_types_used.is_empty() => Ok(self),
            reserved_enum_types_used => Err(anyhow!(
                "EE210: Schema contains the following reserved keywords: {}",
                reserved_enum_types_used.join(", ")
            )),
        }
    }

    fn check_duplicate_naming_between_enums_and_entities(self) -> anyhow::Result<Self> {
        let duplicate_names = self
            .get_all_enum_type_names()
            .into_iter()
            .filter(|k| self.entities.get(k).is_some())
            .collect::<Vec<_>>();
        if !duplicate_names.is_empty() {
            Err(anyhow!(
                "EE214: Schema contains the following enums and entities with the same name, all \
                 type definitions must be unique in the schema: {}",
                duplicate_names.join(", ")
            ))
        } else {
            Ok(self)
        }
    }

    fn try_get_type_def(&self, name: &String) -> anyhow::Result<TypeDef> {
        match (self.entities.get(name), self.enums.get(name)) {
            (None, None) => Err(anyhow!("No type definition '{}' exists in schema", name)),
            (Some(_), Some(_)) => Err(anyhow!(
                "Both an enum and an entity type definition '{}' exist in schema",
                name
            )),
            (Some(entity), None) => Ok(TypeDef::Entity(entity)),
            (None, Some(_)) => Ok(TypeDef::Enum),
        }
    }

    fn check_related_type_defs_exist(self) -> anyhow::Result<Self> {
        for entity in self.entities.values() {
            for rel in entity.get_relationships() {
                match &rel {
                    Relationship::TypeDef { name } => {
                        let _ = self.try_get_type_def(name)?;
                    }
                    Relationship::DerivedFrom {
                        name,
                        derived_from_field,
                    } => {
                        let type_def = self.try_get_type_def(name)?;

                        match type_def {
                            TypeDef::Enum => Err(anyhow!(
                                "Cannot derive field {derived_from_field} from enum {name}. \
                                 derivedFrom is intended to be used with Entity type definitions"
                            ))?,
                            TypeDef::Entity(derived_entity) => {
                                match derived_entity.fields.get(derived_from_field) {
                                    None => Err(anyhow!(
                                        "Derived field {derived_from_field} does not exist on \
                                         entity {name}."
                                    ))?,
                                    Some(field) => match field.field_type.get_underlying_scalar() {
                                        GqlScalar::Custom(name) if name == entity.name => (),
                                        GqlScalar::ID | GqlScalar::String => (),
                                        _ => Err(anyhow!(
                                            "Derived field '{derived_from_field}' on entity \
                                             '{name}' must either be an ID, String, or an Object \
                                             relationship with Entity '{}'",
                                            entity.name
                                        ))?,
                                    },
                                }
                            }
                        }
                    }
                }
            }
        }

        Ok(self)
    }

    /// For all entities validate the defined field types.
    ///
    /// This function will return an error if there is a defined related type where the type does
    /// not exist on the schema.
    fn validate_entity_field_types(self) -> anyhow::Result<Self> {
        for e in self.entities.values() {
            e.validate_field_types(&self)?;
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct GraphQLEnum {
    pub name: String,
    pub values: Vec<String>,
}

impl GraphQLEnum {
    pub fn new(name: String, values: Vec<String>) -> anyhow::Result<Self> {
        Self { name, values }.valididate()
    }

    fn valididate(self) -> anyhow::Result<Self> {
        self.check_duplicate_values()?.check_valid_postgres_name()
    }

    fn check_duplicate_values(self) -> anyhow::Result<Self> {
        let mut value_set: HashSet<String> = self.values.clone().into_iter().collect();

        let duplicate_values = self
            .values
            .clone()
            .into_iter()
            .filter(|value| value_set.insert(value.clone()))
            .collect::<Vec<_>>();

        if !duplicate_values.is_empty() {
            Err(anyhow!(
                "EE213: Schema enum has duplicate values. Enum: {}, duplicate values: {}",
                self.name,
                duplicate_values.join(", ")
            ))
        } else {
            Ok(self)
        }
    }

    fn check_valid_postgres_name(self) -> anyhow::Result<Self> {
        let values_to_check = vec![vec![self.name.clone()], self.values.clone()].concat();
        let invalid_names = values_to_check
            .into_iter()
            .filter(|v| !is_valid_postgres_db_name(v))
            .collect::<Vec<_>>();

        if !invalid_names.is_empty() {
            Err(anyhow!(
                "EE214: Schema contains the enum names and/or values that does not match the \
                 following pattern: It must start with a letter. It can only contain letters, \
                 numbers, and underscores (no spaces). It must have a maximum length of 63 \
                 characters. Invalid names: '{}'",
                invalid_names.join(", ")
            ))
        } else {
            Ok(self)
        }
    }
    fn from_enum(enm: &EnumType<String>) -> anyhow::Result<Self> {
        let name = enm.name.clone();
        let values = enm
            .values
            .iter()
            .map(|value| value.name.clone())
            .collect::<Vec<String>>();
        Self::new(name, values)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entity {
    pub name: String,
    pub fields: HashMap<String, Field>,
    pub multi_field_indexes: Vec<MultiFieldIndex>,
}

#[derive(thiserror::Error, Debug)]
enum EntityParseError {
    #[error("Failed parsing field '{field_name}': {err}")]
    FieldParseError {
        err: FieldParseError,
        field_name: String,
    },
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

impl Entity {
    fn new(
        name: &str,
        fields: Vec<Field>,
        multi_field_indexes: Vec<MultiFieldIndex>,
    ) -> anyhow::Result<Self> {
        let fields = unique_hashmap::from_vec_no_duplicates(
            fields.into_iter().map(|f| (f.name.clone(), f)).collect(),
        )
        .context(format!(
            "Found fields with duplicate names on Entity {name}"
        ))?;

        let multi_field_indexes = multi_field_indexes
            .into_iter()
            .map(|multi_field_index| {
                multi_field_index
                    .validate_no_duplicates(&fields)?
                    .validate_field_name_exists_or_is_allowed(
                        &fields,
                        &vec!["db_write_timestamp".to_string()],
                    )?
                    .validate_no_index_on_derived_field(&fields)?
                    .validate_no_index_on_id_field()
            })
            .collect::<anyhow::Result<Vec<_>>>()
            .context(format!("Invalid multi field indexes on Entity {name}"))?;

        //Check for duplicate fields inside multi field index
        let mut multi_field_indexes_set = HashSet::new();
        for multi_field_index in &multi_field_indexes {
            let is_new_insert = multi_field_indexes_set.insert(multi_field_index);
            if !is_new_insert {
                return Err(anyhow!(
                    "Index error: Duplicate index found on fields {:?} in entity '{}'",
                    multi_field_index.get_field_names(),
                    name
                ));
            }
        }

        Ok(Self {
            name: name.to_string(),
            fields,
            multi_field_indexes,
        })
    }

    fn from_object(obj: &ObjectType<String>) -> Result<Self, EntityParseError> {
        let name = &obj.name;

        let has_id = obj.fields.iter().any(|field| field.name == "id");
        if !has_id {
            return Err(anyhow!(
                "No 'id' field found on entity {}. Please add an 'id' field to your entity.",
                name
            ))?;
        }

        let multi_field_indexes = obj
            .directives
            .iter()
            .filter(|directive| directive.name == "index")
            .map(
                |directive| match directive.arguments.iter().find(|(key, _)| key == "fields") {
                    Some((_, Value::List(fields))) => {
                        let index_fields = fields
                            .iter()
                            .map(|v| {
                                if let Value::String(field_name) = v {
                                    Ok(field_name.clone())
                                } else {
                                    Err(anyhow!("Listed index field should be a string"))
                                }
                            })
                            .collect::<anyhow::Result<Vec<String>>>()
                            .context("Failed to get fields in index")?;

                        Ok(MultiFieldIndex::new(index_fields))
                    }
                    _ => Err(anyhow!(
                        "Invalid @index directive. Please ensure index has a key of fields with a \
                         list of strings matching field names in your entity. Eg. @index(fields: \
                         [\"fieldA\", \"fieldB\"])"
                    )),
                },
            )
            .collect::<anyhow::Result<Vec<_>>>()
            .context(format!(
                "Failed parsing multi field indexes on entity {name}"
            ))?;

        // Map each field in the ObjectType to a Field, passing the indexed status
        let fields = obj
            .fields
            .iter()
            .map(
                |obj_field| {
                    Field::from_obj_field(obj_field).map_err(|err| {
                        EntityParseError::FieldParseError {
                            err,
                            field_name: obj_field.name.clone(),
                        }
                    })
                }, // Pass the indexed status to the field constructor
            )
            .collect::<Result<Vec<Field>, _>>()?;

        let entity = Self::new(name, fields, multi_field_indexes)
            .context(format!("Failed constructing entity {name}",))?;

        // Here, store indexed information somewhere within your entity structure or handle them accordingly
        Ok(entity)
    }

    /// Returns the fields of this [`Entity`] sorted by field name.
    pub fn get_fields<'a>(&'a self) -> Vec<&'a Field> {
        self.fields.values().sorted_by_key(|v| &v.name).collect()
    }

    pub fn get_relationships(&self) -> Vec<Relationship> {
        let derived_from_fields: Vec<Relationship> = self
            .get_fields()
            .into_iter()
            .filter_map(|f| match &f.field_type {
                FieldType::DerivedFromField {
                    entity_name,
                    derived_from_field,
                } => Some(Relationship::DerivedFrom {
                    name: entity_name.clone(),
                    derived_from_field: derived_from_field.clone(),
                }),
                _ => None,
            })
            .collect();
        let object_relationship_fields: Vec<Relationship> = self
            .get_fields()
            .into_iter()
            .filter_map(|f| f.get_relationship())
            .collect();

        vec![derived_from_fields, object_relationship_fields].concat()
    }

    pub fn get_related_entities<'a>(
        &'a self,
        schema: &'a Schema,
    ) -> anyhow::Result<Vec<(&'a Field, &'a Self)>> {
        let related_entities_with_field = self
            .get_fields()
            .into_iter()
            .filter_map(|field| {
                let gql_scalar = field.field_type.get_underlying_scalar();
                if let GqlScalar::Custom(name) = gql_scalar {
                    schema.try_get_type_def(&name).map_or_else(
                        |e| Some(Err(e)),
                        |type_def| match type_def {
                            TypeDef::Entity(entity) => Some(Ok((field, entity))),
                            TypeDef::Enum => None,
                        },
                    )
                } else {
                    None
                }
            })
            .collect::<anyhow::Result<_>>()?;

        Ok(related_entities_with_field)
    }

    /// Validate each field type in an the given entity
    ///
    /// This function will return an error if there is a defined related type where the type does
    /// not exist on the schema.
    fn validate_field_types(&self, schema: &Schema) -> anyhow::Result<()> {
        for field in self.get_fields() {
            field.validate_field_type(schema)?;
        }
        Ok(())
    }

    ///Returns defined multi field indices where definitions
    ///have > 1 fields.
    pub fn get_composite_indices(&self) -> Vec<Vec<String>> {
        self.multi_field_indexes
            .iter()
            .cloned()
            .filter_map(|multi_field_index| {
                if multi_field_index.0.len() > 1 {
                    Some(multi_field_index.0)
                } else {
                    None
                }
            })
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Field {
    pub name: String,
    pub field_type: FieldType,
}

#[derive(thiserror::Error, Debug)]
pub enum DirectiveParseError {
    #[error("A field cannot have more than one {0} directive")]
    Duplicate(String),
    #[error("Derictives {} cannot be used together", .directive_names.join(", "))]
    NonCompatibleDirectives { directive_names: Vec<String> },
    #[error("An id field cannot have an @index or @derivedFrom directive")]
    IndexOnId,

    #[error(
        "Directive {directive_name} is not compatible with field {field_name} of type {field_type}"
    )]
    NonCompatibleWithField {
        directive_name: String,
        field_name: String,
        field_type: String,
    },

    #[error("Directive {directive_name} is missing argument of '{argument_name}'")]
    MissingArgument {
        directive_name: String,
        argument_name: String,
    },
    #[error("Directive {directive_name} has expected a type of '{expected_type}' for argument '{argument_name}'")]
    InvalidArgumentType {
        directive_name: String,
        argument_name: String,
        expected_type: String,
    },
    #[error("Directive {directive_name} has an invalid argument '{argument_name}'")]
    InvalidArgument {
        directive_name: String,
        argument_name: String,
    },
    #[error("Directive {directive_name} has too many arguments. Expected {} args of {}, got {args_count}", .expected_args.len(), .expected_args.join(", "))]
    TooManyArguments {
        directive_name: String,
        expected_args: Vec<String>,
        args_count: usize,
    },
    #[error(
        "Directive {directive_name} expects a positive integer for argument '{argument_name}'"
    )]
    ExpectedPositiveIntArg {
        directive_name: String,
        argument_name: String,
    },
}

#[derive(thiserror::Error, Debug)]
pub enum FieldParseError {
    #[error("Invalid Directive: {err}. {}", .additional_info.clone().unwrap_or("".to_string()))]
    InvalidDirective {
        err: DirectiveParseError,
        additional_info: Option<String>,
    },
    #[error(transparent)]
    ParseFailure(#[from] anyhow::Error),
}

impl FieldParseError {
    fn invalid_directive(error: DirectiveParseError) -> Self {
        Self::InvalidDirective {
            err: error,
            additional_info: None,
        }
    }

    fn invalid_directive_with_info(error: DirectiveParseError, additional_info: &str) -> Self {
        Self::InvalidDirective {
            err: error,
            additional_info: Some(additional_info.to_string()),
        }
    }
}

impl Field {
    fn from_obj_field(field: &ObjField<String>) -> Result<Self, FieldParseError> {
        ///  used to get the positive integers in the directives from the GraphQL schema.
        fn get_positive_integer(
            arg_value: &Value<String>,
            directive_name: &str,
            argument_name: &str,
        ) -> Result<u32, FieldParseError> {
            let mk_err = || {
                FieldParseError::invalid_directive(DirectiveParseError::ExpectedPositiveIntArg {
                    directive_name: directive_name.to_string(),
                    argument_name: argument_name.to_string(),
                })
            };
            match arg_value {
                Value::Int(i) => {
                    let val = i.as_i64().ok_or(mk_err())?;
                    if val < 0 {
                        return Err(mk_err());
                    }
                    Ok(val as u32)
                }
                _ => Err(mk_err()),
            }
        }
        // Get all gql directives labeled @derivedFrom and @index
        let derived_from_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "derivedFrom")
            .collect::<Vec<&Directive<'_, String>>>();

        let indexed_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "index")
            .collect::<Vec<&Directive<'_, String>>>();

        // Validate directive usage

        // Do not allow for multiple @derivedFrom directives
        // If this step is not important and we are fine with just taking the first one
        // in the case of multiple we can just use a find rather than a filter method above

        let derived_from_count = derived_from_directives.len();
        let indexed_count = indexed_directives.len();

        if derived_from_count > 1 {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::Duplicate("@derivedFrom".to_string()),
            ));
        }

        if indexed_count > 1 {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::Duplicate("@index".to_string()),
            ));
        }

        if derived_from_count > 0 && indexed_count > 0 {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::NonCompatibleDirectives {
                    directive_names: vec!["@derivedFrom".to_string(), "@index".to_string()],
                },
            ));
        }

        if (field.name == "id" || field.name == "ID")
            && (indexed_count > 0 || derived_from_count > 0)
        {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::IndexOnId,
            ));
        }

        let maybe_derived_from_directive = derived_from_directives.get(0);
        let derived_from_field = match maybe_derived_from_directive {
            None => None,
            Some(d) => {
                let field_arg = d.arguments.iter().find(|a| a.0 == "field").ok_or_else(|| {
                    FieldParseError::invalid_directive(DirectiveParseError::MissingArgument {
                        directive_name: "@derivedFrom".to_string(),
                        argument_name: "field".to_string(),
                    })
                })?;
                match &field_arg.1 {
                    Value::String(val) => Some(val.clone()),
                    _ => Err(FieldParseError::invalid_directive(
                        DirectiveParseError::InvalidArgumentType {
                            directive_name: "@derivedFrom".to_string(),
                            argument_name: "field".to_string(),
                            expected_type: "string".to_string(),
                        },
                    ))?,
                }
            }
        };

        // TODO: should we dis-allow indexed fields that are either `id` or derived From fields?
        let is_indexed = indexed_count > 0;

        // Collect directives
        let decimal_precision_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "precision")
            .collect::<Vec<&Directive<'_, String>>>();
        let numeric_directives = field
            .directives
            .iter()
            .filter(|&directive| directive.name == "numeric")
            .collect::<Vec<&Directive<'_, String>>>();

        // Validate directive usage
        if decimal_precision_directives.len() > 1 {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::Duplicate("@precision".to_string()),
            ));
        }

        if numeric_directives.len() > 1 {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::Duplicate("@numeric".to_string()),
            ));
        }

        if decimal_precision_directives.len() > 0 && numeric_directives.len() > 0 {
            return Err(FieldParseError::invalid_directive(
                DirectiveParseError::NonCompatibleDirectives {
                    directive_names: vec!["@precision".to_string(), "@numeric".to_string()],
                },
            ));
        }

        // Parse the field type into UserDefinedFieldType
        let field_type = UserDefinedFieldType::from_obj_field_type(
            &field.field_type,
            &PgTypeModifications::default(),
        );

        let underlying_scalar = field_type.get_underlying_scalar();

        let mut pg_type_modifications = PgTypeModifications::default();

        // Process @precision
        if let Some(decimal_precision_directive) = decimal_precision_directives.first() {
            if !matches!(underlying_scalar, GqlScalar::BigInt(_)) {
                return Err(FieldParseError::invalid_directive_with_info(
                    DirectiveParseError::NonCompatibleWithField {
                        directive_name: "@precision".to_string(),
                        field_name: field.name.clone(),
                        field_type: underlying_scalar.to_string(),
                    },
                    "The precision directive on a field is only suitable for BigInt scalar type.",
                ));
            }
            if decimal_precision_directive.arguments.len() != 1 {
                return Err(FieldParseError::invalid_directive(
                    DirectiveParseError::TooManyArguments {
                        directive_name: "@precision".to_string(),
                        expected_args: vec!["digits".to_string()],
                        args_count: decimal_precision_directive.arguments.len(),
                    },
                ));
            }
            let (arg_name, arg_value) = decimal_precision_directive.arguments.first().unwrap();
            if arg_name != "digits" {
                return Err(FieldParseError::invalid_directive_with_info(
                    DirectiveParseError::InvalidArgument {
                        directive_name: "@precision".to_string(),
                        argument_name: arg_name.clone(),
                    },
                    "Expected only 'digits' argument",
                ));
            }
            let precision = get_positive_integer(arg_value, "@precision", "digits")?;
            pg_type_modifications.big_int_precision = Some(precision);
        }

        // Process @numeric
        if let Some(numeric_directive) = numeric_directives.first() {
            if !matches!(underlying_scalar, GqlScalar::BigDecimal(_)) {
                return Err(FieldParseError::invalid_directive_with_info(
                    DirectiveParseError::NonCompatibleWithField {
                        directive_name: "@numeric".to_string(),
                        field_name: field.name.clone(),
                        field_type: underlying_scalar.to_string(),
                    },
                    "The numeric directive on a field is only suitable for BigDecimal scalar type.",
                ));
            }
            let mut precision: Option<u32> = None;
            let mut scale: Option<u32> = None;

            for (arg_name, arg_value) in &numeric_directive.arguments {
                match arg_name.as_str() {
                    "precision" => {
                        precision = Some(get_positive_integer(arg_value, "@numeric", "precision")?);
                    }
                    "scale" => {
                        scale = Some(get_positive_integer(arg_value, "@numeric", "scale")?);
                    }
                    unknown_param => {
                        return Err(FieldParseError::invalid_directive_with_info(
                            DirectiveParseError::InvalidArgument {
                                directive_name: "@numeric".to_string(),
                                argument_name: unknown_param.to_string(),
                            },
                            "Expected only 'precision' and 'scale' arguments",
                        ));
                    }
                }
            }
            if precision.is_none() {
                return Err(FieldParseError::invalid_directive(
                    DirectiveParseError::MissingArgument {
                        directive_name: "@numeric".to_string(),
                        argument_name: "precision".to_string(),
                    },
                ));
            }
            if scale.is_none() {
                return Err(FieldParseError::invalid_directive(
                    DirectiveParseError::MissingArgument {
                        directive_name: "@numeric".to_string(),
                        argument_name: "scale".to_string(),
                    },
                ));
            }
            pg_type_modifications.big_decimal_precision_scale =
                Some((precision.unwrap(), scale.unwrap()));
        }

        let params = FieldTypeParams {
            derived_from_field,
            has_indexed_directive: is_indexed,
            pg_type_modifications,
        };

        let field_type = FieldType::from_obj_field_type(&field.field_type, params)
            .context(format!("Failed parsing field {}", field.name))?;

        Ok(Field {
            name: field.name.clone(),
            field_type,
        })
    }

    fn get_relationship(&self) -> Option<Relationship> {
        match self.field_type.get_underlying_scalar() {
            GqlScalar::Custom(name) => Some(Relationship::TypeDef { name: name.clone() }),
            _ => None,
        }
    }

    fn validate_field_type(&self, schema: &Schema) -> anyhow::Result<()> {
        self.field_type.validate_type(schema)
    }

    pub fn get_relational_key(&self, schema: &Schema) -> anyhow::Result<String> {
        match &self.field_type {
            FieldType::DerivedFromField {
                derived_from_field,
                entity_name,
            } => {
                let entity_field = schema
                    .entities
                    .get(entity_name)
                    .ok_or_else(|| anyhow!("Unexpected, entity {entity_name} does not exist"))?
                    .fields
                    .get(derived_from_field)
                    .ok_or_else(|| {
                        anyhow!(
                            "Unexpected, field {derived_from_field} does not exist on entity \
                             {entity_name}"
                        )
                    })?;

                match entity_field.field_type.get_underlying_scalar() {
                    //In the case where there is a recipracol lookup, the actual
                    //underlying field contains _id at the end
                    GqlScalar::Custom(name)
                        if matches!(schema.try_get_type_def(&name)?, TypeDef::Entity(_)) =>
                    {
                        Ok(format!("{derived_from_field}_id"))
                    }
                    //In the case where its just an an ID or a string,
                    //just keep the the field as is from what was
                    //defined in @derivedFrom
                    GqlScalar::ID | GqlScalar::String => Ok(derived_from_field.clone()),
                    _ => Err(anyhow!(
                        "Unexpected, derived from field is neither an ID, String or bidirectional \
                         relationship"
                    ))?,
                }
            }

            FieldType::RegularField { .. } => Ok(self.name.clone()),
        }
    }

    pub fn is_indexed_field(&self, entity: &Entity) -> bool {
        let has_indexed_directive = self.field_type.has_indexed_directive();
        let has_single_field_index_directive = entity
            .multi_field_indexes
            .iter()
            .filter_map(MultiFieldIndex::get_single_field_index)
            .any(|single_field_index| single_field_index == self.name);

        has_indexed_directive || has_single_field_index_directive
    }

    pub fn is_derived_lookup_field(&self, entity: &Entity, schema: &Schema) -> bool {
        schema.entities.values().fold(false, |accum, entity_inner| {
            accum
                || entity_inner
                    .get_fields()
                    .iter()
                    .fold(false, |accum, field| {
                        accum
                            || matches!(
                                &field.field_type,
                                FieldType::DerivedFromField {
                                    entity_name,
                                    derived_from_field
                                } if entity_name == &entity.name && derived_from_field == &self.name
                            )
                    })
        })
    }

    pub fn is_primary_key(&self) -> bool {
        self.name.as_str().to_lowercase() == "id"
    }

    ///Returns None if it is a derived field
    pub fn get_postgres_field(
        &self,
        schema: &Schema,
        entity: &Entity,
    ) -> anyhow::Result<Option<PGField>> {
        match &self.field_type {
            FieldType::DerivedFromField { .. } => Ok(None),
            FieldType::RegularField {
                field_type: gql_field_type,
                ..
            } => Ok(Some(PGField {
                field_name: self.name.clone(),
                field_type: gql_field_type.to_underlying_postgres_primitive(schema)?,
                is_array: gql_field_type.is_array(),
                is_index: self.is_indexed_field(entity),
                linked_entity: gql_field_type.get_linked_entity(schema)?,
                is_primary_key: self.is_primary_key(),
                is_nullable: gql_field_type.is_optional(),
            })),
        }
    }

    pub fn get_derived_from_field(&self) -> Option<DerivedFieldTemplate> {
        match &self.field_type {
            FieldType::DerivedFromField {
                entity_name,
                derived_from_field,
            } => Some(DerivedFieldTemplate {
                field_name: self.name.clone(),
                derived_from_field: derived_from_field.clone(),
                derived_from_entity: entity_name.clone(),
            }),
            FieldType::RegularField { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct MultiFieldIndex(Vec<String>);

impl MultiFieldIndex {
    fn new(field_names: Vec<String>) -> Self {
        Self(field_names.into_iter().sorted().collect())
    }

    pub fn get_field_names(&self) -> &Vec<String> {
        &self.0
    }

    fn get_single_field_index(&self) -> Option<String> {
        if self.0.len() == 1 {
            self.0.get(0).cloned()
        } else {
            None
        }
    }

    pub fn get_multi_field_index(&self) -> Option<&Self> {
        if self.0.len() > 1 {
            Some(&self)
        } else {
            None
        }
    }

    fn validate_field_name_exists_or_is_allowed(
        self,
        fields: &HashMap<String, Field>,
        allowed_names: &Vec<String>,
    ) -> anyhow::Result<Self> {
        for field_name in &self.0 {
            if !fields.contains_key(field_name) && !allowed_names.contains(field_name) {
                return Err(anyhow!(
                    "Index error: Field '{}' does not exist in entity, please remove it from the \
                     `@index` directive.",
                    field_name,
                ));
            }
        }
        Ok(self)
    }

    fn validate_no_duplicates(self, fields: &HashMap<String, Field>) -> anyhow::Result<Self> {
        let mut field_names_set = HashSet::new();
        for field_name in &self.0 {
            //Check for duplicate fields inside multi field index
            let is_new_insert = field_names_set.insert(field_name);
            if !is_new_insert {
                return Err(anyhow!(
                    "Field {field_name} is listed multiple times in index"
                ));
            }
        }

        //Check for @index directives on the defined field
        if let Some(single_field_index) = self.get_single_field_index() {
            if let Some(field) = fields.get(&single_field_index) {
                if field.field_type.has_indexed_directive() {
                    return Err(anyhow!(
                        "EE202: The field '{}' is marked as an index. Please either remove the \
                         @index directive on the field, or the @index(fields: [\"{}\"]) directive \
                         on the entity",
                        field.name,
                        field.name
                    ));
                }
            }
        }
        Ok(self)
    }

    fn validate_no_index_on_derived_field(
        self,
        fields: &HashMap<String, Field>,
    ) -> anyhow::Result<Self> {
        for field_name in &self.0 {
            if let Some(field) = fields.get(field_name) {
                if field.field_type.is_derived_from() {
                    return Err(anyhow!(
                        "Index error: Field '{}' is a @derivedFrom field and cannot be indexed, \
                         please remove it from the `@index` directive.",
                        field_name
                    ));
                }
            }
        }
        Ok(self)
    }

    fn validate_no_index_on_id_field(self) -> anyhow::Result<Self> {
        if let Some(single_field_index) = self.get_single_field_index() {
            if single_field_index == "id" {
                return Err(anyhow!(
                    "Index error: Field 'id' is indexed by default in all entities, please remove \
                     the `@index` directive on it.",
                ));
            }
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum UserDefinedFieldType {
    Single(GqlScalar),
    ListType(Box<UserDefinedFieldType>),
    NonNullType(Box<UserDefinedFieldType>),
}

impl UserDefinedFieldType {
    fn from_obj_field_type(
        obj_field_type: &ObjType<'_, String>,
        pg_type_modifications: &PgTypeModifications,
    ) -> Self {
        match obj_field_type {
            ObjType::NamedType(name) => {
                UserDefinedFieldType::Single(GqlScalar::from_str(name, pg_type_modifications))
            }
            ObjType::NonNullType(obj_field_type) => UserDefinedFieldType::NonNullType(Box::new(
                Self::from_obj_field_type(obj_field_type, pg_type_modifications),
            )),
            ObjType::ListType(obj_field_type) => UserDefinedFieldType::ListType(Box::new(
                Self::from_obj_field_type(obj_field_type, pg_type_modifications),
            )),
        }
    }

    pub fn validate_type(&self, schema: &Schema) -> anyhow::Result<()> {
        match self {
            Self::Single(_) => Ok(()),
            Self::ListType(field_type) => match field_type.as_ref() {
                //Postgres doesn't support nullable types inside of arrays
                Self::NonNullType(inner_field_type) => match inner_field_type.as_ref() {
                    //Don't allow non derived from enity relationships inside arrays
                    Self::Single(GqlScalar::Custom(name))
                        if matches!(schema.try_get_type_def(name)?, TypeDef::Entity(_)) =>
                    {
                        Err(anyhow!(
                            "EE211: Arrays of entities is unsupported. Please use one of the \
                             methods for referencing entities outlined in the docs. The entity \
                             being referenced in the array is '{}'.",
                            name
                        ))?
                    }
                    _ => field_type.validate_type(schema),
                },
                Self::Single(gql_scalar) => Err(anyhow!(
                    "EE208: Nullable scalars inside lists are unsupported. Please include a '!' \
                     after your '{}' scalar",
                    gql_scalar
                ))?,
                Self::ListType(_) => Err(anyhow!(
                    "EE209: Nullable multidimensional lists types are unsupported,please include \
                     a '!' for your inner list type eg. [[Int!]!]"
                ))?,
            },
            Self::NonNullType(field_type) => match field_type.as_ref() {
                Self::NonNullType(_) => Err(anyhow!(
                    "Nested Not Null types are unsupported. Please remove any sequential '!' \
                     symbols after types in schema"
                )),
                _ => field_type.validate_type(schema),
            },
        }
    }

    pub fn to_underlying_postgres_primitive(&self, schema: &Schema) -> anyhow::Result<PGPrimitive> {
        match self {
            Self::Single(gql_scalar) => gql_scalar.to_underlying_postgres_primitive(schema),
            Self::ListType(field_type) | Self::NonNullType(field_type) => {
                field_type.to_underlying_postgres_primitive(schema)
            }
        }
    }

    pub fn is_optional(&self) -> bool {
        !matches!(self, Self::NonNullType(_))
    }

    pub fn is_array(&self) -> bool {
        match self {
            Self::ListType(_) => true,
            Self::NonNullType(field_type) => field_type.is_array(),
            Self::Single(_) => false,
        }
    }

    pub fn to_rescript_type(&self, schema: &Schema) -> anyhow::Result<RescriptTypeIdent> {
        let composed_type_name = match self {
            //Only types in here should be non optional
            Self::NonNullType(field_type) => match field_type.as_ref() {
                Self::Single(gql_scalar) => gql_scalar.to_rescript_type(schema)?,
                Self::ListType(field_type) => {
                    RescriptTypeIdent::Array(Box::new(field_type.to_rescript_type(schema)?))
                }
                //This case shouldn't happen, and should recurse without adding any types if so
                //A double non null would be !! in gql
                Self::NonNullType(field_type) => field_type.to_rescript_type(schema)?,
            },
            //If we match this case it missed the non null path entirely and should be optional
            Self::Single(gql_scalar) => {
                RescriptTypeIdent::Option(Box::new(gql_scalar.to_rescript_type(schema)?))
            }
            //If we match this case it missed the non null path entirely and should be optional
            Self::ListType(field_type) => RescriptTypeIdent::Option(Box::new(
                RescriptTypeIdent::Array(Box::new(field_type.to_rescript_type(schema)?)),
            )),
        };
        Ok(composed_type_name)
    }

    fn get_underlying_scalar(&self) -> GqlScalar {
        match self {
            Self::Single(gql_scalar) => gql_scalar.clone(),
            Self::ListType(field_type) | Self::NonNullType(field_type) => {
                field_type.get_underlying_scalar()
            }
        }
    }

    pub fn is_entity_field(&self, schema: &Schema) -> anyhow::Result<bool> {
        self.get_underlying_scalar().is_entity(schema)
    }

    ///Returns None if field is not a linked entity and   Some(<ENTITY_NAME>) if it is
    pub fn get_linked_entity(&self, schema: &Schema) -> anyhow::Result<Option<String>> {
        self.get_underlying_scalar().get_linked_entity(schema)
    }

    fn to_string(&self) -> String {
        match &self {
            Self::Single(gql_scalar) => gql_scalar.to_string(),
            Self::ListType(field_type) => format!("[{}]", field_type.to_string()),
            Self::NonNullType(field_type) => format!("{}!", field_type.to_string()),
        }
    }

    /// Returns the name of the entity when @derivedFrom derivtive is used
    /// Returns None in the case that it does not conform to the correct
    /// structure of a derived entity
    fn get_name_of_derived_from_entity(&self) -> Option<String> {
        match self {
            Self::NonNullType(f) => match f.as_ref() {
                Self::ListType(f) => match f.as_ref() {
                    Self::NonNullType(f) => match f.as_ref() {
                        Self::Single(GqlScalar::Custom(name)) => Some(name.clone()),
                        _ => None,
                    },
                    _ => None,
                },
                _ => None,
            },
            _ => None,
        }
    }

    pub fn from_ethabi_type(abi_type: &EthAbiParamType) -> anyhow::Result<Self> {
        match abi_type {
            EthAbiParamType::Uint(_size) | EthAbiParamType::Int(_size) => Ok(Self::NonNullType(
                Box::new(Self::Single(GqlScalar::BigInt(None))),
            )),
            EthAbiParamType::Bool => Ok(Self::NonNullType(Box::new(Self::Single(
                GqlScalar::Boolean,
            )))),
            EthAbiParamType::Address
            | EthAbiParamType::Bytes
            | EthAbiParamType::String
            | EthAbiParamType::FixedBytes(_) => {
                Ok(Self::NonNullType(Box::new(Self::Single(GqlScalar::String))))
            }
            EthAbiParamType::Array(abi_type) | EthAbiParamType::FixedArray(abi_type, _) => {
                //Validate no nested arrays or
                match abi_type.as_ref() {
                    EthAbiParamType::Tuple(_) => {
                        Err(anyhow!("Unhandled contract import type 'array of tuple'"))?
                    }
                    EthAbiParamType::Array(_) => {
                        Err(anyhow!("Unhandled contract import type 'array of array'"))?
                    }
                    _ => (),
                }
                let inner_type = Self::from_ethabi_type(abi_type)
                    .context("Unhandled contract import nested type in array")?;
                Ok(Self::NonNullType(Box::new(Self::ListType(Box::new(
                    inner_type,
                )))))
            }
            EthAbiParamType::Tuple(_abi_types) =>
            //This case should be flattened out unless it is nested inside an array
            {
                Err(anyhow!("Unhandled contract import type 'tuple'"))
            }
        }
    }
}

// Implement the Display trait for the custom struct
impl fmt::Display for UserDefinedFieldType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string())
    }
}

impl Serialize for UserDefinedFieldType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_str())
    }
}

#[derive(Default)]
pub struct PgTypeModifications {
    pub big_int_precision: Option<u32>,
    pub big_decimal_precision_scale: Option<(u32, u32)>,
}

pub struct FieldTypeParams {
    pub derived_from_field: Option<String>,
    pub has_indexed_directive: bool,
    pub pg_type_modifications: PgTypeModifications,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FieldType {
    DerivedFromField {
        entity_name: String,
        derived_from_field: String,
    },
    RegularField {
        field_type: UserDefinedFieldType,
        has_indexed_directive: bool,
    },
}

impl FieldType {
    fn to_user_defined_field_type(&self) -> UserDefinedFieldType {
        match self {
            Self::RegularField { field_type: t, .. } => t.clone(),
            Self::DerivedFromField { entity_name, .. } => {
                use UserDefinedFieldType::*;
                NonNullType(Box::new(ListType(Box::new(NonNullType(Box::new(Single(
                    GqlScalar::Custom(entity_name.clone()),
                )))))))
            }
        }
    }

    fn from_obj_field_type(
        obj_field_type: &ObjType<'_, String>,
        params: FieldTypeParams,
    ) -> anyhow::Result<Self> {
        let field_type = UserDefinedFieldType::from_obj_field_type(
            obj_field_type,
            &params.pg_type_modifications,
        );

        match params.derived_from_field {
            None => Ok(Self::RegularField {
                field_type,
                has_indexed_directive: params.has_indexed_directive,
            }),
            Some(derived_from_field) => match field_type.get_name_of_derived_from_entity() {
                None => {
                    let example_str = Self::DerivedFromField {
                        entity_name: "<MY_ENTITY>".to_string(),
                        derived_from_field,
                    }
                    .to_string();

                    Err(anyhow!(
                        "Field marked with @derivedFrom directive does not meet the required \
                         structure. Field should contain a non nullable list of non nullable \
                         entities for example: {example_str}"
                    ))
                }
                Some(entity_name) => Ok(Self::DerivedFromField {
                    entity_name,
                    derived_from_field,
                }),
            },
        }
    }

    pub fn validate_type(&self, schema: &Schema) -> anyhow::Result<()> {
        match self {
            Self::DerivedFromField { .. } => Ok(()), //Already validated
            Self::RegularField { field_type: t, .. } => t.validate_type(schema),
        }
    }

    pub fn is_optional(&self) -> bool {
        self.to_user_defined_field_type().is_optional()
    }

    pub fn is_derived_from(&self) -> bool {
        matches!(self, Self::DerivedFromField { .. })
    }

    fn has_indexed_directive(&self) -> bool {
        match self {
            Self::DerivedFromField { .. } => false,
            Self::RegularField {
                has_indexed_directive,
                ..
            } => *has_indexed_directive,
        }
    }

    pub fn is_array(&self) -> bool {
        match self {
            Self::DerivedFromField { .. } => true,
            Self::RegularField { field_type: t, .. } => t.is_array(),
        }
    }

    pub fn to_rescript_type(&self, schema: &Schema) -> anyhow::Result<RescriptTypeIdent> {
        self.to_user_defined_field_type().to_rescript_type(schema)
    }

    fn get_underlying_scalar(&self) -> GqlScalar {
        self.to_user_defined_field_type().get_underlying_scalar()
    }

    pub fn is_entity_field(&self, schema: &Schema) -> anyhow::Result<bool> {
        self.to_user_defined_field_type().is_entity_field(schema)
    }

    fn to_string(&self) -> String {
        match self {
            Self::DerivedFromField { entity_name, .. } => {
                let field_str = self.to_user_defined_field_type().to_string();
                format!("{field_str} @derivedFrom(field: \"{entity_name}\")")
            }
            Self::RegularField { field_type: t, .. } => t.to_string(),
        }
    }

    pub fn from_ethabi_type(abi_type: &EthAbiParamType) -> anyhow::Result<Self> {
        Ok(Self::RegularField {
            field_type: UserDefinedFieldType::from_ethabi_type(abi_type)?,
            has_indexed_directive: false,
        })
    }
}

// Implement the Display trait for the custom struct
impl fmt::Display for FieldType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.to_string())
    }
}

impl Serialize for FieldType {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.to_string().as_str())
    }
}

#[subenum(BuiltInGqlScalar, AdditionalGqlScalar)]
#[derive(Debug, Clone, PartialEq, strum_macros::Display, Eq, Hash)]
pub enum GqlScalar {
    #[subenum(BuiltInGqlScalar)]
    ID,
    #[subenum(BuiltInGqlScalar)]
    String,
    #[subenum(BuiltInGqlScalar)]
    Int,
    #[subenum(BuiltInGqlScalar)]
    Float,
    #[subenum(BuiltInGqlScalar)]
    Boolean,
    #[subenum(AdditionalGqlScalar)]
    BigInt(Option<u32>),
    #[subenum(AdditionalGqlScalar)]
    BigDecimal(Option<(u32, u32)>),
    #[subenum(AdditionalGqlScalar)]
    Timestamp,
    #[subenum(AdditionalGqlScalar)]
    Bytes,
    Custom(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BigIntPrecisionScale {
    pub precision: Option<u32>,
    pub scale: Option<u32>,
}

#[derive(Debug, Clone)]
pub enum Relationship {
    TypeDef {
        name: String,
    },
    DerivedFrom {
        name: String,
        derived_from_field: String,
    },
}

impl GqlScalar {
    fn is_entity(&self, schema: &Schema) -> anyhow::Result<bool> {
        match self {
            GqlScalar::Custom(name) => {
                Ok(matches!(schema.try_get_type_def(name)?, TypeDef::Entity(_)))
            }
            _ => Ok(false),
        }
    }

    fn from_str(name: &str, pg_type_modifications: &PgTypeModifications) -> Self {
        match name {
            "ID" => GqlScalar::ID,
            "String" => GqlScalar::String,
            "Int" => GqlScalar::Int,
            "Float" => GqlScalar::Float,
            "Boolean" => GqlScalar::Boolean,
            "BigInt" => GqlScalar::BigInt(pg_type_modifications.big_int_precision),
            "BigDecimal" => {
                GqlScalar::BigDecimal(pg_type_modifications.big_decimal_precision_scale)
            }
            "Timestamp" => GqlScalar::Timestamp,
            "Bytes" => GqlScalar::Bytes,
            _name => GqlScalar::Custom(name.to_string()),
        }
    }

    pub fn to_underlying_postgres_primitive(&self, schema: &Schema) -> anyhow::Result<PGPrimitive> {
        let converted = match self {
            GqlScalar::ID => PGPrimitive::Text,
            GqlScalar::String => PGPrimitive::Text,
            GqlScalar::Int => PGPrimitive::Integer,
            GqlScalar::Float => PGPrimitive::Numeric(None), // Should we allow this type? Rounding issues will abound.
            GqlScalar::Boolean => PGPrimitive::Boolean,
            GqlScalar::Bytes => PGPrimitive::Text,
            GqlScalar::BigInt(None) => PGPrimitive::Numeric(None),
            GqlScalar::BigInt(Some(precision)) => PGPrimitive::Numeric(Some((*precision, 0))), //  We leave the scale as zero since it is not relevant for integers.
            GqlScalar::BigDecimal(None) => PGPrimitive::Numeric(None),
            GqlScalar::BigDecimal(Some((precision, scale))) => {
                PGPrimitive::Numeric(Some((*precision, *scale)))
            }
            GqlScalar::Timestamp => PGPrimitive::Timestamp,
            GqlScalar::Custom(name) => match schema.try_get_type_def(name)? {
                TypeDef::Entity(_) => PGPrimitive::Text,
                TypeDef::Enum => PGPrimitive::Enum(name.clone()),
            },
        };
        Ok(converted)
    }

    fn to_rescript_type(&self, schema: &Schema) -> anyhow::Result<RescriptTypeIdent> {
        let res_type = match self {
            GqlScalar::ID => RescriptTypeIdent::ID,
            GqlScalar::String => RescriptTypeIdent::String,
            GqlScalar::Int => RescriptTypeIdent::Int,
            GqlScalar::BigInt(_) => RescriptTypeIdent::BigInt,
            GqlScalar::BigDecimal(_) => RescriptTypeIdent::BigDecimal,
            GqlScalar::Float => RescriptTypeIdent::Float,
            GqlScalar::Bytes => RescriptTypeIdent::String,
            GqlScalar::Boolean => RescriptTypeIdent::Bool,
            GqlScalar::Timestamp => RescriptTypeIdent::Timestamp,
            GqlScalar::Custom(name) => match schema.try_get_type_def(name)? {
                TypeDef::Entity(_) => RescriptTypeIdent::ID,
                TypeDef::Enum => RescriptTypeIdent::SchemaEnum(name.to_capitalized_options()),
            },
        };
        Ok(res_type)
    }

    fn get_linked_entity(&self, schema: &Schema) -> anyhow::Result<Option<String>> {
        let opt_entity_name = match self {
            Self::Custom(name) => match schema.try_get_type_def(name)? {
                TypeDef::Entity(entity) => Some(entity.name.clone()),
                TypeDef::Enum => None,
            },
            _ => None,
        };

        Ok(opt_entity_name)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        anyhow, DirectiveParseError, Entity, EntityParseError, Field, FieldParseError, FieldType,
        GqlScalar, GraphQLEnum, Schema, SchemaParseError, UserDefinedFieldType,
    };
    use crate::config_parsing::postgres_types::Primitive as PGPrimitive;
    use graphql_parser::schema::{parse_schema, Definition, Document, ObjectType, TypeDefinition};
    use pretty_assertions::assert_eq;

    fn setup_document(schema: &str) -> anyhow::Result<Document<String>> {
        parse_schema::<String>(schema)
            .map_err(|e| anyhow!("EE201: Failed to parse schema: {:?}", e))
    }

    fn get_entities_from_document(gql_doc: Document<String>) -> Vec<ObjectType<String>> {
        gql_doc
            .definitions
            .into_iter()
            .filter_map(|d| {
                if let Definition::TypeDefinition(TypeDefinition::Object(obj)) = d {
                    Some(obj)
                } else {
                    None
                }
            })
            .collect()
    }

    fn get_first_entity_from_string(schema_str: &str) -> ObjectType<String> {
        let gql_doc = setup_document(schema_str).unwrap();
        let entities = get_entities_from_document(gql_doc);
        entities.first().unwrap().clone()
    }

    #[test]
    fn test_field_does_not_exist_in_entity() {
        let schema_str = r#"
type TestEntity
  @index(fields: ["field_that_doesnt_exist", "id", "tokenId"]) {
  id: ID!
  tokenId: BigInt! @index
  collection: String!
  owner: String!
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let parsed_entity = Entity::from_object(&first_entity_schema);

        assert!(parsed_entity.is_err());
        let err_message = format!("{:?}", parsed_entity.unwrap_err());
        assert!(err_message.contains("Field 'field_that_doesnt_exist' does not exist"));
    }

    #[test]
    fn test_missing_id_field() {
        let schema_str = r#"
type TestEntity {
  testField: String
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let parsed_entity = Entity::from_object(&first_entity_schema);

        assert!(parsed_entity.is_err());
        let err_message = format!("{:?}", parsed_entity.unwrap_err());
        assert_eq!(
            err_message,
            "No 'id' field found on entity TestEntity. Please add an 'id' field to your entity."
        );
    }

    #[test]
    fn test_field_is_derived_from_and_indexed() {
        let schema_str = r#"
type TestEntity
  @index(fields: ["collection"]) {
  id: ID!
  tokenId: BigInt!
  collection: [Collection!]! @derivedFrom(field: "owner")
  owner: String!
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let parsed_entity = Entity::from_object(&first_entity_schema);

        assert!(parsed_entity.is_err());
        let err_message = format!("{:?}", parsed_entity.unwrap_err());
        println!("{err_message}");
        assert!(err_message.contains("Index error: Field 'collection' is a @derivedFrom field"));
    }

    #[test]
    fn test_duplicate_index_definition() {
        let schema_str = r#"
type TestEntity
  @index(fields: ["id", "tokenId"])
  @index(fields: ["id", "tokenId"]) {
  id: ID!
  tokenId: BigInt! @index
  collection: String!
  owner: String!
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let parsed_entity = Entity::from_object(&first_entity_schema);

        assert!(parsed_entity.is_err());
        let err_message = format!("{:?}", parsed_entity.unwrap_err());
        assert!(err_message.contains(
            "Index error: Duplicate index found on fields [\"id\", \"tokenId\"] in entity \
             'TestEntity'"
        ));
    }

    #[test]
    fn test_field_marked_as_indexed_and_index_directive() {
        let schema_str = r#"
type TestEntity @index(fields: ["tokenId"]) {
  id: ID!
  tokenId: BigInt! @index
  collection: String!
  owner: String!
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let parsed_entity = Entity::from_object(&first_entity_schema);

        assert!(parsed_entity.is_err());
        let err_message = format!("{:?}", parsed_entity.unwrap_err());
        println!("{err_message}");
        assert!(err_message.contains(
            "EE202: The field 'tokenId' is marked as an index. Please either remove the @index \
             directive on the field, or the @index(fields: [\"tokenId\"]) directive on the entity"
        ));
    }

    #[test]
    fn more_than_one_derived_from_directive() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  testField: String @derivedFrom(field: "someField") @derivedFrom(field: "anotherField")
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let result = Entity::from_object(&first_entity_schema);

        assert!(
            result.is_err(),
            "Should error with more than one @derivedFrom directive"
        );
    }

    #[test]
    fn more_than_one_indexed_directive() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  testField: String @index @index
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let result = Entity::from_object(&first_entity_schema);

        assert!(
            result.is_err(),
            "Should error with more than one @index directive"
        );
    }

    #[test]
    fn fail_derived_from_and_indexed_directive() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  testField: String @derivedFrom(field: "someField") @index
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let result = Entity::from_object(&first_entity_schema);

        assert!(
            result.is_err(),
            "Should error with both @derivedFrom and @index directives"
        );
    }

    #[test]
    fn fail_id_field_with_derived_from_or_indexed_directive() {
        let schema_str = r#"
type TestEntity {
  id: ID! @derivedFrom(field: "someField")
  ID: ID! @index
}
        "#;
        let first_entity_schema = get_first_entity_from_string(schema_str);
        let result = Entity::from_object(&first_entity_schema);

        assert!(
            result.is_err(),
            "Should error when 'id' or 'ID' field is indexed or derived from"
        );
    }

    #[test]
    fn gql_type_to_rescript_type_string() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::String)
            .to_rescript_type(&empty_schema)
            .expect("expected rescript option string");

        assert_eq!(rescript_type.to_string(), "option<string>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_int() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::Int)
            .to_rescript_type(&empty_schema)
            .expect("expected rescript option string");

        assert_eq!(rescript_type.to_string(), "option<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_int() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::NonNullType(Box::new(
            UserDefinedFieldType::Single(GqlScalar::Int),
        ))
        .to_rescript_type(&empty_schema)
        .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "int".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_array() {
        let empty_schema = Schema::empty();
        let rescript_type = UserDefinedFieldType::NonNullType(Box::new(
            UserDefinedFieldType::ListType(Box::new(UserDefinedFieldType::NonNullType(Box::new(
                UserDefinedFieldType::Single(GqlScalar::Int),
            )))),
        ))
        .to_rescript_type(&empty_schema)
        .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "array<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_null_array_int() {
        let empty_schema = Schema::empty();

        let rescript_type =
            UserDefinedFieldType::ListType(Box::new(UserDefinedFieldType::Single(GqlScalar::Int)))
                .to_rescript_type(&empty_schema)
                .expect("expected rescript type string");

        assert_eq!(
            rescript_type.to_string(),
            "option<array<option<int>>>".to_owned()
        );
    }

    #[test]
    fn gql_type_to_rescript_type_entity() {
        let test_entity_string = String::from("TestEntity");
        let test_entity = Entity::new(&test_entity_string, vec![], vec![]).unwrap();
        let schema = Schema::new(vec![test_entity], vec![]).unwrap();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::Custom(test_entity_string))
            .to_rescript_type(&schema)
            .expect("expected rescript type string");

        assert_eq!(rescript_type.to_string(), "option<id>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_enum() {
        let name = String::from("TestEnum");
        let test_enum = GraphQLEnum::new(name.clone(), vec![]).unwrap();
        let schema = Schema::new(vec![], vec![test_enum]).unwrap();
        let rescript_type = UserDefinedFieldType::Single(GqlScalar::Custom(name))
            .to_rescript_type(&schema)
            .expect("expected rescript type string");

        assert_eq!(
            rescript_type.to_string(),
            "option<Enums.TestEnum.t>".to_owned()
        );
    }

    #[test]
    fn field_type_is_optional_test() {
        let test_scalar = GqlScalar::Custom(String::from("TestEntity"));
        let test_field_type = UserDefinedFieldType::Single(test_scalar);
        assert!(
            test_field_type.is_optional(),
            "single field should have been optional"
        );

        // ListType:
        let test_list_type = UserDefinedFieldType::ListType(Box::new(test_field_type));
        assert!(
            test_list_type.is_optional(),
            "list field should have been optional"
        );

        // NonNullType
        let gql_array_non_null_type = UserDefinedFieldType::NonNullType(Box::new(test_list_type));
        assert!(
            !gql_array_non_null_type.is_optional(),
            "non-null field should not be optional"
        );
    }

    fn get_field_type_helper_with_additional(
        gql_field_str: &str,
        enum_types: Vec<GraphQLEnum>,
    ) -> FieldType {
        let enum_type_defs: String = enum_types
            .iter()
            .map(|e| format!("enum {} {{\n{}\n}}", e.name, e.values.join("\n")))
            .collect::<Vec<_>>()
            .join("\n");

        let schema_string = format!(
            r#"
        type TestEntity {{
          id: ID!
          test_field: {gql_field_str}
        }}
        {enum_type_defs}
        "#,
        );
        let schema_doc = graphql_parser::schema::parse_schema::<String>(&schema_string).unwrap();

        let schema = Schema::from_document(schema_doc).expect("bad schema");

        let test_field = schema
            .entities
            .get("TestEntity")
            .expect("No test entity in schema")
            .fields
            .get("test_field")
            .expect("No field test_field on entity")
            .clone();

        test_field.field_type
    }

    fn get_field_type_helper(gql_field_str: &str) -> FieldType {
        get_field_type_helper_with_additional(gql_field_str, vec![])
    }

    #[test]
    fn gql_enum_type_to_pgprimitive() {
        let name = String::from("TestEnum");
        let test_enum = GraphQLEnum::new(name.clone(), vec!["TEST_VALUE".to_string()]).unwrap();
        let field_type =
            get_field_type_helper_with_additional("TestEnum!", vec![test_enum.clone()]);
        let schema = Schema::new(vec![], vec![test_enum]).unwrap();
        let pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&schema)
            .expect("unable to get postgres primitive");
        assert_eq!(pg_primitive, PGPrimitive::Enum("TestEnum".to_string()));
    }

    #[test]
    fn gql_single_not_null_array_to_pgprimitive() {
        let gql_type = "[String!]!";
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("unable to get postgres primitive");
        assert_eq!(pg_primitive, PGPrimitive::Text);
        assert!(field_type.to_user_defined_field_type().is_array());
    }

    #[test]
    fn gql_multi_not_null_array_to_pgprimitive() {
        let gql_type = "[[Int!]!]!";
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("unable to get postgres primitive");
        assert_eq!(pg_primitive, PGPrimitive::Integer);
        assert!(field_type.to_user_defined_field_type().is_array());
    }

    #[test]
    #[should_panic]
    fn gql_single_nullable_array_to_pgprimitive_should_panic() {
        let gql_type = "[Int]!"; // Nested lists need to be not nullable
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let _pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("should panic due to validation error");
    }

    #[test]
    #[should_panic]
    fn gql_multi_nullable_array_to_pgprimitive_should_panic() {
        let gql_type = "[[Int!]]!"; // Nested lists need to be not nullable
        let field_type = get_field_type_helper(gql_type);
        let empty_schema = Schema::empty();
        let _pg_primitive = field_type
            .to_user_defined_field_type()
            .to_underlying_postgres_primitive(&empty_schema)
            .expect("should panic due to validation error");
    }

    #[test]
    fn test_nullability_to_string() {
        use UserDefinedFieldType::{ListType, NonNullType, Single};
        let scalar = NonNullType(Box::new(ListType(Box::new(Single(GqlScalar::Int)))));

        let expected_output = "[Int]!".to_string();

        assert_eq!(scalar.to_string(), expected_output);
    }

    #[test]
    fn gql_type_to_rescript_nullable() {
        let field_type = get_field_type_helper("Int");

        let empty_schema = Schema::empty();
        let rescript_type = field_type.to_rescript_type(&empty_schema).unwrap();
        assert_eq!("option<int>".to_string(), rescript_type.to_string());
    }

    #[test]
    #[ignore = "We don't support list types with nullable scalars due to postgres limitations"]
    fn gql_type_to_rescript_array_nullable_string() {
        let field_type = get_field_type_helper("[String]!");

        let empty_schema = Schema::empty();
        let rescript_type = field_type.to_rescript_type(&empty_schema).unwrap();
        assert_eq!(
            "array<option<string>>".to_string(),
            rescript_type.to_string()
        );
    }

    #[test]
    fn test_get_postgres_field_basic() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  name: String! @index
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema = Schema::from_document(gql_doc).unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.fields.get("name").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "name");
        assert_eq!(pg_field.field_type, PGPrimitive::Text);
        assert!(pg_field.is_index);
        assert!(!pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, None);
    }

    #[test]
    fn test_get_postgres_field_with_linked_entity() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  relatedEntity: RelatedEntity!
}

type RelatedEntity {
  id: ID!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema = Schema::from_document(gql_doc).unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.fields.get("relatedEntity").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "relatedEntity");
        assert_eq!(pg_field.field_type, PGPrimitive::Text);
        assert!(!pg_field.is_index);
        assert!(!pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, Some("RelatedEntity".to_string()));
    }

    #[test]
    fn test_get_postgres_field_array_type() {
        let schema_str = r#"
type TestEntity {
  id: ID!
  tags: [String!]!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema = Schema::from_document(gql_doc).unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.fields.get("tags").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "tags");
        assert_eq!(pg_field.field_type, PGPrimitive::Text);
        assert!(!pg_field.is_index);
        assert!(pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, None);
    }

    #[test]
    fn test_get_postgres_field_enum_type() {
        let schema_str = r#"
enum Status {
  ACTIVE
  INACTIVE
}

type TestEntity {
  id: ID!
  status: Status!
}
        "#;
        let gql_doc = setup_document(schema_str).unwrap();
        let schema = Schema::from_document(gql_doc).unwrap();
        let entity = schema.entities.get("TestEntity").unwrap();
        let field = entity.fields.get("status").unwrap();
        let pg_field = field
            .get_postgres_field(&schema, entity)
            .expect("Failed to get postgres field")
            .unwrap();

        assert_eq!(pg_field.field_name, "status");
        assert_eq!(pg_field.field_type, PGPrimitive::Enum("Status".to_string()));
        assert!(!pg_field.is_index);
        assert!(!pg_field.is_array);
        assert!(!pg_field.is_nullable);
        assert_eq!(pg_field.linked_entity, None);
    }

    #[test]
    fn test_decimal_precision_numeric_happy_path() {
        let schema_str = r#"
    type Entity {
        id: ID!
        exampleBigInt: BigInt @precision(digits: 76)
        exampleBigIntRequired: BigInt! @precision(digits: 77)
        exampleBigIntArray: [BigInt!] @precision(digits: 78)
        exampleBigIntArrayRequired: [BigInt!]! @precision(digits: 79)
        exampleBigDecimal: BigDecimal @numeric(precision: 80, scale: 5)
        exampleBigDecimalRequired: BigDecimal! @numeric(precision: 81, scale: 5)
        exampleBigDecimalArray: [BigDecimal!] @numeric(precision: 82, scale: 5)
        exampleBigDecimalArrayRequired: [BigDecimal!]! @numeric(precision: 83, scale: 5)
        exampleBigDecimalOtherOrder: BigDecimal! @numeric(scale: 6, precision: 84)
    }
    "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let schema = Schema::from_document(gql_doc).expect("Failed to create schema");

        // Verify that the schema contains the entity and fields as expected
        let entity = schema.entities.get("Entity").expect("Entity not found");

        // Helper function -  tests that the types of each field is what we expect
        fn check_field_type(
            field: &Field,
            expected_scalar: &str, // "BigInt" or "BigDecimal"
            expected_precision: Option<u32>,
            expected_scale: Option<u32>,
            is_required: bool,
            is_array: bool,
        ) {
            match &field.field_type {
                FieldType::RegularField { field_type, .. } => {
                    //  In this test, we strip this type from the outside to the inside like an onion and check that each layer is correct.
                    let mut current_type = field_type;

                    // Handle non-null types
                    if is_required {
                        match current_type {
                            UserDefinedFieldType::NonNullType(inner) => {
                                current_type = inner.as_ref();
                            }
                            _ => panic!("Field '{}' is expected to be non-null", field.name),
                        }
                    } else if matches!(current_type, UserDefinedFieldType::NonNullType(_)) {
                        panic!("Field '{}' should be nullable", field.name);
                    }

                    // Handle array types
                    if is_array {
                        match current_type {
                            UserDefinedFieldType::ListType(inner) => {
                                current_type = inner.as_ref();
                            }
                            _ => panic!("Field '{}' is expected to be an array", field.name),
                        }
                        // Array elements should be non-null (e.g., [Type!])
                        match current_type {
                            UserDefinedFieldType::NonNullType(inner) => {
                                current_type = inner.as_ref();
                            }
                            _ => panic!(
                                "Array elements of field '{}' are expected to be non-null",
                                field.name
                            ),
                        }
                    } else if matches!(current_type, UserDefinedFieldType::ListType(_)) {
                        panic!("Field '{}' should not be an array", field.name);
                    }

                    // Check the scalar type and precision/scale
                    match current_type {
                        UserDefinedFieldType::Single(scalar) => match (scalar, expected_scalar) {
                            (GqlScalar::BigInt(Some(precision)), "BigInt") => {
                                if let Some(expected_precision) = expected_precision {
                                    assert_eq!(
                                        *precision, expected_precision,
                                        "Field '{}' has precision {}, expected {}",
                                        field.name, precision, expected_precision
                                    );
                                } else {
                                    panic!("Expected precision for BigInt field '{}'", field.name);
                                }
                            }
                            (GqlScalar::BigDecimal(Some((precision, scale))), "BigDecimal") => {
                                if let (Some(expected_precision), Some(expected_scale)) =
                                    (expected_precision, expected_scale)
                                {
                                    assert_eq!(
                                        (*precision, *scale),
                                        (expected_precision, expected_scale),
                                        "Field '{}' has precision {}, scale {}, expected \
                                         precision {}, scale {}",
                                        field.name,
                                        precision,
                                        scale,
                                        expected_precision,
                                        expected_scale
                                    );
                                } else {
                                    panic!(
                                        "Expected precision and scale for BigDecimal field '{}'",
                                        field.name
                                    );
                                }
                            }
                            _ => panic!(
                                "Field '{}' has unexpected scalar type or missing precision/scale",
                                field.name
                            ),
                        },
                        _ => panic!("Field '{}' has unexpected field type", field.name),
                    }
                }
                _ => panic!("Field '{}' is not a regular field", field.name),
            }
        }

        // Now use the helper function to test all fields

        // BigInt fields
        check_field_type(
            entity.fields.get("exampleBigInt").expect("Field not found"),
            "BigInt",
            Some(76),
            None,
            false, // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .fields
                .get("exampleBigIntRequired")
                .expect("Field not found"),
            "BigInt",
            Some(77),
            None,
            true,  // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .fields
                .get("exampleBigIntArray")
                .expect("Field not found"),
            "BigInt",
            Some(78),
            None,
            false, // is_required
            true,  // is_array
        );

        check_field_type(
            entity
                .fields
                .get("exampleBigIntArrayRequired")
                .expect("Field not found"),
            "BigInt",
            Some(79),
            None,
            true, // is_required
            true, // is_array
        );

        // BigDecimal fields
        check_field_type(
            entity
                .fields
                .get("exampleBigDecimal")
                .expect("Field not found"),
            "BigDecimal",
            Some(80),
            Some(5),
            false, // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .fields
                .get("exampleBigDecimalRequired")
                .expect("Field not found"),
            "BigDecimal",
            Some(81),
            Some(5),
            true,  // is_required
            false, // is_array
        );

        check_field_type(
            entity
                .fields
                .get("exampleBigDecimalArray")
                .expect("Field not found"),
            "BigDecimal",
            Some(82),
            Some(5),
            false, // is_required
            true,  // is_array
        );

        check_field_type(
            entity
                .fields
                .get("exampleBigDecimalArrayRequired")
                .expect("Field not found"),
            "BigDecimal",
            Some(83),
            Some(5),
            true, // is_required
            true, // is_array
        );

        // exampleBigDecimalOtherOrder
        check_field_type(
            entity
                .fields
                .get("exampleBigDecimalOtherOrder")
                .expect("Field not found"),
            "BigDecimal",
            Some(84),
            Some(6),
            true,  // is_required
            false, // is_array
        );
    }

    #[test]
    fn test_error_case_numeric_on_bigint() {
        let schema_str = r#"
        type Entity {
            id: ID!
            exampleBigIntWrongDirective: BigInt @numeric(precision: 76, scale: 5)
        }
        "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let result = Schema::from_document(gql_doc);

        assert!(result.is_err());
        let err_message = format!("{:?}", result.unwrap_err());
        assert!(err_message.contains(
            "The numeric directive on a field is only suitable for BigDecimal scalar type."
        ));
    }

    #[test]
    fn test_error_case_decimal_precision_on_bigdecimal() {
        let schema_str = r#"
        type Entity {
            id: ID!
            exampleBigIntWrongDirective: BigDecimal @precision(precision: 76)
        }
        "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let result = Schema::from_document(gql_doc);

        assert!(result.is_err());
        let err_message = format!("{:?}", result.unwrap_err());
        assert!(err_message.contains(
            "The precision directive on a field is only suitable for BigInt scalar type."
        ));
    }

    #[test]
    fn test_error_case_decimal_precision_wrong_name() {
        let schema_str = r#"
        type Entity {
            id: ID!
            exampleBigDecimalWrongDirective: BigInt @precision(wronglabel: 76)
        }
        "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let result = Schema::from_document(gql_doc);

        assert!(matches!(
            result,
            Err(SchemaParseError::EntityParseError {
                err: EntityParseError::FieldParseError {
                    err: FieldParseError::InvalidDirective {
                        err: DirectiveParseError::InvalidArgument { .. },
                        ..
                    },
                    ..
                },
                ..
            })
        ));
        // assert!(err_message.contains(
        //     "The precision directive on a BigInt should only have a 'digits' parameter. Unknown \
        //      parameter 'wronglabel'. Field 'exampleBigDecimalWrongDirective'"
        // ));
    }

    #[test]
    fn test_error_case_numeric_unknown_parameter() {
        let schema_str = r#"
        type Entity {
            id: ID!
            exampleBigIntWrongDirective: BigDecimal @numeric(wronglabel: 76, scale: 5)
        }
        "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let result = Schema::from_document(gql_doc);

        assert!(result.is_err());
        let err_message = format!("{:?}", result.unwrap_err());
        assert!(err_message.contains(
            "The numeric directive on a BigDecimal should only have 'precision' and 'scale' \
             parameters. Unknown parameter 'wronglabel'."
        ));
    }

    #[test]
    fn test_error_case_numeric_unknown_parameter_with_precision() {
        let schema_str = r#"
        type Entity {
            id: ID!
            exampleBigIntWrongDirective: BigDecimal @numeric(precision: 76, wronglabel: 4, scale: 5)
        }
        "#;

        let gql_doc = setup_document(schema_str).expect("Failed to parse schema");
        let result = Schema::from_document(gql_doc);

        assert!(result.is_err());
        let err_message = format!("{:?}", result.unwrap_err());
        println!("SEEE MEEE {}", err_message);
        assert!(err_message.contains(
            "The numeric directive on a BigDecimal should only have 'precision' and 'scale' \
             parameters. Unknown parameter 'wronglabel'."
        ));
    }
}
