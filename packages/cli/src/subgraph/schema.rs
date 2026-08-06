//! schema.graphql (subgraph flavour) -> schema.graphql (envio flavour).
//!
//! The translator owns strictness. Envio's own parser can't be leaned on for
//! the deny-unknown promise: it ignores unrecognised directives and doesn't even
//! require `@entity`. So everything is validated here, against a whitelist,
//! before a clean envio schema is emitted.

use std::collections::{BTreeMap, BTreeSet};

use graphql_parser::schema::{Definition, Directive, Document, Type, TypeDefinition, Value};

use super::errors::Report;

/// Directives a subgraph schema may carry. Anything else is a typo or newer
/// than this translator.
const KNOWN_TYPE_DIRECTIVES: &[&str] = &["entity", "aggregation", "fulltext", "subgraphId"];
const KNOWN_FIELD_DIRECTIVES: &[&str] = &["derivedFrom", "aggregate"];

/// `@entity` arguments graph-node accepts.
const KNOWN_ENTITY_ARGS: &[&str] = &["immutable", "timeseries"];

/// Scalars a subgraph schema can use, mapped to what envio stores.
fn map_scalar(name: &str) -> Option<&'static str> {
    match name {
        "ID" => Some("ID"),
        "String" => Some("String"),
        "Int" => Some("Int"),
        "Boolean" => Some("Boolean"),
        "Bytes" => Some("String"),
        "BigInt" => Some("BigInt"),
        "BigDecimal" => Some("BigDecimal"),
        // 64-bit in AssemblyScript; envio's Int is 32-bit and JS numbers are
        // only safe to 2^53, so BigInt is the lossless fit.
        "Int8" => Some("BigInt"),
        "Timestamp" => Some("Timestamp"),
        _ => None,
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SchemaTranslation {
    /// The envio schema text, ready to hand to the normal entity parser.
    #[serde(skip)]
    pub text: String,
    /// Fields the shim converts between graph-ts' i64 microseconds and the
    /// stored timestamp, keyed by entity name.
    pub timestamp_fields: BTreeMap<String, Vec<String>>,
    /// Entities whose `id` is declared `Bytes`: the shim lowercases and hexes
    /// their ids at the store boundary.
    pub bytes_id_entities: BTreeSet<String>,
    /// Fields holding a list of entity ids, which graph-ts sees as `[String]`.
    pub entity_list_fields: BTreeMap<String, Vec<String>>,
}

fn directive_name<'a, 'b>(directive: &'a Directive<'b, String>) -> &'a str {
    directive.name.as_str()
}

fn bool_arg(directive: &Directive<'_, String>, name: &str) -> Option<bool> {
    directive.arguments.iter().find_map(|(key, value)| {
        if key == name {
            match value {
                Value::Boolean(b) => Some(*b),
                _ => None,
            }
        } else {
            None
        }
    })
}

