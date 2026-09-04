//! schema.graphql (subgraph flavour) -> schema.graphql (envio flavour).
//!
//! The translator owns strictness. Envio's own parser can't be leaned on for
//! the deny-unknown promise: it doesn't even require `@entity`. So the schema is
//! validated here, against a whitelist, before a clean envio schema is emitted.
//!
//! Directives are the exception: graph-node ignores one it doesn't define, and
//! subgraphs use that for documentation-only tags, so an unrecognised directive
//! is dropped rather than refused. A directive can't change what is indexed —
//! only the manifest and the field types can, and those stay strict.

use std::collections::{BTreeMap, BTreeSet};

use graphql_parser::schema::{Definition, Directive, Document, Type, TypeDefinition, Value};
use serde::Serialize;

use super::errors::Report;

/// `@entity` arguments graph-node accepts.
const KNOWN_ENTITY_ARGS: &[&str] = &["immutable", "timeseries"];

/// Scalars a subgraph schema can use, mapped to what envio stores.
fn map_scalar(name: &str) -> Option<&'static str> {
    match name {
        "ID" => Some("ID"),
        "String" => Some("String"),
        "Int" => Some("Int"),
        "Boolean" => Some("Boolean"),
        // Subgraph mode sets `bytes_type: uint8array`, so a `Bytes` column
        // holds the bytes graph-ts hands it rather than a hex rendering.
        "Bytes" => Some("Bytes"),
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
    /// Every field each entity declares. envio's store returns what a mapping
    /// wrote; graph-node's returns every column, so the shim answers `null` for
    /// a declared field the stored row doesn't carry.
    pub entity_fields: BTreeMap<String, Vec<String>>,
    /// Fields holding one entity's id. graph-ts calls the field `owner`; envio's
    /// column is `owner_id`, so the shim renames it at the store boundary.
    pub entity_ref_fields: BTreeMap<String, Vec<String>>,
    /// What each field is declared as in the *subgraph* schema, which is what a
    /// mapping expects to read back — the envio column is often a different
    /// type, and guessing from the stored value can't tell `Bytes` from
    /// `String` or `Int8` from `Int`.
    pub entity_field_types: BTreeMap<String, BTreeMap<String, FieldType>>,
}

/// A field as the subgraph schema declares it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldType {
    /// The subgraph scalar, an enum name, or `Entity` for a relation.
    pub kind: String,
    /// The entity a relation points at, so its id type can be looked up.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// The field on `target` that points back, for a `@derivedFrom` field.
    /// `store.loadRelated` names the owner and the derived field, so the query
    /// it stands for is only recoverable from here.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub derived_from: Option<String>,
    pub list: bool,
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

