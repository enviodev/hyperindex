//! Minimal, version-tolerant project file reading for `envio serve`.
//!
//! `config.yaml` is read with a hand-rolled reader that only looks at the
//! top-level `schema` field (the path to schema.graphql, defaulting to
//! "schema.graphql" next to the config file). Unlike the strict
//! `HumanConfig` deserializers, this accepts configs written for any envio
//! version >= 2.21.5 — old or new fields never cause a failure.
//!
//! `schema.graphql` is likewise parsed leniently: entity names, every
//! db-backed field name (needed to map GraphQL field names to columns when
//! the project uses `column_name_format: snake_case`), entity-reference
//! fields (object relationships) and `@derivedFrom` fields (array
//! relationships) are extracted; column shapes come from live Postgres
//! introspection.

use crate::project_paths::ParsedProjectPaths;
use anyhow::{anyhow, Context};
use graphql_parser::schema as gql;

pub struct ProjectSchema {
    pub entities: Vec<EntityDef>,
}

pub struct EntityDef {
    pub name: String,
    pub description: Option<String>,
    /// field name -> referenced entity (fields typed as another entity)
    pub object_relationships: Vec<ObjectRel>,
    /// @derivedFrom fields
    pub array_relationships: Vec<ArrayRel>,
    /// Every field backed by a db column (scalars and enums — everything
    /// that is neither an entity reference nor @derivedFrom), in schema
    /// order.
    pub scalar_fields: Vec<ScalarField>,
}

pub struct ScalarField {
    pub name: String,
    pub description: Option<String>,
}

pub struct ObjectRel {
    pub field_name: String,
    pub remote_entity: String,
}

pub struct ArrayRel {
    pub field_name: String,
    pub remote_entity: String,
    /// The field on the remote entity named by @derivedFrom(field: ...)
    pub remote_field: String,
}

impl ProjectSchema {
    pub fn load(
        project_paths: &ParsedProjectPaths,
        _env: &super::env_config::ServeEnv,
    ) -> anyhow::Result<ProjectSchema> {
        let config_text = std::fs::read_to_string(&project_paths.config).with_context(|| {
            format!(
                "Failed reading config file at {}",
                project_paths.config.display()
            )
        })?;
        let schema_rel_path = read_schema_field(&config_text)?;

        let config_dir = project_paths
            .config
            .parent()
            .ok_or_else(|| anyhow!("Config path has no parent directory"))?;
        let schema_path = config_dir.join(&schema_rel_path);
        let schema_text = std::fs::read_to_string(&schema_path).with_context(|| {
            format!("Failed reading GraphQL schema at {}", schema_path.display())
        })?;

        Self::parse(&schema_text)
    }

    pub fn parse(schema_text: &str) -> anyhow::Result<ProjectSchema> {
        let doc: gql::Document<String> =
            graphql_parser::parse_schema(schema_text).context("Failed parsing schema.graphql")?;

        let entity_names: Vec<String> = doc
            .definitions
            .iter()
            .filter_map(|d| match d {
                gql::Definition::TypeDefinition(gql::TypeDefinition::Object(o)) => {
                    Some(o.name.clone())
                }
                _ => None,
            })
            .collect();

        let mut entities = Vec::new();
        for def in &doc.definitions {
            let gql::Definition::TypeDefinition(gql::TypeDefinition::Object(obj)) = def else {
                continue;
            };
            let mut object_relationships = Vec::new();
            let mut array_relationships = Vec::new();
            let mut scalar_fields = Vec::new();

            for field in &obj.fields {
                let base = base_type_name(&field.field_type);
                let derived_from_field = field.directives.iter().find_map(|d| {
                    if d.name != "derivedFrom" {
                        return None;
                    }
                    d.arguments.iter().find_map(|(name, value)| {
                        if name == "field" {
                            match value {
                                gql::Value::String(s) => Some(s.clone()),
                                _ => None,
                            }
                        } else {
                            None
                        }
                    })
                });

                // Hasura.res's makeColumnConfigs only sends a `comment` for
                // plain db-backed fields, never for relationship fields
                // (Table.DerivedFrom is skipped outright, and entity-reference
                // fields never produce a Table.Field entry) — so relationship
                // fields must not feed scalar_fields here.
                if let Some(remote_field) = derived_from_field {
                    if entity_names.contains(&base) {
                        array_relationships.push(ArrayRel {
                            field_name: field.name.clone(),
                            remote_entity: base,
                            remote_field,
                        });
                        continue;
                    }
                } else if entity_names.contains(&base) && !is_list_type(&field.field_type) {
                    object_relationships.push(ObjectRel {
                        field_name: field.name.clone(),
                        remote_entity: base,
                    });
                    continue;
                }
                scalar_fields.push(ScalarField {
                    name: field.name.clone(),
                    description: field.description.clone(),
                });
            }

            entities.push(EntityDef {
                name: obj.name.clone(),
                description: obj.description.clone(),
                object_relationships,
                array_relationships,
                scalar_fields,
            });
        }

        Ok(ProjectSchema { entities })
    }
}

