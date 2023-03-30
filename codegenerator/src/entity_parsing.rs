use crate::CURRENT_DIR_PATH;
use graphql_parser::schema::{Definition, Type, TypeDefinition};

pub fn get_entity_types_from_schema() {
    let schema_path = format!("{}/{}", CURRENT_DIR_PATH, "schema.graphql");
    let schema_string = std::fs::read_to_string(schema_path).expect("failed to read schema file");
    let schema_doc =
        graphql_parser::parse_schema::<String>(&schema_string).expect("failed to parse");
    for definition in schema_doc.definitions.iter() {
        let def = match definition {
            Definition::SchemaDefinition(_) => "schema def",
            Definition::TypeDefinition(def) => match def {
                TypeDefinition::Scalar(_) => "Scalar",
                TypeDefinition::Object(object) => {
                    println!("{:?}", object.name);
                    let _fields = object
                        .fields
                        .iter()
                        .map(|field| {
                            let field_type = gql_type_to_rescript_type(&field.field_type).unwrap();
                            let field = format!("{} : {}", field.name.to_owned(), field_type);
                            println!("{field}");
                            field
                        })
                        .collect::<String>();

                    "Object"
                }
                TypeDefinition::Interface(_) => "Interface",
                TypeDefinition::Union(_) => "Union",
                TypeDefinition::Enum(_) => "Enum",
                TypeDefinition::InputObject(_) => "InputObj",
            },
            Definition::DirectiveDefinition(_) => "directives def",
            Definition::TypeExtension(_) => " type extension",
        };
        println!("{:?}", def);
    }
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
    use crate::entity_parsing::get_entity_types_from_schema;
    #[test]
    fn gql_parse() {
        get_entity_types_from_schema()
    }
}
