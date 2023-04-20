use std::path::PathBuf;

use crate::{capitalization::Capitalize, Error, ParamType, RecordType};
use graphql_parser::schema::{Definition, Type, TypeDefinition};
use std::collections::HashSet;

pub fn get_entity_record_types_from_schema(
    schema_path: &PathBuf,
) -> Result<Vec<RecordType>, Box<dyn Error>> {
    let schema_string = std::fs::read_to_string(schema_path).map_err(|err| {
        format!(
            "Failed to read schema file at {} with Error: {}",
            schema_path.to_str().unwrap_or("unknown file"),
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
        for field in object.fields.iter() {
            let param_type = gql_type_to_rescript_type(&field.field_type, &entities_set)?;

            params.push(ParamType {
                key: field.name.to_owned(),
                type_: param_type,
            })
        }

        entity_records.push(RecordType {
            name: object.name.to_owned().to_capitalized_options(),
            params,
        })
    }
    Ok(entity_records)
}

enum NullableContainer {
    NotNullable,
    Nullable,
}

fn gql_named_types_to_rescript_types(
    named_type: &str,
    entities_set: &HashSet<String>,
) -> Result<String, String> {
    match named_type {
        "ID" => Ok("string".to_owned()),
        "String" => Ok("string".to_owned()),
        "Int" => Ok("int".to_owned()),
        "BigInt" => Ok("BigInt.t".to_owned()),
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

#[cfg(test)]
mod tests {
    use crate::entity_parsing::gql_type_to_rescript_type;
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

    // #[test]
    // fn gql_type_to_rescript_type_non_null_int() {
    //     let gql_int_type = Type::NonNullType::(Box::new(Type::NamedType(String::from("Int")::<String>)));
    //     let result = gql_type_to_rescript_type(&gql_int_type).unwrap();
    //
    //     assert_eq!(result, "int".to_owned());
    // }

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
}
