use crate::{
    capitalization::Capitalize, capitalization::CapitalizedOptions, project_paths::ParsedPaths,
    EntityParamType, EntityRecordType, EntityRelationalTypes,
};
use graphql_parser::schema::{Definition, Type, TypeDefinition};
use std::collections::HashSet;

pub fn get_entity_record_types_from_schema(
    parsed_paths: &ParsedPaths,
) -> Result<Vec<EntityRecordType>, String> {
    let schema_string = std::fs::read_to_string(&parsed_paths.schema_path).map_err(|err| {
        format!(
            "Failed to read schema file at {} with Error: {}",
            &parsed_paths.schema_path.to_str().unwrap_or("unknown file"),
            err.to_string()
        )
    })?;

    let schema_doc = graphql_parser::parse_schema::<String>(&schema_string)
        .map_err(|err| format!("Failed to parse schema with Error: {}", err.to_string()))?;
    let mut schema_object_types = Vec::new();
    let mut entities_set: HashSet<String> = HashSet::new();

    for definition in schema_doc.definitions.iter() {
        match definition {
            Definition::SchemaDefinition(_) => (),
            Definition::TypeDefinition(def) => match def {
                TypeDefinition::Scalar(_) => (),
                TypeDefinition::Object(object) => {
                    entities_set.insert(object.name.clone());
                    schema_object_types.push(object);
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
        let mut relational_params = Vec::new();
        for field in object.fields.iter() {
            let param_type = gql_type_to_rescript_type(&field.field_type, &entities_set)?;
            let param_pg_type = gql_type_to_postgres_type(&field.field_type, &entities_set)?;
            let relationship_type =
                gql_type_to_postgres_relational_type(&field.name, &field.field_type, &entities_set);
            let param_maybe_entity_name =
                gql_type_to_capitalized_entity_name(&field.field_type, &entities_set);

            let is_optional = gql_type_is_optional(&field.field_type);

            params.push(EntityParamType {
                key: field.name.to_owned(),
                is_optional,
                type_rescript: param_type,
                type_pg: param_pg_type,
                maybe_entity_name: param_maybe_entity_name,
            });

            relational_params.extend(relationship_type);
        }

        entity_records.push(EntityRecordType {
            name: object.name.to_owned().to_capitalized_options(),
            params,
            relational_params,
        })
    }
    Ok(entity_records)
}

enum NullableContainer {
    NotNullable,
    Nullable,
}

fn gql_named_types_to_postgres_types(
    named_type: &str,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    match named_type {
        "ID" => Ok("text".to_owned()),
        "String" => Ok("text".to_owned()),
        "Int" => Ok("integer".to_owned()),
        "BigInt" => Ok("numeric".to_owned()), // NOTE: we aren't setting precision and scale - see (8.1.2) https://www.postgresql.org/docs/current/datatype-numeric.html
        "Float" => Ok("numeric".to_owned()), // Should we allow this type? Rounding issues will abound.
        "Bytes" => Ok("text".to_owned()),
        "Boolean" => Ok("boolean".to_owned()),
        custom_type => {
            if entities_set.contains(custom_type) {
                Ok("text".to_owned())
            } else {
                let error_message = format!("Failed to parse undefined type: {}", custom_type);
                Err(error_message.to_owned())
            }
        }
    }
}

fn gql_type_to_postgres_type(
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    let composed_type_name = match gql_type {
        Type::NamedType(named) => gql_named_types_to_postgres_types(named, entities_set)?,
        Type::ListType(_gql_type) => {
            // NOTE: arrays are currently stored as text in the database, this is a temporary hack.
            String::from("text")
        }
        Type::NonNullType(gql_type) => format!(
            "{}  NOT NULL",
            gql_type_to_postgres_type(&gql_type, entities_set)?
        ),
    };
    Ok(composed_type_name)
}

fn gql_type_is_optional(gql_type: &Type<String>) -> bool {
    return !matches!(gql_type, Type::NonNullType(_));
}

fn gql_type_to_postgres_relational_type(
    field_name: &String,
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
) -> Option<EntityRelationalTypes> {
    match gql_type {
        Type::NamedType(named) if entities_set.contains(named) => Some(EntityRelationalTypes {
            relational_key: field_name.clone(),
            mapped_entity: named.to_capitalized_options(),
            relationship_type: "object".to_owned(),
        }),
        Type::NamedType(_) => None,
        Type::ListType(gql_type) => {
            match gql_type_to_postgres_relational_type(&field_name, &gql_type, &entities_set) {
                Some(mut relational_type) => {
                    relational_type.relationship_type = "array".to_owned();
                    Some(relational_type)
                }
                None => None,
            }
        }
        Type::NonNullType(gql_type) => {
            gql_type_to_postgres_relational_type(&field_name, &gql_type, &entities_set)
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
                &gql_type,
                NullableContainer::Nullable,
                entities_set
            )?
        ),
        (Type::ListType(gql_type), NullableContainer::Nullable) => format!(
            "option<array<{}>>",
            gql_type_to_rescript_type_with_container_wrapper(
                &gql_type,
                NullableContainer::Nullable,
                entities_set
            )?
        ),
        (Type::NonNullType(gql_type), _) => format!(
            "{}",
            gql_type_to_rescript_type_with_container_wrapper(
                &gql_type,
                NullableContainer::NotNullable,
                entities_set
            )?
        ),
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

fn gql_type_to_capitalized_entity_name(
    gql_type: &Type<String>,
    entities_set: &HashSet<String>,
) -> Option<CapitalizedOptions> {
    match gql_type {
        Type::NamedType(named_type) => entities_set
            .contains(named_type)
            .then(|| named_type.to_owned().to_capitalized_options()),
        // NOTE: we don't support lists of entities yet
        // TODO [#363]: make this work for lists of entities
        Type::ListType(_gql_type) => None,
        Type::NonNullType(gql_type) => gql_type_to_capitalized_entity_name(&gql_type, entities_set),
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        capitalization::Capitalize,
        entity_parsing::{
            gql_type_is_optional, gql_type_to_postgres_relational_type, gql_type_to_rescript_type,
        },
        EntityRelationalTypes,
    };
    use graphql_parser::schema::Type;
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
        let result =
            gql_type_to_postgres_relational_type(&field_name, &gql_object_type, &entity_set);
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
        let result =
            gql_type_to_postgres_relational_type(&field_name, &gql_object_type, &entity_set);
        let expect_output = Some(EntityRelationalTypes {
            relational_key: field_name,
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: "object".to_owned(),
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
        let result =
            gql_type_to_postgres_relational_type(&field_name, &gql_object_type, &entity_set);
        let expect_output = Some(EntityRelationalTypes {
            relational_key: field_name,
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: "object".to_owned(),
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
        let result =
            gql_type_to_postgres_relational_type(&field_name, &gql_array_object_type, &entity_set);
        let expect_output = Some(EntityRelationalTypes {
            relational_key: field_name,
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: "array".to_owned(),
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
        let result =
            gql_type_to_postgres_relational_type(&field_name, &gql_array_object_type, &entity_set);
        let expect_output = Some(EntityRelationalTypes {
            relational_key: field_name,
            mapped_entity: test_entity_string.to_capitalized_options(),
            relationship_type: "array".to_owned(),
        });
        assert_eq!(result, expect_output);
    }

    #[test]
    fn gql_type_is_optional_test() {
        let test_entity_string = String::from("TestEntity");
        let test_named_entity = Type::NamedType(test_entity_string);
        // NamedType:
        let is_optional = gql_type_is_optional(&test_named_entity);
        assert_eq!(is_optional, true);

        // ListType:
        let test_list_type = Type::ListType(Box::new(test_named_entity));
        let is_optional = gql_type_is_optional(&test_list_type);
        assert_eq!(is_optional, true);

        // NonNullType
        let gql_array_non_null_type = Type::NonNullType(Box::new(test_list_type));
        let is_optional = gql_type_is_optional(&gql_array_non_null_type);
        assert_eq!(is_optional, false);
    }
}