/// Field lines for one type, with the subgraph scalars mapped to what envio
/// stores and the conversions the shim needs recorded against `owner`.
fn render_fields(
    owner: &str,
    source: &[graphql_parser::schema::Field<'_, String>],
    entity_names: &BTreeSet<String>,
    enum_names: &BTreeSet<String>,
    translation: &mut SchemaTranslation,
    report: &mut Report,
) -> Vec<String> {
    let mut fields = Vec::new();
    let declared = translation
        .entity_fields
        .entry(owner.to_string())
        .or_default();
    for field in source {
        if !declared.contains(&field.name) {
            declared.push(field.name.clone());
        }
    }
    for field in source {
        let location = format!("schema.graphql → {}.{}", owner, field.name);

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
            }
        }

        let (base, wrappers) = unwrap_type(&field.field_type);

        translation
            .entity_field_types
            .entry(owner.to_string())
            .or_default()
            .insert(
                field.name.clone(),
                FieldType {
                    kind: if map_scalar(&base).is_some() || enum_names.contains(&base) {
                        base.clone()
                    } else {
                        "Entity".to_string()
                    },
                    target: (map_scalar(&base).is_none() && !enum_names.contains(&base))
                        .then(|| base.clone()),
                    derived_from: derived_from.clone(),
                    list: is_list(&wrappers),
                },
            );

        if let Some(derived_field) = derived_from {
            // Rendered as a list whatever the subgraph wrote. The Graph accepts
            // the one-to-one `Registration @derivedFrom(...)` and answers it
            // with the same lookup; envio only spells a derived field as a
            // list, and `graph codegen` reads one back as an array either way.
            fields.push(format!(
                "  {}: [{}!]! @derivedFrom(field: \"{}\")",
                field.name, base, derived_field
            ));
            continue;
        }

        let rendered_base = if let Some(scalar) = map_scalar(&base) {
            if field.name == "id" {
                if base == "Bytes" {
                    translation.bytes_id_entities.insert(owner.to_string());
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
                        .entry(owner.to_string())
                        .or_default()
                        .push(field.name.clone());
                }
                scalar.to_string()
            }
        } else if enum_names.contains(&base) {
            base.clone()
        } else if entity_names.contains(&base) {
            if is_list(&wrappers) {
                // A stored list of entities is a list of ids on both sides;
                // envio has no list-of-relations type.
                translation
                    .entity_list_fields
                    .entry(owner.to_string())
                    .or_default()
                    .push(field.name.clone());
                "String".to_string()
            } else {
                translation
                    .entity_ref_fields
                    .entry(owner.to_string())
                    .or_default()
                    .push(field.name.clone());
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
    fields
}

fn inherit_conversions(translation: &mut SchemaTranslation, entity: &str, interface: &str) {
    if translation.bytes_id_entities.contains(interface) {
        translation.bytes_id_entities.insert(entity.to_string());
    }
    // An implementor gets the interface's columns without restating them, so it
    // needs their declared types too — otherwise the runtime is back to
    // guessing a Bytes id from a lowercase hex string.
    if let Some(inherited) = translation.entity_field_types.get(interface).cloned() {
        let own = translation
            .entity_field_types
            .entry(entity.to_string())
            .or_default();
        for (field, field_type) in inherited {
            own.entry(field).or_insert(field_type);
        }
    }
    for map in [
        &mut translation.timestamp_fields,
        &mut translation.entity_list_fields,
        &mut translation.entity_fields,
        &mut translation.entity_ref_fields,
    ] {
        let Some(inherited) = map.get(interface).cloned() else {
            continue;
        };
        let own = map.entry(entity.to_string()).or_default();
        for field in inherited {
            if !own.contains(&field) {
                own.push(field);
            }
        }
    }
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
            // An interface names a shape shared by entities, so a field may
            // point at it the same way it points at an entity.
            Definition::TypeDefinition(TypeDefinition::Interface(interface)) => {
                entity_names.insert(interface.name.clone());
            }
            Definition::TypeDefinition(TypeDefinition::Enum(enum_type)) => {
                enum_names.insert(enum_type.name.clone());
            }
            _ => {}
        }
    }

    let mut out = String::new();
    let mut implementors: Vec<(String, Vec<String>)> = Vec::new();

    for definition in &document.definitions {
        match definition {
            // The interface carries no table of its own — the entity parser
            // folds it into each implementor — but its fields go through the
            // same scalar mapping on the way there.
            Definition::TypeDefinition(TypeDefinition::Interface(interface)) => {
                let fields = render_fields(
                    &interface.name,
                    &interface.fields,
                    &entity_names,
                    &enum_names,
                    &mut translation,
                    report,
                );
                out.push_str(&format!(
                    "interface {} {{\n{}\n}}\n\n",
                    interface.name,
                    fields.join("\n")
                ));
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
                        format!(
                            "schema.graphql → type {} @entity(timeseries: true)",
                            object.name
                        ),
                    );
                }
                // `immutable: true` is validated and dropped: graph-node's
                // write-once check only ever fires for mappings that are
                // already broken, so a working subgraph loses nothing.

                let fields = render_fields(
                    &object.name,
                    &object.fields,
                    &entity_names,
                    &enum_names,
                    &mut translation,
                    report,
                );

                implementors.push((object.name.clone(), object.implements_interfaces.clone()));

                let implements = if object.implements_interfaces.is_empty() {
                    String::new()
                } else {
                    format!(" implements {}", object.implements_interfaces.join(" & "))
                };

                out.push_str(&format!(
                    "type {}{} {{\n{}\n}}\n\n",
                    object.name,
                    implements,
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
            Definition::DirectiveDefinition(_) => {}
            Definition::SchemaDefinition(_) | Definition::TypeExtension(_) => {}
        }
    }

    // The shim's conversions are keyed by entity, and a field the entity
    // inherits rather than restates is still its field. Applied after the walk
    // so the interface need not be declared before its implementors.
    for (entity, interfaces) in &implementors {
        for interface in interfaces {
            inherit_conversions(&mut translation, entity, interface);
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
                translation
                    .bytes_id_entities
                    .iter()
                    .cloned()
                    .collect::<Vec<_>>(),
                translation.timestamp_fields.get("Gravatar").cloned(),
                translation.entity_list_fields.get("Account").cloned(),
            ),
            (
                "type Gravatar {\n  \
                   id: String!\n  \
                   owner: Bytes!\n  \
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

    // The Graph answers a derived field with the same lookup however it is
    // written, and `graph codegen` reads it back as an array either way, so the
    // one-to-one `Registration @derivedFrom(...)` the ENS subgraph uses is
    // emitted as the list envio spells a derived field with.
    #[test]
    fn renders_a_one_to_one_derived_field_as_a_list() {
        let (translation, report) = translate_ok(
            r#"
type Domain @entity {
  id: ID!
  registration: Registration @derivedFrom(field: "domain")
  transfers: [Transfer!]! @derivedFrom(field: "domain")
}

type Registration @entity {
  id: ID!
  domain: Domain!
}

type Transfer @entity {
  id: ID!
  domain: Domain!
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            (
                translation.text.as_str(),
                translation
                    .entity_field_types
                    .get("Domain")
                    .and_then(|fields| fields.get("registration"))
                    .cloned(),
            ),
            (
                "type Domain {\n  \
                   id: ID!\n  \
                   registration: [Registration!]! @derivedFrom(field: \"domain\")\n  \
                   transfers: [Transfer!]! @derivedFrom(field: \"domain\")\n\
                 }\n\n\
                 type Registration {\n  \
                   id: ID!\n  \
                   domain: Domain!\n\
                 }\n\n\
                 type Transfer {\n  \
                   id: ID!\n  \
                   domain: Domain!\n\
                 }",
                // The reverse field is what `store.loadRelated` needs and the
                // manifest never states; only the schema carries it.
                Some(FieldType {
                    kind: "Entity".to_string(),
                    target: Some("Registration".to_string()),
                    derived_from: Some("domain".to_string()),
                    list: false,
                }),
            )
        );
    }

    // Carried through for the entity parser to fold into each implementor; the
    // subgraph scalars still have to be mapped on the way.
    #[test]
    fn carries_interfaces_through_with_their_scalars_mapped() {
        let (translation, report) = translate_ok(
            r#"
interface DomainEvent {
  id: ID!
  domain: Domain!
  txHash: Bytes!
}

type Domain @entity {
  id: ID!
  events: [DomainEvent!]! @derivedFrom(field: "domain")
}

type Transfer implements DomainEvent @entity {
  id: ID!
  domain: Domain!
  txHash: Bytes!
  owner: Bytes!
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            translation.text.as_str(),
            "interface DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain!\n  \
               txHash: Bytes!\n\
             }\n\n\
             type Domain {\n  \
               id: ID!\n  \
               events: [DomainEvent!]! @derivedFrom(field: \"domain\")\n\
             }\n\n\
             type Transfer implements DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain!\n  \
               txHash: Bytes!\n  \
               owner: Bytes!\n\
             }"
        );
    }

    // graph-node ignores a directive it doesn't define, so subgraphs carry
    // documentation-only ones — Messari tags every entity with @dailySnapshot
    // and @regularPolling. Refusing them refuses a comment.
    #[test]
    fn ignores_schema_directives_graph_node_ignores() {
        let (translation, report) = translate_ok(
            r#"
type Token @entity @regularPolling {
  id: ID!
  total: BigInt! @colour(value: "blue")
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            translation.text.as_str(),
            "type Token {\n  id: ID!\n  total: BigInt!\n}"
        );
    }

    #[test]
    fn refuses_timeseries_and_unknowns() {
        let (_, report) = translate_ok(
            r#"
type Stats @entity(timeseries: true) {
  id: Int8!
  amount: BigInt!
}

type Loose {
  id: ID!
}

type Odd @entity {
  id: ID!
  missing: NotAType!
}
"#,
        );
        let rendered = report.to_string();
        assert_eq!(
            (
                rendered.contains("doesn't support timeseries and aggregations"),
                rendered.contains("doesn't know the object type Loose without @entity"),
                rendered.contains("doesn't know the type NotAType"),
            ),
            (true, true, true)
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
