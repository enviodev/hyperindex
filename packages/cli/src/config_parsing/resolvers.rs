use super::entity_parsing::Schema;
use super::human_config::BaseConfig;
use anyhow::{anyhow, Result};
use std::collections::{BTreeMap, HashSet};

pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// What a resolver argument or output may name without declaring it. `BigInt`
/// and `BigDecimal` are not Hasura built-ins: the runtime declares them as
/// custom scalars when an action uses them.
pub const SCALARS: [&str; 7] = [
    "String",
    "Int",
    "Float",
    "Boolean",
    "ID",
    "BigInt",
    "BigDecimal",
];

const RESERVED_TYPES: [&str; 5] = [
    "query_root",
    "mutation_root",
    "subscription_root",
    "order_by",
    "cursor_ordering",
];

/// Root fields the indexer tracks in Hasura besides the entities.
const RESERVED_ROOT_FIELDS: [&str; 3] = ["_meta", "chain_metadata", "raw_events"];

const ENTITY_TYPE_SUFFIXES: [&str; 10] = [
    "_aggregate",
    "_aggregate_bool_exp",
    "_aggregate_bool_exp_count",
    "_aggregate_fields",
    "_aggregate_order_by",
    "_bool_exp",
    "_order_by",
    "_select_column",
    "_stream_cursor_input",
    "_stream_cursor_value_input",
];

fn is_name(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {
            chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        }
        _ => false,
    }
}

/// The named type inside a GraphQL type reference such as `[Int!]!`, or None
/// when the string is not a type reference.
pub fn named_type(type_ref: &str) -> Option<&str> {
    let s = type_ref.trim();
    let s = s.strip_suffix('!').map(str::trim_end).unwrap_or(s);
    if let Some(inner) = s.strip_prefix('[') {
        return named_type(inner.strip_suffix(']')?);
    }
    is_name(s).then_some(s)
}

struct Reserved {
    root_fields: BTreeMap<String, String>,
    types: BTreeMap<String, String>,
}

/// The names Hasura and envio serve generate from schema.graphql. A resolver or
/// type that takes one of them makes the GraphQL schema ambiguous, which both
/// layers refuse at startup; here the user still has the config open.
fn reserved_names(schema: &Schema) -> Reserved {
    let mut root_fields = BTreeMap::new();
    let mut types = BTreeMap::new();
    for name in RESERVED_TYPES.iter().chain(SCALARS.iter()) {
        types.insert(name.to_string(), "a built-in GraphQL type name".to_string());
    }
    for name in RESERVED_ROOT_FIELDS {
        root_fields.insert(
            name.to_string(),
            "a field the indexer publishes".to_string(),
        );
    }
    for name in schema.enums.keys() {
        types.insert(
            name.clone(),
            "an enum declared in schema.graphql".to_string(),
        );
    }
    for entity in schema.entities.keys() {
        root_fields.insert(entity.clone(), format!("entity '{entity}'"));
        root_fields.insert(
            format!("{entity}_by_pk"),
            format!("the by-primary-key field of entity '{entity}'"),
        );
        root_fields.insert(
            format!("{entity}_aggregate"),
            format!("the aggregate field of entity '{entity}'"),
        );
        root_fields.insert(
            format!("{entity}_stream"),
            format!("the subscription stream of entity '{entity}'"),
        );
        types.insert(entity.clone(), format!("the row type of entity '{entity}'"));
        for suffix in ENTITY_TYPE_SUFFIXES {
            types.insert(
                format!("{entity}{suffix}"),
                format!("a type generated for entity '{entity}'"),
            );
        }
    }
    Reserved { root_fields, types }
}

