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
    /// `@entity(timeseries: true)` types. The runtime stamps each save with the
    /// block's timestamp and an auto-generated, increasing `Int8` id.
    pub timeseries_entities: BTreeSet<String>,
    /// `@aggregation` types, rolled up by the runtime into one entity per
    /// interval, named `<Aggregation>_<interval>`.
    pub aggregations: Vec<Aggregation>,
    /// Derived fields that list an aggregation's rows (`stats: [Stat!]
    /// @derivedFrom(field: "pool")`), by owning entity. envio has no table for
    /// the aggregation under that name, so they are not part of the entity;
    /// a query answers them from the `<Aggregation>_<interval>` tables.
    pub aggregation_derived_fields: BTreeMap<String, Vec<AggregationDerivedField>>,
    #[serde(skip)]
    aggregation_names: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AggregationDerivedField {
    pub field: String,
    pub aggregation: String,
    /// The dimension of the aggregation that points back at the owner.
    pub via: String,
}

/// An `@aggregation(intervals: [...], source: "...")` type.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Aggregation {
    pub name: String,
    /// The timeseries entity the aggregates are computed over.
    pub source: String,
    /// `hour` and/or `day`.
    pub intervals: Vec<String>,
    /// Fields without `@aggregate`: the group key, copied from the source row.
    pub dimensions: Vec<AggregationDimension>,
    pub aggregates: Vec<Aggregate>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AggregationDimension {
    pub field: String,
    /// The column holding it: `<field>_id` for a relation, else the field.
    pub column: String,
}

/// One `@aggregate(fn: ..., arg: ..., cumulative: ...)` field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Aggregate {
    pub field: String,
    /// `sum`, `count`, `min`, `max`, `first` or `last`.
    pub func: String,
    /// A source field or a SQL expression over source fields. `count` needs none.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub arg: Option<String>,
    pub cumulative: bool,
    /// The declared scalar: `Int`, `Int8`, `BigInt` or `BigDecimal`.
    pub kind: String,
}

/// The interval names `@aggregation` accepts.
pub const AGGREGATION_INTERVALS: &[&str] = &["hour", "day"];
const AGGREGATE_FUNCTIONS: &[&str] = &["sum", "count", "min", "max", "first", "last"];
/// The envio entity that holds the rollup bookkeeping (see the runtime).
pub const ROLLUP_STATE_ENTITY: &str = "EnvioSubgraphRollup";

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

