use crate::{
    capitalization::Capitalize,
    capitalization::CapitalizedOptions,
    hbs_templating::codegen_templates::{
        EntityParamTypeTemplate, EntityRecordTypeTemplate, EntityRelationalTypesTemplate,
        FilteredTemplateLists, RelationshipTypeTemplate,
    },
    project_paths::ParsedPaths,
};
use graphql_parser::schema::{Definition, Directive, Type, TypeDefinition, Value};
use std::collections::HashSet;

use super::validation::check_names_from_schema_for_reserved_words;

pub fn get_entity_record_types_from_schema(
    parsed_paths: &ParsedPaths,
) -> Result<Vec<EntityRecordTypeTemplate>, String> {
    let schema_string = std::fs::read_to_string(&parsed_paths.schema_path).map_err(|err| {
        format!(
            "EE200: Failed to read schema file at {} with Error: {}. Please ensure that the schema file is placed correctly in the directory.",
            &parsed_paths.schema_path.to_str().unwrap_or("unknown file"),
            err
        )
    })?;

    let schema_doc = graphql_parser::parse_schema::<String>(&schema_string)
        .map_err(|err| format!("EE201: Failed to parse schema with Error: {}", err))?;
    let mut schema_object_types = Vec::new();
    let mut entities_set: HashSet<String> = HashSet::new();
    let mut names_from_schema: Vec<&str> = Vec::new();

    for definition in schema_doc.definitions.iter() {
        match definition {
            Definition::SchemaDefinition(_) => (),
            Definition::TypeDefinition(def) => match def {
                TypeDefinition::Scalar(_) => (),
                TypeDefinition::Object(object) => {
                    entities_set.insert(object.name.clone());
                    schema_object_types.push(object);
                    names_from_schema.push(object.name.as_str());
                }
                TypeDefinition::Interface(_) => (),
                TypeDefinition::Union(_) => (),
                TypeDefinition::Enum(_) => (),
                TypeDefinition::InputObject(_) => (),
            },
            Definition::DirectiveDefinition(_) => (),
            Definition::TypeExtension(_) => (),
        };
    }
    let mut entity_records = Vec::new();
    for object in schema_object_types.iter() {
        let mut params = Vec::new();
        let mut relational_params_all = Vec::new();
        for field in object.fields.iter() {
            //Get all gql derictives labeled @derivedFrom
            let derived_from_directives = field
                .directives
                .iter()
                .filter(|directive| directive.name == "derivedFrom")
                .collect::<Vec<&Directive<'_, String>>>();

            //Do not allow for multiple @derivedFrom directives
            //If this step is not important and we are fine with just taking the first one
            //in the case of multiple we can just use a find rather than a filter method above
            if derived_from_directives.len() > 1 {
                let msg = format!(
                    "EE202: Cannot use more than one @derivedFrom directive, please update your entity {} at field {}",
                    object.name, field.name
                );
                return Err(msg);
            }

            let maybe_derived_from_directive = derived_from_directives.get(0);
            let derived_from_field_key = match maybe_derived_from_directive {
                None => None,
                Some(d) => {
                    let field_arg =
                        d.arguments.iter().find(|a| a.0 == "field").ok_or_else(|| {
                            format!(
                                "EE203: No 'field' argument supplied to @derivedFrom directive on field {}, entity {}",
                                field.name, object.name
                            )
                        })?;
                    match &field_arg.1 {
                        Value::String(val) => Some(val.to_capitalized_options()),
                        _ => Err(format!("EE204: 'field' argument in @derivedFrom directive on field {}, entity {} needs to contain a string", field.name, object.name))?

                    }
                }
            };
            let is_derived_from = maybe_derived_from_directive.map_or(false, |_| true);

            let param_type = gql_type_to_rescript_type(&field.field_type, &entities_set)?;
            let param_pg_type = gql_type_to_postgres_type(&field.field_type, &entities_set)?;
            let maybe_relationship_type = gql_type_to_postgres_relational_type(
                &field.name,
                &field.field_type,
                &entities_set,
                derived_from_field_key,
            );

            //If the field has a relational type with a derived from field key
            //Validate that the derived_from_field_key exists
            //This simpler to do here once the relational_type has already been parsed
            if let Some(relational_type) = &maybe_relationship_type {
                if let Some(field_key) = &relational_type.derived_from_field_key {
                    let entity = schema_object_types
                        .iter()
                        .find(|obj| {
                            obj.name.to_capitalized_options().uncapitalized
                                == relational_type.mapped_entity.uncapitalized
                        })
                        .ok_or_else(|| {
                            format!(
                                "EE205: Derived entity {} does not exist in schema",
                                relational_type.mapped_entity.capitalized
                            )
                        })?;

                    entity
                        .fields
                        .iter()
                        .find(|field| {
                            field.name.to_capitalized_options().uncapitalized
                                == field_key.uncapitalized
                        })
                        .ok_or_else(|| {
                            format!(
                                "EE206: Derived field {} does not exist on entity {}",
                                field_key.uncapitalized, entity.name
                            )
                        })?;
                }
            }

            let param_maybe_entity_name =
                gql_type_to_capitalized_entity_name(&field.field_type, &entities_set);

            let is_optional = gql_type_is_optional(&field.field_type);

            params.push(EntityParamTypeTemplate {
                key: field.name.to_owned(),
                is_optional,
                type_rescript: param_type.to_owned(),
                type_rescript_non_optional: strip_option_from_rescript_type_str(&param_type),
                type_pg: param_pg_type,
                maybe_entity_name: param_maybe_entity_name,
                is_derived_from,
            });

            relational_params_all.extend(maybe_relationship_type);
            names_from_schema.push(field.name.as_str());
        }

        //Template needs access to both the full list and filtered for
        //relational params that are not using a "@derivedFrom" directive
        let relational_params = FilteredTemplateLists::new(relational_params_all);
        entity_records.push(EntityRecordTypeTemplate {
            name: object.name.to_owned().to_capitalized_options(),
            params,
            relational_params,
        })
    }

    // validate that no user defined names in the schema are reserved words
    let detected_reserved_words =
        check_names_from_schema_for_reserved_words(&names_from_schema.join(" "));

    if !detected_reserved_words.is_empty() {
        return Err(format!(
            "EE210: The schema file cannot contain any reserved words from JavaScript or ReScript. Reserved word(s) are: {}. Please rename them in the schema file.",
            detected_reserved_words.join(" "),
        ));
    }

    Ok(entity_records)
}

