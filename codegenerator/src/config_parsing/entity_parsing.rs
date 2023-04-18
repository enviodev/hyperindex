use std::path::PathBuf;

use crate::{capitalization::Capitalize, Error, ParamType, RecordType};
use graphql_parser::schema::{Definition, Type, TypeDefinition};

pub fn get_entity_record_types_from_schema(
    schema_path: &PathBuf,
) -> Result<Vec<RecordType>, Box<dyn Error>> {
    let schema_string = std::fs::read_to_string(schema_path)
        .map_err(|err| format!("Failed to read schema file with Error: {}", err.to_string()))?;
    let schema_doc = graphql_parser::parse_schema::<String>(&schema_string)
        .map_err(|err| format!("Failed to parse schema with Error: {}", err.to_string()))?;
    let mut schema_object_types = Vec::new();

    for definition in schema_doc.definitions.iter() {
        match definition {
            Definition::SchemaDefinition(_) => (),
            Definition::TypeDefinition(def) => match def {
                TypeDefinition::Scalar(_) => (),
                TypeDefinition::Object(object) => {
                    println!("{:?}", object.name);
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
            let param_type = gql_type_to_rescript_type(&field.field_type)?;

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

fn gql_named_types_to_rescript_types(named_type: &str) -> Result<String, String> {
    match named_type {
        "ID" => Ok("string".to_owned()),
        "String" => Ok("string".to_owned()),
        "Int" => Ok("int".to_owned()),
        "BigInt" => Ok("BigInt.t".to_owned()),
        "Float" => Ok("float".to_owned()),
        "Bytes" => Ok("string".to_owned()),
        "Boolean" => Ok("bool".to_owned()),
        _ => Err("Failed to parse gql scalar".to_owned()),
    }
}

fn gql_type_to_rescript_type_with_contriner_wrapper(
    gql_type: &Type<String>,
    container_type: NullableContainer,
) -> Result<String, String> {
    let composed_type_name = match (gql_type, container_type) {
        (Type::NamedType(named), NullableContainer::NotNullable) => {
            gql_named_types_to_rescript_types(named)?
        }
        (Type::NamedType(named), NullableContainer::Nullable) => {
            format!("option<{}>", gql_named_types_to_rescript_types(named)?)
        }
        (Type::ListType(gql_type), NullableContainer::NotNullable) => format!(
            "array<{}>",
            gql_type_to_rescript_type_with_contriner_wrapper(
                &gql_type,
                NullableContainer::Nullable
            )?
        ),
        (Type::ListType(gql_type), NullableContainer::Nullable) => format!(
            "option<array<{}>>",
            gql_type_to_rescript_type_with_contriner_wrapper(
                &gql_type,
                NullableContainer::Nullable
            )?
        ),
        (Type::NonNullType(gql_type), _) => format!(
            "{}",
            gql_type_to_rescript_type_with_contriner_wrapper(
                &gql_type,
                NullableContainer::NotNullable
            )?
        ),
    };
    Ok(composed_type_name)
}

fn gql_type_to_rescript_type(gql_type: &Type<String>) -> Result<String, String> {
    gql_type_to_rescript_type_with_contriner_wrapper(gql_type, NullableContainer::Nullable)
}

#[cfg(test)]
mod tests {
    use crate::entity_parsing::gql_type_to_rescript_type;
    use graphql_parser::schema::Type;

    #[test]
    fn gql_type_to_rescript_type_string() {
        let gql_string_type = Type::NamedType("String".to_owned());
        let result = gql_type_to_rescript_type(&gql_string_type).unwrap();

        assert_eq!(result, "option<string>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_int() {
        let gql_int_type = Type::NamedType("Int".to_owned());
        let result = gql_type_to_rescript_type(&gql_int_type).unwrap();

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
        let gql_int_type = Type::NonNullType(Box::new(Type::ListType(Box::new(
            Type::NonNullType(Box::new(Type::NamedType("Int".to_owned()))),
        ))));
        let result = gql_type_to_rescript_type(&gql_int_type).unwrap();

        assert_eq!(result, "array<int>".to_owned());
    }

    #[test]
    fn gql_type_to_rescript_type_null_array_int() {
        let gql_int_type = Type::ListType(Box::new(Type::NamedType("Int".to_owned())));
        let result = gql_type_to_rescript_type(&gql_int_type).unwrap();

        assert_eq!(result, "option<array<option<int>>>".to_owned());
    }
}