fn base_type_name(t: &gql::Type<String>) -> String {
    match t {
        gql::Type::NamedType(n) => n.clone(),
        gql::Type::ListType(inner) | gql::Type::NonNullType(inner) => base_type_name(inner),
    }
}

fn is_list_type(t: &gql::Type<String>) -> bool {
    match t {
        gql::Type::NamedType(_) => false,
        gql::Type::ListType(_) => true,
        gql::Type::NonNullType(inner) => is_list_type(inner),
    }
}

/// Reads only the top-level `schema` scalar from config.yaml without
/// deserializing into any versioned struct.
fn read_schema_field(config_text: &str) -> anyhow::Result<String> {
    let value: serde_yaml::Value =
        serde_yaml::from_str(config_text).context("Failed parsing config.yaml as YAML")?;
    match value
        .as_mapping()
        .and_then(|m| m.get(serde_yaml::Value::String("schema".to_string())))
    {
        None => Ok("schema.graphql".to_string()),
        Some(v) => v.as_str().map(|s| s.to_string()).ok_or_else(|| {
            let shown = serde_yaml::to_string(v)
                .map(|s| s.trim_end().to_string())
                .unwrap_or_else(|_| format!("{v:?}"));
            anyhow!(
                "Invalid `schema` value in config.yaml: expected a string path to the GraphQL schema, got: {shown}"
            )
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_field_default_and_custom() {
        assert_eq!(
            read_schema_field("name: test\ncontracts: []\n").unwrap(),
            "schema.graphql"
        );
        assert_eq!(
            read_schema_field("name: x\nschema: ./custom/path.graphql\n").unwrap(),
            "./custom/path.graphql"
        );
    }

    #[test]
    fn tolerates_unknown_and_legacy_fields() {
        // 2.21.5-era config with fields the current HumanConfig rejects or
        // never knew about must still parse.
        let legacy = r#"
name: legacy
description: old
schema: ./schema.graphql
unordered_multichain_mode: true
event_decoder: hypersync-client
networks:
  - id: 1
    start_block: 0
    contracts: []
some_future_field:
  nested: [1, 2]
"#;
        assert_eq!(read_schema_field(legacy).unwrap(), "./schema.graphql");
    }

    #[test]
    fn reads_real_2_21_5_config_fixtures() {
        // Authentic v2.21.5 config shape (verbatim from the v2.21.5 tag,
        // trimmed): networks/rpc_config keys, no schema field -> default.
        let legacy = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/test/configs/serve-legacy-2.21.5.yaml"
        ))
        .unwrap();
        assert_eq!(read_schema_field(&legacy).unwrap(), "schema.graphql");

        let custom = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/test/configs/serve-legacy-2.21.5-custom-schema.yaml"
        ))
        .unwrap();
        assert_eq!(
            read_schema_field(&custom).unwrap(),
            "./schemas/gravatar-schema.graphql"
        );
    }

    #[test]
    fn non_string_schema_value_is_an_error() {
        let err = read_schema_field("schema:\n  nested: true\n")
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("Invalid `schema` value") && err.contains("nested"),
            "unexpected error: {err}"
        );
        let err = read_schema_field("schema: 42\n").unwrap_err().to_string();
        assert!(
            err.contains("Invalid `schema` value") && err.contains("42"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn parses_relationships() {
        let schema = r#"
type User {
  id: ID!
  "user balance"
  tokenBalance: BigInt!
  gravatar: Gravatar
  tokens: [Token!]! @derivedFrom(field: "owner")
}
type Gravatar {
  id: ID!
  owner: User!
}
type Token {
  id: ID!
  owner: User!
}
"#;
        let parsed = ProjectSchema::parse(schema).unwrap();
        let user = parsed.entities.iter().find(|e| e.name == "User").unwrap();
        assert_eq!(
            (
                user.object_relationships
                    .iter()
                    .map(|r| r.field_name.as_str())
                    .collect::<Vec<_>>(),
                user.array_relationships
                    .iter()
                    .map(|r| (r.field_name.as_str(), r.remote_field.as_str()))
                    .collect::<Vec<_>>(),
                user.scalar_fields
                    .iter()
                    .map(|f| (f.name.as_str(), f.description.as_deref()))
                    .collect::<Vec<_>>(),
            ),
            (
                vec!["gravatar"],
                vec![("tokens", "owner")],
                vec![("id", None), ("tokenBalance", Some("user balance"))]
            )
        );
    }
}
