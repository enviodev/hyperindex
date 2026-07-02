//! Resolves `__schema` / `__type` selections against the registry,
//! producing JSON text that matches Hasura's introspection responses
//! byte-for-byte (field order follows the selection set; type lists are
//! ordered by type name).

use super::types::{EnumValueDef, FieldDef, InputValueDef, Registry, TypeDef, TypeRef};
use crate::serve::exec::error::{GResult, GraphQLError};
use crate::serve::exec::ir::{IntroSelItem, IntroSelection, IntrospectionField};

/// Returns the serialized JSON value for the introspection field.
pub fn resolve(registry: &Registry, field: &IntrospectionField) -> GResult<String> {
    let mut out = String::with_capacity(256);
    match field.field.as_str() {
        "__schema" => write_schema(registry, &field.selection, &mut out)?,
        "__type" => match field.type_name.as_deref().and_then(|n| registry.get(n)) {
            Some(def) => write_type(registry, TypeView::Def(def), &field.selection, &mut out)?,
            None => out.push_str("null"),
        },
        other => {
            return Err(internal(format!(
                "unexpected introspection root field '{other}'"
            )))
        }
    }
    Ok(out)
}

/// Fallback for selections validate.rs should have rejected already.
fn internal(message: String) -> GraphQLError {
    GraphQLError::validation("$", message)
}

fn subsel(item: &IntroSelItem) -> GResult<&IntroSelection> {
    item.selection
        .as_ref()
        .ok_or_else(|| internal(format!("field '{}' requires a selection set", item.field)))
}

fn write_json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn write_opt_str(out: &mut String, s: Option<&str>) {
    match s {
        Some(s) => write_json_string(out, s),
        None => out.push_str("null"),
    }
}

/// Writes `{ "<alias>": <value(item)>, ... }` in selection order.
fn write_object(
    sel: &IntroSelection,
    out: &mut String,
    mut value: impl FnMut(&IntroSelItem, &mut String) -> GResult<()>,
) -> GResult<()> {
    out.push('{');
    let mut first = true;
    for item in &sel.items {
        if !first {
            out.push(',');
        }
        first = false;
        write_json_string(out, &item.alias);
        out.push(':');
        value(item, out)?;
    }
    out.push('}');
    Ok(())
}

fn write_array<T>(
    out: &mut String,
    items: impl IntoIterator<Item = T>,
    mut value: impl FnMut(T, &mut String) -> GResult<()>,
) -> GResult<()> {
    out.push('[');
    let mut first = true;
    for it in items {
        if !first {
            out.push(',');
        }
        first = false;
        value(it, out)?;
    }
    out.push(']');
    Ok(())
}

fn write_schema(registry: &Registry, sel: &IntroSelection, out: &mut String) -> GResult<()> {
    write_object(sel, out, |item, out| {
        match item.field.as_str() {
            "__typename" => write_json_string(out, "__Schema"),
            "description" => out.push_str("null"),
            "queryType" => write_root_type(registry, Some(&registry.query_root), item, out)?,
            "mutationType" => {
                write_root_type(registry, registry.mutation_root.as_deref(), item, out)?
            }
            "subscriptionType" => {
                write_root_type(registry, Some(&registry.subscription_root), item, out)?
            }
            "types" => {
                let sub = subsel(item)?;
                write_array(out, registry.types.values(), |def, out| {
                    write_type(registry, TypeView::Def(def), sub, out)
                })?;
            }
            "directives" => {
                let sub = subsel(item)?;
                write_array(out, directives().iter(), |d, out| {
                    write_directive(registry, d, sub, out)
                })?;
            }
            other => return Err(internal(format!("unexpected field '{other}' on __Schema"))),
        }
        Ok(())
    })
}

fn write_root_type(
    registry: &Registry,
    name: Option<&str>,
    item: &IntroSelItem,
    out: &mut String,
) -> GResult<()> {
    match name.and_then(|n| registry.get(n)) {
        Some(def) => write_type(registry, TypeView::Def(def), subsel(item)?, out),
        None => {
            out.push_str("null");
            Ok(())
        }
    }
}