fn string_arg(directive: &Directive<'_, String>, name: &str) -> Option<String> {
    directive
        .arguments
        .iter()
        .find_map(|(key, value)| match value {
            Value::String(s) if key == name => Some(s.clone()),
            _ => None,
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

fn non_null_elements(wrappers: &[Wrapper]) -> Vec<Wrapper> {
    let mut out = Vec::with_capacity(wrappers.len() + 1);
    for (index, wrapper) in wrappers.iter().enumerate() {
        out.push(*wrapper);
        if *wrapper == Wrapper::List && wrappers.get(index + 1) != Some(&Wrapper::NonNull) {
            out.push(Wrapper::NonNull);
        }
    }
    out
}

/// A list graph-node stores and envio's store can't, as the feature to report.
fn unstorable_list(base: &str, wrappers: &[Wrapper]) -> Option<&'static str> {
    let nullable_element = wrappers.iter().enumerate().any(|(index, wrapper)| {
        *wrapper == Wrapper::List && wrappers.get(index + 1) != Some(&Wrapper::NonNull)
    });
    if nullable_element {
        Some("lists whose elements can be null, like [String]")
    } else if is_list(wrappers) && base == "Timestamp" {
        Some("lists of Timestamp")
    } else {
        None
    }
}

/// The envio scalar an id of this subgraph type is stored as.
fn id_scalar(base: &str) -> &'static str {
    match map_scalar(base) {
        Some(scalar @ ("Int" | "BigInt")) => scalar,
        _ => "String",
    }
}

/// What the schema's interfaces resolve to, collected before any field is
/// rendered.
///
/// graph-node stores a field typed as an interface as the referenced entity's
/// id, and finds the entity by looking that id up in every implementor. With
/// one implementor that is a plain relation to it. With several there is no one
/// table to relate to, so the column holds the id alone — under the `_id` name
/// a relation's column gets, which is where graph-node consumers look for it.
#[derive(Default)]
struct Interfaces {
    /// The only entity implementing each interface that has exactly one.
    sole_implementor: BTreeMap<String, String>,
    /// The id type of each interface with several (or no) implementors.
    shared_id_type: BTreeMap<String, String>,
    /// Per type, the stored fields typed as one of those shared interfaces.
    /// A `@derivedFrom` naming one has to name its id column instead.
    id_only_fields: BTreeMap<String, BTreeSet<String>>,
}

impl Interfaces {
    fn collect(document: &Document<'_, String>) -> Self {
        let mut implementors: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut id_types: BTreeMap<String, String> = BTreeMap::new();
        let mut types: Vec<(&str, &[graphql_parser::schema::Field<'_, String>])> = Vec::new();
        for definition in &document.definitions {
            match definition {
                Definition::TypeDefinition(TypeDefinition::Interface(interface)) => {
                    implementors.entry(interface.name.clone()).or_default();
                    let id_type = interface
                        .fields
                        .iter()
                        .find(|field| field.name == "id")
                        .map(|field| unwrap_type(&field.field_type).0)
                        .unwrap_or_else(|| "ID".to_string());
                    id_types.insert(interface.name.clone(), id_type);
                    types.push((&interface.name, &interface.fields));
                }
                Definition::TypeDefinition(TypeDefinition::Object(object)) => {
                    for interface in &object.implements_interfaces {
                        implementors
                            .entry(interface.clone())
                            .or_default()
                            .push(object.name.clone());
                    }
                    types.push((&object.name, &object.fields));
                }
                _ => {}
            }
        }

        let mut interfaces = Interfaces::default();
        for (interface, entities) in implementors {
            match entities.as_slice() {
                [only] => {
                    interfaces.sole_implementor.insert(interface, only.clone());
                }
                _ => {
                    let id_type = id_types.remove(&interface).unwrap_or_else(|| "ID".into());
                    interfaces.shared_id_type.insert(interface, id_type);
                }
            }
        }
        for (owner, fields) in types {
            for field in fields {
                let (base, wrappers) = unwrap_type(&field.field_type);
                let derived = field
                    .directives
                    .iter()
                    .any(|directive| directive.name == "derivedFrom");
                if !derived && !is_list(&wrappers) && interfaces.shared_id_type.contains_key(&base)
                {
                    interfaces
                        .id_only_fields
                        .entry(owner.to_string())
                        .or_default()
                        .insert(field.name.clone());
                }
            }
        }
        interfaces
    }

    /// The type a field names, with a single-implementor interface replaced by
    /// its implementor.
    fn resolve(&self, base: String) -> String {
        self.sole_implementor.get(&base).cloned().unwrap_or(base)
    }

    fn is_id_only(&self, owner: &str, field: &str) -> bool {
        self.id_only_fields
            .get(owner)
            .is_some_and(|fields| fields.contains(field))
    }
}

/// Field lines for one type, with the subgraph scalars mapped to what envio
/// stores and the conversions the shim needs recorded against `owner`.
fn render_fields(
    owner: &str,
    source: &[graphql_parser::schema::Field<'_, String>],
    entity_names: &BTreeSet<String>,
    enum_names: &BTreeSet<String>,
    interfaces: &Interfaces,
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
        let base = interfaces.resolve(base);

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
            if translation.aggregation_names.contains(&base) {
                translation
                    .aggregation_derived_fields
                    .entry(owner.to_string())
                    .or_default()
                    .push(AggregationDerivedField {
                        field: field.name.clone(),
                        aggregation: base,
                        via: derived_field,
                    });
                continue;
            }
            let column = if interfaces.is_id_only(&base, &derived_field) {
                format!("{derived_field}_id")
            } else {
                derived_field
            };
            // Rendered as a list whatever the subgraph wrote. The Graph accepts
            // the one-to-one `Registration @derivedFrom(...)` and answers it
            // with the same lookup; envio only spells a derived field as a
            // list, and `graph codegen` reads one back as an array either way.
            fields.push(format!(
                "  {}: [{}!]! @derivedFrom(field: \"{}\")",
                field.name, base, column
            ));
            continue;
        }

        if interfaces.is_id_only(owner, &field.name) {
            translation
                .entity_ref_fields
                .entry(owner.to_string())
                .or_default()
                .push(field.name.clone());
            let id_type = interfaces
                .shared_id_type
                .get(&base)
                .map(String::as_str)
                .unwrap_or("ID");
            fields.push(format!(
                "  {}_id: {}{RELATION_INDEX}",
                field.name,
                render_type(id_scalar(id_type), &wrappers)
            ));
            continue;
        }

        // The original Uniswap v2 schema, and most of its forks, declare
        // `mints: [Mint]!`. A list of entities holds their ids, which a mapping
        // never leaves null, so its elements are stored as the ids they are.
        let wrappers = if entity_names.contains(&base) {
            non_null_elements(&wrappers)
        } else {
            wrappers
        };

        if let Some(shape) = unstorable_list(&base, &wrappers) {
            report.unsupported(shape, location.clone());
            continue;
        }

        let mut indexed = false;
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
                indexed = true;
                base.clone()
            }
        } else {
            report.unknown(format!("the type {base}"), location.clone());
            continue;
        };

        fields.push(format!(
            "  {}: {}{}",
            field.name,
            render_type(&rendered_base, &wrappers),
            if indexed { RELATION_INDEX } else { "" }
        ));
    }
    fields
}