enum BuiltInGqlScalar {
    ID,
    String,
    Int,
    Float,
    Boolean,
}

enum AdditionalGqlScalar {
    BigInt,
    Bytes,
}

enum GqlScalar {
    BuiltIn(BuiltInGqlScalar),
    Additional(AdditionalGqlScalar),
    Custom(String),
}

fn gql_named_to_scalar(named_type: &str) -> GqlScalar {
    match named_type {
        "ID" => GqlScalar::BuiltIn(BuiltInGqlScalar::ID),
        "String" => GqlScalar::BuiltIn(BuiltInGqlScalar::String),
        "Int" => GqlScalar::BuiltIn(BuiltInGqlScalar::Int),
        "Float" => GqlScalar::BuiltIn(BuiltInGqlScalar::Float), // Should we allow this type? Rounding issues will abound.
        "Boolean" => GqlScalar::BuiltIn(BuiltInGqlScalar::Boolean),
        "BigInt" => GqlScalar::Additional(AdditionalGqlScalar::BigInt), // NOTE: we aren't setting precision and scale - see (8.1.2) https://www.postgresql.org/docs/current/datatype-numeric.html
        "Bytes" => GqlScalar::Additional(AdditionalGqlScalar::Bytes),
        custom_type => GqlScalar::Custom(custom_type.to_string()),
    }
}