/// One step of a type-ref chain: a registry type, or a NonNull/List wrapper
/// whose `ofType` continues the chain.
#[derive(Clone, Copy)]
enum TypeView<'a> {
    Def(&'a TypeDef),
    NonNull(&'a TypeRef),
    List(&'a TypeRef),
}

fn view_of<'a>(registry: &'a Registry, r: &'a TypeRef) -> Option<TypeView<'a>> {
    match r {
        TypeRef::Named(n) => registry.get(n).map(TypeView::Def),
        TypeRef::NonNull(inner) => Some(TypeView::NonNull(inner)),
        TypeRef::List(inner) => Some(TypeView::List(inner)),
    }
}

fn write_type_ref(
    registry: &Registry,
    r: &TypeRef,
    sel: &IntroSelection,
    out: &mut String,
) -> GResult<()> {
    match view_of(registry, r) {
        Some(view) => write_type(registry, view, sel, out),
        None => {
            out.push_str("null");
            Ok(())
        }
    }
}

fn def_description(def: &TypeDef) -> Option<&str> {
    match def {
        TypeDef::Scalar { description, .. }
        | TypeDef::Object { description, .. }
        | TypeDef::InputObject { description, .. }
        | TypeDef::Enum { description, .. } => description.as_deref(),
    }
}

fn write_type(
    registry: &Registry,
    view: TypeView,
    sel: &IntroSelection,
    out: &mut String,
) -> GResult<()> {
    write_object(sel, out, |item, out| {
        match item.field.as_str() {
            "__typename" => write_json_string(out, "__Type"),
            "kind" => {
                let kind = match view {
                    TypeView::Def(TypeDef::Scalar { .. }) => "SCALAR",
                    TypeView::Def(TypeDef::Object { .. }) => "OBJECT",
                    TypeView::Def(TypeDef::InputObject { .. }) => "INPUT_OBJECT",
                    TypeView::Def(TypeDef::Enum { .. }) => "ENUM",
                    TypeView::NonNull(_) => "NON_NULL",
                    TypeView::List(_) => "LIST",
                };
                write_json_string(out, kind);
            }
            "name" => match view {
                TypeView::Def(def) => write_json_string(out, def.name()),
                _ => out.push_str("null"),
            },
            "description" => match view {
                TypeView::Def(def) => write_opt_str(out, def_description(def)),
                _ => out.push_str("null"),
            },
            // Nothing in the schema is deprecated, so includeDeprecated has
            // no effect on fields/enumValues.
            "fields" => match view {
                TypeView::Def(TypeDef::Object { fields, .. }) => {
                    let sub = subsel(item)?;
                    write_array(out, fields.iter(), |f, out| {
                        write_field(registry, f, sub, out)
                    })?;
                }
                _ => out.push_str("null"),
            },
            "inputFields" => match view {
                TypeView::Def(TypeDef::InputObject { fields, .. }) => {
                    let sub = subsel(item)?;
                    write_array(out, fields.iter(), |f, out| {
                        write_input_value(registry, f, sub, out)
                    })?;
                }
                _ => out.push_str("null"),
            },
            "interfaces" => match view {
                TypeView::Def(TypeDef::Object { .. }) => out.push_str("[]"),
                _ => out.push_str("null"),
            },
            "enumValues" => match view {
                TypeView::Def(TypeDef::Enum { values, .. }) => {
                    let sub = subsel(item)?;
                    write_array(out, values.iter(), |v, out| write_enum_value(v, sub, out))?;
                }
                _ => out.push_str("null"),
            },
            "possibleTypes" => out.push_str("null"),
            "ofType" => match view {
                TypeView::NonNull(inner) | TypeView::List(inner) => {
                    write_type_ref(registry, inner, subsel(item)?, out)?
                }
                TypeView::Def(_) => out.push_str("null"),
            },
            other => return Err(internal(format!("unexpected field '{other}' on __Type"))),
        }
        Ok(())
    })
}

fn write_field(
    registry: &Registry,
    field: &FieldDef,
    sel: &IntroSelection,
    out: &mut String,
) -> GResult<()> {
    write_object(sel, out, |item, out| {
        match item.field.as_str() {
            "__typename" => write_json_string(out, "__Field"),
            "name" => write_json_string(out, &field.name),
            "description" => write_opt_str(out, field.description.as_deref()),
            "args" => {
                let sub = subsel(item)?;
                write_array(out, field.args.iter(), |a, out| {
                    write_input_value(registry, a, sub, out)
                })?;
            }
            "type" => write_type_ref(registry, &field.ty, subsel(item)?, out)?,
            "isDeprecated" => out.push_str("false"),
            "deprecationReason" => out.push_str("null"),
            other => return Err(internal(format!("unexpected field '{other}' on __Field"))),
        }
        Ok(())
    })
}

fn write_input_value(
    registry: &Registry,
    input: &InputValueDef,
    sel: &IntroSelection,
    out: &mut String,
) -> GResult<()> {
    write_object(sel, out, |item, out| {
        match item.field.as_str() {
            "__typename" => write_json_string(out, "__InputValue"),
            "name" => write_json_string(out, &input.name),
            "description" => write_opt_str(out, input.description.as_deref()),
            "type" => write_type_ref(registry, &input.ty, subsel(item)?, out)?,
            "defaultValue" => write_opt_str(out, input.default_value.as_deref()),
            other => {
                return Err(internal(format!(
                    "unexpected field '{other}' on __InputValue"
                )))
            }
        }
        Ok(())
    })
}

fn write_enum_value(value: &EnumValueDef, sel: &IntroSelection, out: &mut String) -> GResult<()> {
    write_object(sel, out, |item, out| {
        match item.field.as_str() {
            "__typename" => write_json_string(out, "__EnumValue"),
            "name" => write_json_string(out, &value.name),
            "description" => write_opt_str(out, value.description.as_deref()),
            "isDeprecated" => out.push_str("false"),
            "deprecationReason" => out.push_str("null"),
            other => {
                return Err(internal(format!(
                    "unexpected field '{other}' on __EnumValue"
                )))
            }
        }
        Ok(())
    })
}

struct DirectiveDef {
    name: &'static str,
    description: &'static str,
    locations: &'static [&'static str],
    args: Vec<InputValueDef>,
}

fn directives() -> Vec<DirectiveDef> {
    let if_arg = InputValueDef::new("if", None, TypeRef::non_null(TypeRef::named("Boolean")));
    let ttl = {
        let mut arg = InputValueDef::new(
            "ttl",
            Some("measured in seconds"),
            TypeRef::non_null(TypeRef::named("Int")),
        );
        arg.default_value = Some("60".to_string());
        arg
    };
    let refresh = {
        let mut arg = InputValueDef::new(
            "refresh",
            Some("refresh the cache entry"),
            TypeRef::non_null(TypeRef::named("Boolean")),
        );
        arg.default_value = Some("false".to_string());
        arg
    };
    vec![
        DirectiveDef {
            name: "include",
            description: "whether this query should be included",
            locations: &["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"],
            args: vec![if_arg.clone()],
        },
        DirectiveDef {
            name: "skip",
            description: "whether this query should be skipped",
            locations: &["FIELD", "FRAGMENT_SPREAD", "INLINE_FRAGMENT"],
            args: vec![if_arg],
        },
        DirectiveDef {
            name: "cached",
            description: "whether this query should be cached (Hasura Cloud only)",
            locations: &["QUERY"],
            args: vec![ttl, refresh],
        },
    ]
}

fn write_directive(
    registry: &Registry,
    directive: &DirectiveDef,
    sel: &IntroSelection,
    out: &mut String,
) -> GResult<()> {
    write_object(sel, out, |item, out| {
        match item.field.as_str() {
            "__typename" => write_json_string(out, "__Directive"),
            "name" => write_json_string(out, directive.name),
            "description" => write_json_string(out, directive.description),
            "locations" => write_array(out, directive.locations.iter(), |loc, out| {
                write_json_string(out, loc);
                Ok(())
            })?,
            "args" => {
                let sub = subsel(item)?;
                write_array(out, directive.args.iter(), |a, out| {
                    write_input_value(registry, a, sub, out)
                })?;
            }
            // Hasura types isRepeatable as String! yet always returns null.
            "isRepeatable" => out.push_str("null"),
            other => {
                return Err(internal(format!(
                    "unexpected field '{other}' on __Directive"
                )))
            }
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::gql::schema_build::{self, Role};
    use crate::serve::model::{Column, Scalar, ServerModel, Table};
    use crate::serve::pg_catalog::RelationKind;

    fn test_registry() -> Registry {
        let model = ServerModel {
            tables: vec![Table {
                name: "User".to_string(),
                kind: RelationKind::Table,
                description: None,
                columns: vec![Column {
                    api_name: "id".to_string(),
                    db_name: "id".to_string(),
                    pg_type: "text".to_string(),
                    scalar: Scalar::String,
                    is_array: false,
                    nullable: false,
                    description: None,
                }],
                primary_key: vec!["id".to_string()],
                object_relationships: vec![],
                array_relationships: vec![],
                admin_only: false,
                public_aggregations: false,
            }],
            pg_schema: "public".to_string(),
            response_limit: None,
            enums: std::collections::HashMap::new(),
        };
        schema_build::build(&model, Role::Public)
    }

    fn item(field: &str, selection: Option<IntroSelection>) -> IntroSelItem {
        IntroSelItem {
            alias: field.to_string(),
            field: field.to_string(),
            include_deprecated: false,
            selection,
        }
    }

    fn sel(items: Vec<IntroSelItem>) -> IntroSelection {
        IntroSelection { items }
    }

    fn type_query(name: &str, selection: IntroSelection) -> IntrospectionField {
        IntrospectionField {
            alias: "__type".to_string(),
            field: "__type".to_string(),
            type_name: Some(name.to_string()),
            selection,
        }
    }

    #[test]
    fn json_string_escaping() {
        let mut out = String::new();
        write_json_string(&mut out, "a\"b\\c\nd\te\u{1}f🚀");
        assert_eq!(out, "\"a\\\"b\\\\c\\nd\\te\\u0001f🚀\"");
    }

    #[test]
    fn type_query_object_with_of_type_chain() {
        let registry = test_registry();
        let field = type_query(
            "User",
            sel(vec![
                item("kind", None),
                item("name", None),
                item("description", None),
                item(
                    "fields",
                    Some(sel(vec![
                        item("name", None),
                        item(
                            "type",
                            Some(sel(vec![
                                item("kind", None),
                                item("name", None),
                                item(
                                    "ofType",
                                    Some(sel(vec![item("kind", None), item("name", None)])),
                                ),
                            ])),
                        ),
                    ])),
                ),
                item("interfaces", Some(sel(vec![item("name", None)]))),
                item("inputFields", Some(sel(vec![item("name", None)]))),
                item("possibleTypes", Some(sel(vec![item("name", None)]))),
            ]),
        );
        assert_eq!(
            resolve(&registry, &field).unwrap(),
            r#"{"kind":"OBJECT","name":"User","description":"columns and relationships of \"User\"","fields":[{"name":"id","type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String"}}}],"interfaces":[],"inputFields":null,"possibleTypes":null}"#
        );
    }

    #[test]
    fn type_query_missing_type_is_null() {
        let registry = test_registry();
        let field = type_query("DoesNotExist", sel(vec![item("name", None)]));
        assert_eq!(resolve(&registry, &field).unwrap(), "null");
    }

    #[test]
    fn type_query_meta_enum_uses_alias() {
        let registry = test_registry();
        let mut values = item("enumValues", Some(sel(vec![item("name", None)])));
        values.alias = "vals".to_string();
        let field = type_query("__TypeKind", sel(vec![item("__typename", None), values]));
        assert_eq!(
            resolve(&registry, &field).unwrap(),
            r#"{"__typename":"__Type","vals":[{"name":"ENUM"},{"name":"INPUT_OBJECT"},{"name":"INTERFACE"},{"name":"LIST"},{"name":"NON_NULL"},{"name":"OBJECT"},{"name":"SCALAR"},{"name":"UNION"}]}"#
        );
    }

    #[test]
    fn schema_roots_and_directives() {
        let registry = test_registry();
        let field = IntrospectionField {
            alias: "__schema".to_string(),
            field: "__schema".to_string(),
            type_name: None,
            selection: sel(vec![
                item("queryType", Some(sel(vec![item("name", None)]))),
                item("mutationType", Some(sel(vec![item("name", None)]))),
                item("subscriptionType", Some(sel(vec![item("name", None)]))),
                item(
                    "directives",
                    Some(sel(vec![
                        item("name", None),
                        item("locations", None),
                        item(
                            "args",
                            Some(sel(vec![
                                item("name", None),
                                item("defaultValue", None),
                                item(
                                    "type",
                                    Some(sel(vec![
                                        item("kind", None),
                                        item("ofType", Some(sel(vec![item("name", None)]))),
                                    ])),
                                ),
                            ])),
                        ),
                    ])),
                ),
            ]),
        };
        assert_eq!(
            resolve(&registry, &field).unwrap(),
            concat!(
                r#"{"queryType":{"name":"query_root"},"mutationType":null,"subscriptionType":{"name":"subscription_root"},"#,
                r#""directives":[{"name":"include","locations":["FIELD","FRAGMENT_SPREAD","INLINE_FRAGMENT"],"args":[{"name":"if","defaultValue":null,"type":{"kind":"NON_NULL","ofType":{"name":"Boolean"}}}]},"#,
                r#"{"name":"skip","locations":["FIELD","FRAGMENT_SPREAD","INLINE_FRAGMENT"],"args":[{"name":"if","defaultValue":null,"type":{"kind":"NON_NULL","ofType":{"name":"Boolean"}}}]},"#,
                r#"{"name":"cached","locations":["QUERY"],"args":[{"name":"ttl","defaultValue":"60","type":{"kind":"NON_NULL","ofType":{"name":"Int"}}},{"name":"refresh","defaultValue":"false","type":{"kind":"NON_NULL","ofType":{"name":"Boolean"}}}]}]}"#
            )
        );
    }

    /// The nested TypeRef fragment of the standard introspection query:
    /// `kind name` plus `depth` levels of `ofType`.
    fn type_ref_sel(depth: usize) -> IntroSelection {
        let mut items = vec![item("kind", None), item("name", None)];
        if depth > 0 {
            items.push(item("ofType", Some(type_ref_sel(depth - 1))));
        }
        sel(items)
    }

    fn input_value_sel() -> IntroSelection {
        sel(vec![
            item("name", None),
            item("description", None),
            item("type", Some(type_ref_sel(7))),
            item("defaultValue", None),
        ])
    }

    fn full_type_sel() -> IntroSelection {
        sel(vec![
            item("kind", None),
            item("name", None),
            item("description", None),
            item(
                "fields",
                Some(sel(vec![
                    item("name", None),
                    item("description", None),
                    item("args", Some(input_value_sel())),
                    item("type", Some(type_ref_sel(7))),
                    item("isDeprecated", None),
                    item("deprecationReason", None),
                ])),
            ),
            item("inputFields", Some(input_value_sel())),
            item("interfaces", Some(type_ref_sel(7))),
            item(
                "enumValues",
                Some(sel(vec![
                    item("name", None),
                    item("description", None),
                    item("isDeprecated", None),
                    item("deprecationReason", None),
                ])),
            ),
            item("possibleTypes", Some(type_ref_sel(7))),
        ])
    }

    // Expected values come verbatim from the oracle snapshot
    // introspection-full-public.json (compact-serialized).
    #[test]
    fn meta_types_match_oracle_full_type_fragment() {
        let registry = test_registry();
        let render = |name: &str| resolve(&registry, &type_query(name, full_type_sel())).unwrap();
        assert_eq!(
            (render("__Type"), render("__TypeKind")),
            (
                r#"{"kind":"OBJECT","name":"__Type","description":null,"fields":[{"name":"description","description":null,"args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"isDeprecated":false,"deprecationReason":null},{"name":"enumValues","description":null,"args":[{"name":"includeDeprecated","description":null,"type":{"kind":"SCALAR","name":"Boolean","ofType":null},"defaultValue":"false"}],"type":{"kind":"OBJECT","name":"__EnumValue","ofType":null},"isDeprecated":false,"deprecationReason":null},{"name":"fields","description":null,"args":[{"name":"includeDeprecated","description":null,"type":{"kind":"SCALAR","name":"Boolean","ofType":null},"defaultValue":"false"}],"type":{"kind":"OBJECT","name":"__Field","ofType":null},"isDeprecated":false,"deprecationReason":null},{"name":"inputFields","description":null,"args":[],"type":{"kind":"OBJECT","name":"__InputValue","ofType":null},"isDeprecated":false,"deprecationReason":null},{"name":"interfaces","description":null,"args":[],"type":{"kind":"OBJECT","name":"__Type","ofType":null},"isDeprecated":false,"deprecationReason":null},{"name":"kind","description":null,"args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"ENUM","name":"__TypeKind","ofType":null}},"isDeprecated":false,"deprecationReason":null},{"name":"name","description":null,"args":[],"type":{"kind":"NON_NULL","name":null,"ofType":{"kind":"SCALAR","name":"String","ofType":null}},"isDeprecated":false,"deprecationReason":null},{"name":"ofType","description":null,"args":[],"type":{"kind":"OBJECT","name":"__Type","ofType":null},"isDeprecated":false,"deprecationReason":null},{"name":"possibleTypes","description":null,"args":[],"type":{"kind":"OBJECT","name":"__Type","ofType":null},"isDeprecated":false,"deprecationReason":null}],"inputFields":null,"interfaces":[],"enumValues":null,"possibleTypes":null}"#.to_string(),
                r#"{"kind":"ENUM","name":"__TypeKind","description":null,"fields":null,"inputFields":null,"interfaces":null,"enumValues":[{"name":"ENUM","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"INPUT_OBJECT","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"INTERFACE","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"LIST","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"NON_NULL","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"OBJECT","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"SCALAR","description":null,"isDeprecated":false,"deprecationReason":null},{"name":"UNION","description":null,"isDeprecated":false,"deprecationReason":null}],"possibleTypes":null}"#.to_string()
            )
        );
    }

    #[test]
    fn schema_types_are_sorted_and_include_meta_types() {
        let registry = test_registry();
        let field = IntrospectionField {
            alias: "s".to_string(),
            field: "__schema".to_string(),
            type_name: None,
            selection: sel(vec![item("types", Some(sel(vec![item("name", None)])))]),
        };
        let out = resolve(&registry, &field).unwrap();
        let meta: Vec<&str> = [
            "__Directive",
            "__EnumValue",
            "__Field",
            "__InputValue",
            "__Schema",
            "__Type",
            "__TypeKind",
        ]
        .into_iter()
        .filter(|n| out.contains(&format!("{{\"name\":\"{n}\"}}")))
        .collect();
        assert_eq!(
            (
                meta.len(),
                out.contains("\"User_stream_cursor_value_input\"},{\"name\":\"__Directive\"")
            ),
            (7, true)
        );
    }
}