/// graph-node indexes every column (relational/ddl.rs, `add_attribute_indexes`).
/// A relation's is the one a Graph query can't do without: a nested selection,
/// a `where` on it and every `@derivedFrom` lookup join on it, and without an
/// index each is a scan of the whole table. The rest stay unindexed, as every
/// index slows the backfill's writes.
const RELATION_INDEX: &str = " @index";

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
    let interfaces = Interfaces::collect(&document);

    // Object types are also the set of valid field target types, so collect
    // them before emitting anything.
    let mut entity_names = BTreeSet::new();
    let mut enum_names = BTreeSet::new();
    for definition in &document.definitions {
        match definition {
            Definition::TypeDefinition(TypeDefinition::Object(object)) => {
                entity_names.insert(object.name.clone());
                if object
                    .directives
                    .iter()
                    .any(|d| directive_name(d) == "aggregation")
                {
                    translation.aggregation_names.insert(object.name.clone());
                }
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
    let mut aggregation_defs: Vec<(
        &graphql_parser::schema::ObjectType<'_, String>,
        &Directive<'_, String>,
    )> = Vec::new();

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
                    &interfaces,
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

                if let Some(aggregation) = object
                    .directives
                    .iter()
                    .find(|d| directive_name(d) == "aggregation")
                {
                    aggregation_defs.push((object, aggregation));
                    continue;
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
                let timeseries = bool_arg(entity, "timeseries") == Some(true);
                if timeseries {
                    check_timeseries(object, report);
                    translation.timeseries_entities.insert(object.name.clone());
                }
                // `immutable: true` is validated and dropped: graph-node's
                // write-once check only ever fires for mappings that are
                // already broken, so a working subgraph loses nothing.

                let mut fields = render_fields(
                    &object.name,
                    &object.fields,
                    &entity_names,
                    &enum_names,
                    &interfaces,
                    &mut translation,
                    report,
                );
                if timeseries {
                    index_timestamp(&mut fields);
                }

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

    for (object, directive) in aggregation_defs {
        translate_aggregation(
            object,
            directive,
            &entity_names,
            &enum_names,
            &mut translation,
            &mut out,
            report,
        );
    }
    if !translation.aggregations.is_empty() {
        out.push_str(&format!(
            "type {ROLLUP_STATE_ENTITY} {{\n  id: ID!\n  payload: String!\n}}\n\n"
        ));
    }

    translation.text = out.trim_end().to_string();
    translation
}

/// graph-node's timeseries rules: an `Int8` id and a `Timestamp`.
fn check_timeseries(object: &graphql_parser::schema::ObjectType<'_, String>, report: &mut Report) {
    let location = format!("schema.graphql → type {}", object.name);
    let declared = |name: &str| {
        object
            .fields
            .iter()
            .find(|f| f.name == name)
            .map(|f| unwrap_type(&f.field_type).0)
    };
    match declared("id").as_deref() {
        Some("Int8") => {}
        Some(other) => report.unsupported(
            format!("a timeseries with an {other} id (graph-node generates Int8 ids)"),
            location.clone(),
        ),
        None => report.unknown(
            format!("the timeseries {} without an id", object.name),
            location.clone(),
        ),
    }
    if declared("timestamp").as_deref() != Some("Timestamp") {
        report.unknown(
            format!(
                "the timeseries {} without a Timestamp `timestamp` field",
                object.name
            ),
            location,
        );
    }
}

/// The rollup and `@aggregation` queries both range-scan by `timestamp`.
fn index_timestamp(fields: &mut [String]) {
    for field in fields.iter_mut() {
        if field.starts_with("  timestamp: ") && !field.contains("@index") {
            field.push_str(" @index");
        }
    }
}

fn translate_aggregation(
    object: &graphql_parser::schema::ObjectType<'_, String>,
    directive: &Directive<'_, String>,
    entity_names: &BTreeSet<String>,
    enum_names: &BTreeSet<String>,
    translation: &mut SchemaTranslation,
    out: &mut String,
    report: &mut Report,
) {
    let location = format!("schema.graphql → type {} @aggregation", object.name);
    let source = string_arg(directive, "source");
    let mut intervals = Vec::new();
    for (key, value) in &directive.arguments {
        match (key.as_str(), value) {
            ("source", _) => {}
            ("intervals", Value::List(items)) => {
                for item in items {
                    match item {
                        Value::String(name) if AGGREGATION_INTERVALS.contains(&name.as_str()) => {
                            if !intervals.contains(name) {
                                intervals.push(name.clone());
                            }
                        }
                        Value::String(name) => report.unknown(
                            format!("the aggregation interval \"{name}\""),
                            location.clone(),
                        ),
                        _ => report.unknown("an aggregation interval", location.clone()),
                    }
                }
            }
            (other, _) => report.unknown(
                format!("the @aggregation argument \"{other}\""),
                location.clone(),
            ),
        }
    }
    let Some(source) = source else {
        report.unknown(
            format!("the aggregation {} without a source", object.name),
            location,
        );
        return;
    };
    if intervals.is_empty() {
        report.unknown(
            format!("the aggregation {} without intervals", object.name),
            location,
        );
        return;
    }
    if !translation.timeseries_entities.contains(&source) {
        report.unknown(
            format!(
                "the aggregation source {source} (it must be an @entity(timeseries: true) type)"
            ),
            location,
        );
        return;
    }

    let mut dimensions = Vec::new();
    let mut aggregates = Vec::new();
    for field in &object.fields {
        if field.name == "id" || field.name == "timestamp" {
            continue;
        }
        let field_location = format!("schema.graphql → {}.{}", object.name, field.name);
        let (base, wrappers) = unwrap_type(&field.field_type);
        let Some(aggregate) = field
            .directives
            .iter()
            .find(|d| directive_name(d) == "aggregate")
        else {
            let is_ref = entity_names.contains(&base) && !is_list(&wrappers);
            dimensions.push(AggregationDimension {
                field: field.name.clone(),
                column: if is_ref {
                    format!("{}_id", field.name)
                } else {
                    field.name.clone()
                },
            });
            continue;
        };
        if !["Int", "Int8", "BigInt", "BigDecimal"].contains(&base.as_str()) || is_list(&wrappers) {
            report.unknown(
                format!("an aggregate of type {base} (graph-node takes Int, Int8, BigInt or BigDecimal)"),
                field_location.clone(),
            );
            continue;
        }
        let func = string_arg(aggregate, "fn").unwrap_or_default();
        if !AGGREGATE_FUNCTIONS.contains(&func.as_str()) {
            report.unknown(
                format!("the aggregate function \"{func}\""),
                field_location.clone(),
            );
            continue;
        }
        let arg = string_arg(aggregate, "arg");
        if func != "count" && arg.is_none() {
            report.unknown(
                format!("the {func} aggregate without an arg"),
                field_location.clone(),
            );
            continue;
        }
        aggregates.push(Aggregate {
            field: field.name.clone(),
            func,
            arg,
            cumulative: bool_arg(aggregate, "cumulative").unwrap_or(false),
            kind: base,
        });
    }
    if aggregates.is_empty() {
        report.unknown(
            format!(
                "the aggregation {} without an @aggregate field",
                object.name
            ),
            location,
        );
        return;
    }

    // One entity per interval, like graph-node's `<aggregation>_<interval>`
    // tables. Dimensions keep their declared types; the aggregates lose the
    // directive and keep theirs.
    for interval in &intervals {
        let owner = format!("{}_{interval}", object.name);
        let mut fields = render_fields(
            &owner,
            &object.fields,
            entity_names,
            enum_names,
            translation,
            report,
        );
        index_timestamp(&mut fields);
        out.push_str(&format!("type {owner} {{\n{}\n}}\n\n", fields.join("\n")));
    }
    translation.aggregations.push(Aggregation {
        name: object.name.clone(),
        source,
        intervals,
        dimensions,
        aggregates,
    });
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
                   domain: Domain! @index\n\
                 }\n\n\
                 type Transfer {\n  \
                   id: ID!\n  \
                   domain: Domain! @index\n\
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

type Renewal implements DomainEvent @entity {
  id: ID!
  domain: Domain!
  txHash: Bytes!
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            translation.text.as_str(),
            "interface DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain! @index\n  \
               txHash: Bytes!\n\
             }\n\n\
             type Domain {\n  \
               id: ID!\n  \
               events: [DomainEvent!]! @derivedFrom(field: \"domain\")\n\
             }\n\n\
             type Transfer implements DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain! @index\n  \
               txHash: Bytes!\n  \
               owner: Bytes!\n\
             }\n\n\
             type Renewal implements DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain! @index\n  \
               txHash: Bytes!\n\
             }"
        );
    }

    // With one implementor, a derived field over the interface is a derived
    // field over that entity, which envio can answer.
    #[test]
    fn derives_a_single_implementor_interface_from_its_implementor() {
        let (translation, report) = translate_ok(
            r#"
interface DomainEvent {
  id: ID!
  domain: Domain!
}

type Domain @entity {
  id: ID!
  events: [DomainEvent!]! @derivedFrom(field: "domain")
}

type Transfer implements DomainEvent @entity {
  id: ID!
  domain: Domain!
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            translation.text.as_str(),
            "interface DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain! @index\n\
             }\n\n\
             type Domain {\n  \
               id: ID!\n  \
               events: [Transfer!]! @derivedFrom(field: \"domain\")\n\
             }\n\n\
             type Transfer implements DomainEvent {\n  \
               id: ID!\n  \
               domain: Domain! @index\n\
             }"
        );
    }

    // PancakeSwap and most Uniswap v2 forks: `Transaction.mints: [Mint]!`.
    #[test]
    fn stores_an_entity_list_with_nullable_elements_as_ids() {
        let (translation, report) = translate_ok(
            r#"
type Transaction @entity {
  id: ID!
  mints: [Mint]!
  burns: [Burn]
}

type Mint @entity {
  id: ID!
}

type Burn @entity {
  id: ID!
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            (
                translation.text.as_str(),
                translation.entity_list_fields.get("Transaction").cloned(),
            ),
            (
                "type Transaction {\n  \
                   id: ID!\n  \
                   mints: [String!]!\n  \
                   burns: [String!]\n\
                 }\n\n\
                 type Mint {\n  id: ID!\n}\n\n\
                 type Burn {\n  id: ID!\n}",
                Some(vec!["mints".to_string(), "burns".to_string()]),
            )
        );
    }

    // CryptoPunks: `NFT` has one implementor, so `Ask.nft: NFT` is a relation to
    // `Punk`. `Event` has nine, so `Ask.created: Event` holds an event's id, as
    // graph-node stores it.
    #[test]
    fn stores_interface_typed_fields() {
        let (translation, report) = translate_ok(
            r#"
interface NFT {
  id: ID!
  owner: Account!
}

interface Event {
  id: ID!
  nft: NFT
}

type Account @entity {
  id: Bytes!
  nftsOwned: [NFT!]! @derivedFrom(field: "owner")
}

type Punk implements NFT @entity {
  id: ID!
  owner: Account!
  events: [Event!]! @derivedFrom(field: "nft")
}

type Ask @entity {
  id: ID!
  nft: NFT
  created: Event!
  history: [Event!]!
}

type Sale implements Event @entity {
  id: ID!
  nft: NFT
  asks: [Ask!]! @derivedFrom(field: "created")
}

type Transfer implements Event @entity {
  id: ID!
  nft: NFT
}
"#,
        );
        assert!(report.is_empty(), "{report}");
        let ask = translation.entity_field_types.get("Ask").unwrap();
        assert_eq!(
            (
                translation.text.as_str(),
                translation.entity_ref_fields.get("Ask").cloned(),
                ask.get("nft").and_then(|field| field.target.clone()),
                ask.get("created").and_then(|field| field.target.clone()),
            ),
            (
                "interface NFT {\n  \
                   id: ID!\n  \
                   owner: Account! @index\n\
                 }\n\n\
                 interface Event {\n  \
                   id: ID!\n  \
                   nft: Punk @index\n\
                 }\n\n\
                 type Account {\n  \
                   id: String!\n  \
                   nftsOwned: [Punk!]! @derivedFrom(field: \"owner\")\n\
                 }\n\n\
                 type Punk implements NFT {\n  \
                   id: ID!\n  \
                   owner: Account! @index\n  \
                   events: [Event!]! @derivedFrom(field: \"nft\")\n\
                 }\n\n\
                 type Ask {\n  \
                   id: ID!\n  \
                   nft: Punk @index\n  \
                   created_id: String! @index\n  \
                   history: [String!]!\n\
                 }\n\n\
                 type Sale implements Event {\n  \
                   id: ID!\n  \
                   nft: Punk @index\n  \
                   asks: [Ask!]! @derivedFrom(field: \"created_id\")\n\
                 }\n\n\
                 type Transfer implements Event {\n  \
                   id: ID!\n  \
                   nft: Punk @index\n\
                 }",
                Some(vec!["nft".to_string(), "created".to_string()]),
                Some("Punk".to_string()),
                Some("Event".to_string()),
            )
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
    fn refuses_unknowns() {
        let (_, report) = translate_ok(
            r#"
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
                rendered.contains("doesn't know the object type Loose without @entity"),
                rendered.contains("doesn't know the type NotAType"),
            ),
            (true, true)
        );
    }

    const TRADES: &str = r#"
type Token @entity {
  id: ID!
}

type Trade @entity(timeseries: true) {
  id: Int8!
  timestamp: Timestamp!
  token: Token!
  amount: BigDecimal!
  price: BigDecimal!
}

type TradeStats @aggregation(intervals: ["hour", "day"], source: "Trade") {
  id: Int8!
  timestamp: Timestamp!
  token: Token!
  volume: BigDecimal! @aggregate(fn: "sum", arg: "amount")
  open: BigDecimal! @aggregate(fn: "first", arg: "price")
  trades: Int8! @aggregate(fn: "count", cumulative: true)
}
"#;

    #[test]
    fn translates_a_timeseries_and_its_aggregation_into_one_entity_per_interval() {
        let (translation, report) = translate_ok(TRADES);
        assert!(report.is_empty(), "{report}");
        let aggregation = translation.aggregations.first().cloned();
        assert_eq!(
            (
                translation.text.as_str(),
                translation.timeseries_entities.iter().cloned().collect::<Vec<_>>(),
                aggregation.as_ref().map(|a| a.intervals.clone()),
                aggregation.as_ref().map(|a| a
                    .dimensions
                    .iter()
                    .map(|d| d.column.clone())
                    .collect::<Vec<_>>()),
                aggregation.as_ref().map(|a| a
                    .aggregates
                    .iter()
                    .map(|g| (g.field.clone(), g.func.clone(), g.arg.clone(), g.cumulative))
                    .collect::<Vec<_>>()),
            ),
            (
                "type Token {\n  id: ID!\n}\n\n\
                 type Trade {\n  id: BigInt!\n  timestamp: Timestamp! @index\n  token: Token!\n  \
                   amount: BigDecimal!\n  price: BigDecimal!\n}\n\n\
                 type TradeStats_hour {\n  id: BigInt!\n  timestamp: Timestamp! @index\n  token: Token!\n  \
                   volume: BigDecimal!\n  open: BigDecimal!\n  trades: BigInt!\n}\n\n\
                 type TradeStats_day {\n  id: BigInt!\n  timestamp: Timestamp! @index\n  token: Token!\n  \
                   volume: BigDecimal!\n  open: BigDecimal!\n  trades: BigInt!\n}\n\n\
                 type EnvioSubgraphRollup {\n  id: ID!\n  payload: String!\n}",
                vec!["Trade".to_string()],
                Some(vec!["hour".to_string(), "day".to_string()]),
                Some(vec!["token_id".to_string()]),
                Some(vec![
                    ("volume".to_string(), "sum".to_string(), Some("amount".to_string()), false),
                    ("open".to_string(), "first".to_string(), Some("price".to_string()), false),
                    ("trades".to_string(), "count".to_string(), None, true),
                ]),
            )
        );
    }

    #[test]
    fn leaves_a_derived_list_of_aggregation_rows_out_of_the_entity() {
        let schema = TRADES.replace(
            "type Token @entity {\n  id: ID!\n}",
            "type Token @entity {\n  id: ID!\n  stats: [TradeStats!]! @derivedFrom(field: \"token\")\n}",
        );
        let (translation, report) = translate_ok(&schema);
        assert!(report.is_empty(), "{report}");
        assert_eq!(
            (
                translation
                    .text
                    .starts_with("type Token {\n  id: ID!\n}\n\n"),
                translation.aggregation_derived_fields.get("Token").cloned(),
            ),
            (
                true,
                Some(vec![AggregationDerivedField {
                    field: "stats".to_string(),
                    aggregation: "TradeStats".to_string(),
                    via: "token".to_string(),
                }])
            )
        );
    }

    #[test]
    fn refuses_malformed_timeseries_and_aggregations() {
        let (_, report) = translate_ok(
            r#"
type NoTime @entity(timeseries: true) {
  id: Int8!
}

type Plain @entity {
  id: ID!
}

type Bad @aggregation(intervals: ["week"], source: "Plain") {
  id: Int8!
  timestamp: Timestamp!
  n: Int! @aggregate(fn: "median", arg: "x")
}
"#,
        );
        let rendered = report.to_string();
        assert_eq!(
            (
                rendered.contains("without a Timestamp `timestamp` field"),
                rendered.contains("the aggregation interval \"week\""),
            ),
            (true, true)
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