fn gql_named_types_to_postgres_types(
    scalar_type: &GqlScalar,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    let converted = match scalar_type {
        GqlScalar::BuiltIn(scalar) => {
            use BuiltInGqlScalar::{Boolean, Float, Int, String, ID};
            match scalar {
                ID => "text".to_owned(),
                String => "text".to_owned(),
                Int => "integer".to_owned(),
                Float => "numeric".to_owned(), // Should we allow this type? Rounding issues will abound.
                Boolean => "boolean".to_owned(),
            }
        }
        GqlScalar::Additional(scalar) => {
            use AdditionalGqlScalar::{BigInt, Bytes};
            match scalar {
                Bytes => "text".to_owned(),
                BigInt => "numeric".to_owned(), // NOTE: we aren't setting precision and scale - see (8.1.2) https://www.postgresql.org/docs/current/datatype-numeric.html
            }
        }
        GqlScalar::Custom(named_type) => {
            if entities_set.contains(named_type) {
                "text".to_owned() //This would be the ID of another defined entity
            } else {
                let error_message =
                    format!("EE207: Failed to parse undefined type: {}", named_type);
                Err(error_message.to_owned())?
            }
        }
    };
    Ok(converted)
}

fn gql_type_to_postgres_type(
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    let composed_type_name = match gql_type {
        Type::NamedType(named) => {
            let scalar = gql_named_to_scalar(named);
            gql_named_types_to_postgres_types(&scalar, entities_set)?
        }
        Type::ListType(gql_type) => match *gql_type.clone() {
            //Postgres doesn't support nullable types inside of arrays
            Type::NonNullType(gql_type) =>format!("{}[]", gql_type_to_postgres_type(&gql_type, entities_set)?),
            Type::NamedType(named)   => Err(format!(
                "EE208: Nullable scalars inside lists are unsupported. Please include a '!' after your '{}' scalar", named
            ))?,
            Type::ListType(_) => Err("EE209: Nullable multidimensional lists types are unsupported, please include a '!' for your inner list type eg. [[Int!]!]")?,
        },
        Type::NonNullType(gql_type) => format!(
            "{} NOT NULL",
            gql_type_to_postgres_type(gql_type, entities_set)?
        ),
    };
    Ok(composed_type_name)
}

fn gql_type_is_optional(gql_type: &Type<String>) -> bool {
    !matches!(gql_type, Type::NonNullType(_))
}

fn gql_type_to_postgres_relational_type(
    field_name: &String,
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
    derived_from_field_key: Option<CapitalizedOptions>,
) -> Option<EntityRelationalTypesTemplate> {
    match gql_type {
        Type::NamedType(named) if entities_set.contains(named) => {
            Some(EntityRelationalTypesTemplate {
                relational_key: field_name.clone().to_capitalized_options(),
                mapped_entity: named.to_capitalized_options(),
                relationship_type: RelationshipTypeTemplate::Object,
                is_optional: true,
                is_array: false,
                derived_from_field_key,
            })
        }
        Type::NamedType(_) => None,
        Type::ListType(gql_type) => {
            match gql_type_to_postgres_relational_type(
                field_name,
                gql_type,
                entities_set,
                derived_from_field_key,
            ) {
                Some(mut relational_type) => {
                    relational_type.relationship_type = RelationshipTypeTemplate::Array;
                    relational_type.is_array = true;

                    Some(relational_type)
                }
                None => None,
            }
        }
        Type::NonNullType(gql_type) => {
            match gql_type_to_postgres_relational_type(
                field_name,
                gql_type,
                entities_set,
                derived_from_field_key,
            ) {
                Some(mut relational_type) => {
                    relational_type.is_optional = false;
                    Some(relational_type)
                }
                None => None,
            }
        }
    }
}
fn gql_named_types_to_rescript_types(
    named_type: &str,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    match named_type {
        "ID" => Ok("string".to_owned()),
        "String" => Ok("string".to_owned()),
        "Int" => Ok("int".to_owned()),
        "BigInt" => Ok("Ethers.BigInt.t".to_owned()),
        "Float" => Ok("float".to_owned()),
        "Bytes" => Ok("string".to_owned()),
        "Boolean" => Ok("bool".to_owned()),
        custom_type => {
            if entities_set.contains(custom_type) {
                Ok("id".to_owned())
            } else {
                let error_message = format!("Failed to parse undefined type: {}", custom_type);
                Err(error_message.to_owned())
            }
        }
    }
}