/// Strips wrappers down to the innermost named type, remembering how to put
/// them back.
fn unwrap_type(ty: &Type<'_, String>) -> (String, Vec<Wrapper>) {
    let mut wrappers = Vec::new();
    let mut current = ty;
    loop {
        match current {
            Type::NamedType(name) => return (name.clone(), wrappers),
            Type::NonNullType(inner) => {
                wrappers.push(Wrapper::NonNull);
                current = inner;
            }
            Type::ListType(inner) => {
                wrappers.push(Wrapper::List);
                current = inner;
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Wrapper {
    NonNull,
    List,
}

fn render_type(base: &str, wrappers: &[Wrapper]) -> String {
    let mut rendered = base.to_string();
    for wrapper in wrappers.iter().rev() {
        rendered = match wrapper {
            Wrapper::NonNull => format!("{rendered}!"),
            Wrapper::List => format!("[{rendered}]"),
        };
    }
    rendered
}

fn is_list(wrappers: &[Wrapper]) -> bool {
    wrappers.contains(&Wrapper::List)
}

/// Translates a subgraph schema, reporting everything it refuses.
pub fn translate(schema_text: &str, report: &mut Report) -> SchemaTranslation {
    let document: Document<'_, String> = match graphql_parser::parse_schema(schema_text) {
        Ok(document) => document,
        Err(err) => {
            report.unknown(
                format!("how to read schema.graphql: {err}"),
                "schema.graphql",
            );
            return SchemaTranslation::default();
        }
    };

    let mut translation = SchemaTranslation::default();

    // Object types are also the set of valid field target types, so collect
    // them before emitting anything.
    let mut entity_names = BTreeSet::new();
    let mut enum_names = BTreeSet::new();
    for definition in &document.definitions {
        match definition {
            Definition::TypeDefinition(TypeDefinition::Object(object)) => {
                entity_names.insert(object.name.clone());
            }
            Definition::TypeDefinition(TypeDefinition::Enum(enum_type)) => {
                enum_names.insert(enum_type.name.clone());
            }
            _ => {}
        }
    }

    let mut out = String::new();

    for definition in &document.definitions {
        match definition {
            Definition::TypeDefinition(TypeDefinition::Interface(interface)) => {
                report.unsupported(
                    "GraphQL interfaces",
                    format!("schema.graphql → interface {}", interface.name),
                );
            }
            Definition::TypeDefinition(TypeDefinition::Enum(enum_type)) => {
                let variants: Vec<&str> = enum_type
                    .values
                    .iter()
                    .map(|value| value.name.as_str())
                    .collect();
                out.push_str(&format!(
                    "enum {} {{\n  {}\n}}\n\n",
                    enum_type.name,
                    variants.join("\n  ")
                ));
            }
            Definition::TypeDefinition(TypeDefinition::Object(object)) => {
                // graph-node's full-text search declaration hangs off a dummy
                // type; it carries no entity of its own.
                if object.name == "_Schema_" {
                    continue;
                }

                for directive in &object.directives {
                    let name = directive_name(directive);
                    if name == "aggregation" {
                        report.unsupported(
                            "timeseries and aggregations",
                            format!("schema.graphql → type {} @aggregation", object.name),
                        );
                    } else if !KNOWN_TYPE_DIRECTIVES.contains(&name) {
                        report.unknown(
                            format!("the schema directive @{name}"),
                            format!("schema.graphql → type {}", object.name),
                        );
                    }
                }

                let Some(entity) = object
                    .directives
                    .iter()
                    .find(|d| directive_name(d) == "entity")
                else {
                    report.unknown(
                        format!("the object type {} without @entity", object.name),
                        format!("schema.graphql → type {}", object.name),
                    );
                    continue;
                };

                for (arg, _) in &entity.arguments {
                    if !KNOWN_ENTITY_ARGS.contains(&arg.as_str()) {
                        report.unknown(
                            format!("the @entity argument \"{arg}\""),
                            format!("schema.graphql → type {}", object.name),
                        );
                    }
                }
                if bool_arg(entity, "timeseries") == Some(true) {
                    report.unsupported(
                        "timeseries and aggregations",
                        format!("schema.graphql → type {} @entity(timeseries: true)", object.name),
                    );
                }
                // `immutable: true` is validated and dropped: graph-node's
                // write-once check only ever fires for mappings that are
                // already broken, so a working subgraph loses nothing.

                if !object.implements_interfaces.is_empty() {
                    report.unsupported(
                        "GraphQL interfaces",
                        format!(
                            "schema.graphql → type {} implements {}",
                            object.name,
                            object.implements_interfaces.join(", ")
                        ),
                    );
                }

                let mut fields = Vec::new();
                for field in &object.fields {
                    let location = format!("schema.graphql → {}.{}", object.name, field.name);

                    let mut derived_from = None;
                    for directive in &field.directives {
                        let name = directive_name(directive);
                        if name == "derivedFrom" {
                            derived_from = directive.arguments.iter().find_map(|(key, value)| {
                                match (key.as_str(), value) {
                                    ("field", Value::String(field)) => Some(field.clone()),
                                    _ => None,
                                }
                            });
                            for (arg, _) in &directive.arguments {
                                if arg != "field" {
                                    report.unknown(
                                        format!("the @derivedFrom argument \"{arg}\""),
                                        location.clone(),
                                    );
                                }
                            }
                        } else if !KNOWN_FIELD_DIRECTIVES.contains(&name) {
                            report.unknown(
                                format!("the schema directive @{name}"),
                                location.clone(),
                            );
                        }
                    }

                    let (base, wrappers) = unwrap_type(&field.field_type);

                    if let Some(derived_field) = derived_from {
                        fields.push(format!(
                            "  {}: {} @derivedFrom(field: \"{}\")",
                            field.name,
                            render_type(&base, &wrappers),
                            derived_field
                        ));
                        continue;
                    }

                    let rendered_base = if let Some(scalar) = map_scalar(&base) {
                        if field.name == "id" {
                            if base == "Bytes" {
                                translation.bytes_id_entities.insert(object.name.clone());
                            }
                            // envio only allows ID/String/Int/BigInt ids.
                            match scalar {
                                "ID" | "String" | "Int" | "BigInt" => scalar.to_string(),
                                _ => "String".to_string(),
                            }
                        } else {
                            if base == "Timestamp" {
                                translation
                                    .timestamp_fields
                                    .entry(object.name.clone())
                                    .or_default()
                                    .push(field.name.clone());
                            }
                            scalar.to_string()
                        }
                    } else if enum_names.contains(&base) {
                        base.clone()
                    } else if entity_names.contains(&base) {
                        if is_list(&wrappers) {
                            // A stored list of entities is a list of ids on
                            // both sides; envio has no list-of-relations type.
                            translation
                                .entity_list_fields
                                .entry(object.name.clone())
                                .or_default()
                                .push(field.name.clone());
                            "String".to_string()
                        } else {
                            base.clone()
                        }
                    } else {
                        report.unknown(format!("the type {base}"), location.clone());
                        continue;
                    };

                    fields.push(format!(
                        "  {}: {}",
                        field.name,
                        render_type(&rendered_base, &wrappers)
                    ));
                }

                out.push_str(&format!(
                    "type {} {{\n{}\n}}\n\n",
                    object.name,
                    fields.join("\n")
                ));
            }
            Definition::TypeDefinition(TypeDefinition::Scalar(scalar)) => {
                // graph-node predeclares its own scalars; a project redeclaring
                // one is fine, anything else is unknown.
                if map_scalar(&scalar.name).is_none() {
                    report.unknown(
                        format!("the scalar {}", scalar.name),
                        format!("schema.graphql → scalar {}", scalar.name),
                    );
                }
            }
            Definition::TypeDefinition(TypeDefinition::Union(union_type)) => {
                report.unsupported(
                    "GraphQL unions",
                    format!("schema.graphql → union {}", union_type.name),
                );
            }
            Definition::TypeDefinition(TypeDefinition::InputObject(input)) => {
                report.unknown(
                    format!("the input type {}", input.name),
                    format!("schema.graphql → input {}", input.name),
                );
            }
            Definition::DirectiveDefinition(directive) => {
                if !KNOWN_TYPE_DIRECTIVES.contains(&directive.name.as_str())
                    && !KNOWN_FIELD_DIRECTIVES.contains(&directive.name.as_str())
                {
                    report.unknown(
                        format!("the schema directive @{}", directive.name),
                        "schema.graphql",
                    );
                }
            }
            Definition::SchemaDefinition(_) | Definition::TypeExtension(_) => {}
        }
    }

    translation.text = out.trim_end().to_string();
    translation
}

#[cfg(test)]
mod tests {
    use super::*;

    fn translate_ok(schema: &str) -> (SchemaTranslation, Report) {
        let mut report = Report::new();
        let translation = translate(schema, &mut report);
        (translation, report)
    }

    #[test]
    fn rewrites_subgraph_scalars() {
        let (translation, report) = translate_ok(
            r#"
type Gravatar @entity(immutable: true) {
  id: Bytes!
  owner: Bytes!
  displayName: String!
  score: Int8!
  createdAt: Timestamp!
  imageUrl: String
}

type Account @entity {
  id: ID!
  gravatars: [Gravatar!]! @derivedFrom(field: "owner")
  favourites: [Gravatar!]!
  status: Status!
}

enum Status {
  Active
  Frozen
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            (
                translation.text.as_str(),
                translation.bytes_id_entities.iter().cloned().collect::<Vec<_>>(),
                translation.timestamp_fields.get("Gravatar").cloned(),
                translation.entity_list_fields.get("Account").cloned(),
            ),
            (
                "type Gravatar {\n  \
                   id: String!\n  \
                   owner: String!\n  \
                   displayName: String!\n  \
                   score: BigInt!\n  \
                   createdAt: Timestamp!\n  \
                   imageUrl: String\n\
                 }\n\n\
                 type Account {\n  \
                   id: ID!\n  \
                   gravatars: [Gravatar!]! @derivedFrom(field: \"owner\")\n  \
                   favourites: [String!]!\n  \
                   status: Status!\n\
                 }\n\n\
                 enum Status {\n  Active\n  Frozen\n}",
                vec!["Gravatar".to_string()],
                Some(vec!["createdAt".to_string()]),
                Some(vec!["favourites".to_string()]),
            )
        );
    }

    #[test]
    fn refuses_interfaces_timeseries_and_unknowns() {
        let (_, report) = translate_ok(
            r#"
interface Named {
  id: ID!
}

type Token implements Named @entity {
  id: ID!
  name: String!
}

type Stats @entity(timeseries: true) {
  id: Int8!
  amount: BigInt!
}

type Loose {
  id: ID!
}

type Odd @entity {
  id: ID!
  weird: String! @secretIndex
  missing: NotAType!
}
"#,
        );
        let rendered = report.to_string();
        assert_eq!(
            (
                rendered.contains("doesn't support GraphQL interfaces"),
                rendered.contains("type Token implements Named"),
                rendered.contains("doesn't support timeseries and aggregations"),
                rendered.contains("doesn't know the object type Loose without @entity"),
                rendered.contains("doesn't know the schema directive @secretIndex"),
                rendered.contains("doesn't know the type NotAType"),
            ),
            (true, true, true, true, true, true)
        );
    }

    #[test]
    fn rejects_unknown_entity_arguments() {
        let (_, report) = translate_ok(
            r#"
type Token @entity(immutable: true, sharded: true) {
  id: ID!
}
"#,
        );
        assert!(
            report
                .to_string()
                .contains("doesn't know the @entity argument \"sharded\""),
            "{report}"
        );
    }
}