/// Checks `resolvers:` and `types:` against each other and against the
/// schema, and reports every problem at once.
pub fn validate(base: &BaseConfig, schema: &Schema) -> Result<()> {
    let empty_resolvers = BTreeMap::new();
    let empty_types = BTreeMap::new();
    let resolvers = base.resolvers.as_ref().unwrap_or(&empty_resolvers);
    let types = base.types.as_ref().unwrap_or(&empty_types);
    if resolvers.is_empty() && types.is_empty() {
        return Ok(());
    }

    let reserved = reserved_names(schema);
    let declared: HashSet<&str> = types.keys().map(String::as_str).collect();
    let is_known = |name: &str| SCALARS.contains(&name) || declared.contains(name);
    let mut errors: Vec<String> = Vec::new();

    for (name, resolver) in resolvers {
        if !is_name(name) {
            errors.push(format!(
                "resolver '{name}' is not a valid GraphQL field name"
            ));
        } else if let Some(describe) = reserved.root_fields.get(name) {
            errors.push(format!("resolver '{name}' is {describe}"));
        }
        for (arg, type_ref) in resolver.args.iter().flatten() {
            match named_type(type_ref) {
                None => errors.push(format!(
                    "resolver '{name}': argument '{arg}' type '{type_ref}' is not a GraphQL type"
                )),
                Some(named) if !SCALARS.contains(&named) => errors.push(format!(
                    "resolver '{name}': argument '{arg}' has type '{type_ref}', but arguments \
                     take scalars or lists of scalars"
                )),
                Some(_) => {}
            }
        }
        let output = &resolver.output;
        match named_type(output) {
            None => errors.push(format!(
                "resolver '{name}': output type '{output}' is not a GraphQL type"
            )),
            Some(named) if !is_known(named) => errors.push(format!(
                "resolver '{name}': output type '{output}' names '{named}', which is neither a \
                 scalar nor declared under types:"
            )),
            Some(_) => {}
        }
        let handler = resolver.handler.as_str();
        if handler == "sidecar" {
            if base.sidecar.is_none() {
                errors.push(format!(
                    "resolver '{name}': handler 'sidecar' needs a sidecar: block in config.yaml"
                ));
            }
        } else if !(handler.starts_with("http://") || handler.starts_with("https://")) {
            errors.push(format!(
                "resolver '{name}': handler '{handler}' must be 'sidecar' or an http(s):// URL"
            ));
        }
        if resolver.timeout_ms == Some(0) {
            errors.push(format!(
                "resolver '{name}': timeoutMs must be greater than 0"
            ));
        }
    }

    for (type_name, fields) in types {
        if !is_name(type_name) {
            errors.push(format!(
                "type '{type_name}' is not a valid GraphQL type name"
            ));
        } else if let Some(describe) = reserved.types.get(type_name) {
            errors.push(format!("type '{type_name}' is {describe}"));
        }
        for (field, type_ref) in fields {
            match named_type(type_ref) {
                None => errors.push(format!(
                    "type '{type_name}': field '{field}' type '{type_ref}' is not a GraphQL type"
                )),
                Some(named) if !is_known(named) => errors.push(format!(
                    "type '{type_name}': field '{field}' names '{named}', which is neither a \
                     scalar nor declared under types:"
                )),
                Some(_) => {}
            }
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(anyhow!(
            "Invalid resolvers in config.yaml:\n{}",
            errors
                .iter()
                .map(|e| format!("  - {e}"))
                .collect::<Vec<_>>()
                .join("\n")
        ))
    }
}

/// The custom resolvers preview took `resolvers:` as a module path. Caught
/// before deserializing so the user reads what changed rather than serde's
/// "invalid type: string, expected a map".
pub fn reject_module_path_form(human_config_string: &str) -> Result<()> {
    #[derive(serde::Deserialize)]
    struct Probe {
        resolvers: Option<serde_yaml::Value>,
    }
    if let Ok(Probe {
        resolvers: Some(serde_yaml::Value::String(path)),
    }) = serde_yaml::from_str::<Probe>(human_config_string)
    {
        return Err(anyhow!(
            "`resolvers:` declares GraphQL fields answered by your sidecar or a webhook (a map \
             of name to {{ args, output, handler }}). The module path form `resolvers: {path}` \
             from the custom resolvers preview is not supported in this version."
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::named_type;

    #[test]
    fn named_type_unwraps_lists_and_non_null() {
        assert_eq!(
            [
                "Int",
                "Int!",
                "[Int]",
                "[Int!]!",
                "[[TopTrader!]!]",
                "[Int",
                "Int!!",
                "",
                "1Int",
                "[]",
            ]
            .map(named_type),
            [
                Some("Int"),
                Some("Int"),
                Some("Int"),
                Some("Int"),
                Some("TopTrader"),
                None,
                None,
                None,
                None,
                None,
            ]
        );
    }
}