enum NullableContainer {
    NotNullable,
    Nullable,
}

fn gql_type_to_rescript_type_with_container_wrapper(
    gql_type: &Type<String>,
    container_type: NullableContainer,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    let composed_type_name = match (gql_type, container_type) {
        (Type::NamedType(named), NullableContainer::NotNullable) => {
            gql_named_types_to_rescript_types(named, entities_set)?
        }
        (Type::NamedType(named), NullableContainer::Nullable) => {
            format!(
                "option<{}>",
                gql_named_types_to_rescript_types(named, entities_set)?
            )
        }
        (Type::ListType(gql_type), NullableContainer::NotNullable) => format!(
            "array<{}>",
            gql_type_to_rescript_type_with_container_wrapper(
                gql_type,
                NullableContainer::Nullable,
                entities_set
            )?
        ),
        (Type::ListType(gql_type), NullableContainer::Nullable) => format!(
            "option<array<{}>>",
            gql_type_to_rescript_type_with_container_wrapper(
                gql_type,
                NullableContainer::Nullable,
                entities_set
            )?
        ),
        (Type::NonNullType(gql_type), _) => (gql_type_to_rescript_type_with_container_wrapper(
            gql_type,
            NullableContainer::NotNullable,
            entities_set,
        )?)
        .to_string(),
    };
    Ok(composed_type_name)
}

fn gql_type_to_rescript_type(
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    gql_type_to_rescript_type_with_container_wrapper(
        gql_type,
        NullableContainer::Nullable,
        entities_set,
    )
}

fn strip_option_from_rescript_type_str(s: &str) -> String {
    let prefix = "option<";
    let suffix = ">";
    if s.starts_with(prefix) && s.ends_with(suffix) {
        let without_prefix = s.strip_prefix(prefix).unwrap();
        let without_suffix = without_prefix.strip_suffix(suffix).unwrap();
        return without_suffix.to_string();
    }
    s.to_string()
}

fn gql_type_to_capitalized_entity_name(
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
) -> Option<CapitalizedOptions> {
    match gql_type {
        Type::NamedType(named_type) => entities_set
            .contains(named_type)
            .then(|| named_type.to_owned().to_capitalized_options()),
        Type::ListType(gql_type) => gql_type_to_capitalized_entity_name(gql_type, entities_set),
        Type::NonNullType(gql_type) => gql_type_to_capitalized_entity_name(gql_type, entities_set),
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        capitalization::Capitalize,
        config_parsing::entity_parsing::{
            gql_type_is_optional, gql_type_to_postgres_relational_type, gql_type_to_rescript_type,
        },
        hbs_templating::codegen_templates::{
            EntityRelationalTypesTemplate, RelationshipTypeTemplate,
        },
    };
    use graphql_parser::schema::{Definition, Type, TypeDefinition};
    use std::collections::HashSet;

    #[test]
    fn gql_type_to_rescript_type_string() {
        let empty_set = HashSet::new();
        let gql_string_type = Type::NamedType("String".to_owned());
        let result = gql_type_to_rescript_type(&gql_string_type, &empty_set).unwrap();

        assert_eq!(result, "option<string>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_int() {
        let empty_set = HashSet::new();
        let gql_int_type = Type::NamedType("Int".to_owned());
        let result = gql_type_to_rescript_type(&gql_int_type, &empty_set).unwrap();

        assert_eq!(result, "option<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_int() {
        let empty_set = HashSet::new();
        let gql_int_type = Type::NonNullType(Box::new(Type::NamedType("Int".to_owned())));
        let result = gql_type_to_rescript_type(&gql_int_type, &empty_set).unwrap();

        assert_eq!(result, "int".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_non_null_array() {
        let empty_set = HashSet::new();
        let gql_int_type = Type::NonNullType(Box::new(Type::ListType(Box::new(
            Type::NonNullType(Box::new(Type::NamedType("Int".to_owned()))),
        ))));
        let result = gql_type_to_rescript_type(&gql_int_type, &empty_set).unwrap();

        assert_eq!(result, "array<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_null_array_int() {
        let empty_set = HashSet::new();
        let gql_int_type = Type::ListType(Box::new(Type::NamedType("Int".to_owned())));
        let result = gql_type_to_rescript_type(&gql_int_type, &empty_set).unwrap();

        assert_eq!(result, "option<array<option<int>>>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_entity() {
        let mut entity_set = HashSet::new();
        let test_entity_string = String::from("TestEntity");
        entity_set.insert(test_entity_string.clone());
        let gql_string_type = Type::NamedType(test_entity_string);
        let result = gql_type_to_rescript_type(&gql_string_type, &entity_set).unwrap();

        assert_eq!(result, "option<id>".to_owned());
    }

    #[test]
    fn gql_type_to_relational_type_scalar() {
        let entity_set = HashSet::new();

        let gql_object_type = Type::NamedType("Int".to_owned());
        let field_name = String::from("testField1");
        let derived_from_field_key = None;
        let result = gql_type_to_postgres_relational_type(
            &field_name,
            &gql_object_type,
            &entity_set,
            derived_from_field_key,
        );
        let expect_output = None;
        assert_eq!(result, expect_output);
    }

    #[test]
    fn gql_type_to_relational_type_entity() {
        let mut entity_set = HashSet::new();
        let test_entity_string = String::from("TestEntity");
        entity_set.insert(test_entity_string.clone());
        let gql_object_type = Type::NamedType(test_entity_string.clone());
        let field_name = String::from("testField1");
        let derived_from_field_key = None;
        let result = gql_type_to_postgres_relational_type(
            &field_name,
            &gql_object_type,
            &entity_set,
            derived_from_field_key.clone(),
        );
        let expect_output = Some(EntityRelationalTypesTemplate {
            is_optional: true,
            is_array: false,
            relational_key: field_name.to_capitalized_options(),
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: RelationshipTypeTemplate::Object,
            derived_from_field_key,
        });
        assert_eq!(result, expect_output);
    }

    #[test]
    fn gql_type_to_non_null_relational_type_entity() {
        let mut entity_set = HashSet::new();
        let test_entity_string = String::from("TestEntity");
        entity_set.insert(test_entity_string.clone());
        let gql_object_type =
            Type::NonNullType(Box::new(Type::NamedType(test_entity_string.clone())));
        let field_name = String::from("testField1");
        let derived_from_field_key = None;
        let result = gql_type_to_postgres_relational_type(
            &field_name,
            &gql_object_type,
            &entity_set,
            derived_from_field_key.clone(),
        );
        let expect_output = Some(EntityRelationalTypesTemplate {
            is_optional: false,
            is_array: false,
            relational_key: field_name.to_capitalized_options(),
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: RelationshipTypeTemplate::Object,
            derived_from_field_key,
        });
        assert_eq!(result, expect_output);
    }

    #[test]
    fn gql_type_to_relational_type_array_entity() {
        let mut entity_set = HashSet::new();
        let test_entity_string = String::from("TestEntity");
        entity_set.insert(test_entity_string.clone());
        let gql_array_object_type =
            Type::ListType(Box::new(Type::NamedType(test_entity_string.clone())));

        let field_name = String::from("testField1");
        let derived_from_field_key = None;
        let result = gql_type_to_postgres_relational_type(
            &field_name,
            &gql_array_object_type,
            &entity_set,
            derived_from_field_key.clone(),
        );
        let expect_output = Some(EntityRelationalTypesTemplate {
            is_optional: true,
            is_array: true,
            relational_key: field_name.to_capitalized_options(),
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: RelationshipTypeTemplate::Array,
            derived_from_field_key,
        });
        assert_eq!(result, expect_output);
    }
    #[test]
    fn gql_type_to_non_null_relational_type_array_entity() {
        let mut entity_set = HashSet::new();
        let test_entity_string = String::from("TestEntity");
        entity_set.insert(test_entity_string.clone());
        let gql_array_object_type = Type::NonNullType(Box::new(Type::ListType(Box::new(
            Type::NonNullType(Box::new(Type::NamedType(test_entity_string.clone()))),
        ))));

        let field_name = String::from("testField1");
        let derived_from_field_key = None;
        let result = gql_type_to_postgres_relational_type(
            &field_name,
            &gql_array_object_type,
            &entity_set,
            derived_from_field_key.clone(),
        );
        let expect_output = Some(EntityRelationalTypesTemplate {
            is_optional: false,
            is_array: true,
            relational_key: field_name.to_capitalized_options(),
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: RelationshipTypeTemplate::Array,
            derived_from_field_key,
        });
        assert_eq!(result, expect_output);
    }

    #[test]
    fn gql_type_is_optional_test() {
        let test_entity_string = String::from("TestEntity");
        let test_named_entity = Type::NamedType(test_entity_string);
        // NamedType:
        let is_optional = gql_type_is_optional(&test_named_entity);
        assert!(is_optional);

        // ListType:
        let test_list_type = Type::ListType(Box::new(test_named_entity));
        let is_optional = gql_type_is_optional(&test_list_type);
        assert!(is_optional);

        // NonNullType
        let gql_array_non_null_type = Type::NonNullType(Box::new(test_list_type));
        let is_optional = gql_type_is_optional(&gql_array_non_null_type);
        assert!(!is_optional);
    }

    fn gql_type_to_postgres_type_test_helper(gql_field_str: &str) -> String {
        let schema_string = format!(
            r#"
        type TestEntity @entity {{
          test_field: {}
        }}
        "#,
            gql_field_str
        );
        let schema = graphql_parser::schema::parse_schema::<String>(&schema_string).unwrap();
        let hash_set = HashSet::new();
        let mut gql_type: Option<Type<String>> = None;

        schema.definitions.iter().for_each(|def| {
            if let Definition::TypeDefinition(TypeDefinition::Object(obj_def)) = def {
                obj_def.fields.iter().for_each(|field| {
                    gql_type = Some(field.field_type.clone());
                })
            }
        });
        super::gql_type_to_postgres_type(&gql_type.unwrap(), &hash_set).unwrap()
    }

    #[test]
    fn gql_single_not_null_array_to_pg_type() {
        let gql_type = "[String!]!";
        let pg_type = gql_type_to_postgres_type_test_helper(gql_type);
        assert_eq!(pg_type, "text[] NOT NULL");
    }

    #[test]
    fn gql_multi_not_null_array_to_pg_type() {
        let gql_type = "[[Int!]!]!";
        let pg_type = gql_type_to_postgres_type_test_helper(gql_type);
        assert_eq!(pg_type, "integer[][] NOT NULL");
    }

    #[test]
    #[should_panic]
    fn gql_single_nullable_array_to_pg_type_should_panic() {
        let gql_type = "[Int]!"; //Nested lists need to be not nullable
        gql_type_to_postgres_type_test_helper(gql_type);
    }

    #[test]
    #[should_panic]
    fn gql_multi_nullable_array_to_pg_type_should_panic() {
        let gql_type = "[[Int!]]!"; //Nested lists need to be not nullable
        gql_type_to_postgres_type_test_helper(gql_type);
    }

    #[test]
    fn strip_option_removes_option() {
        assert_eq!(
            super::strip_option_from_rescript_type_str("option<bool>"),
            "bool"
        );

        assert_eq!(
            super::strip_option_from_rescript_type_str("option<array<string>>"),
            "array<string>"
        );

        assert_eq!(
            super::strip_option_from_rescript_type_str("array<string>"),
            "array<string>"
        );
        assert_eq!(
            super::strip_option_from_rescript_type_str("array<string>"),
            "array<string>"
        );
        assert_eq!(super::strip_option_from_rescript_type_str("option<>"), "");
        assert_eq!(
            super::strip_option_from_rescript_type_str("option<"),
            "option<"
        );
    }
}
