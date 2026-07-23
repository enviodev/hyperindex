//! The server model: which relations are exposed, under which GraphQL
//! names, with which columns and relationships — the union of what Hasura
//! metadata (as applied by the indexer) and Postgres introspection produce.

use super::env_config::ServeEnv;
use super::pg_catalog::{Catalog, RelationKind};
use super::project_schema::ProjectSchema;
use crate::config_parsing::field_types::to_snake_case;
use anyhow::anyhow;
use std::collections::HashMap;

/// GraphQL scalar names as Hasura assigns them per Postgres type.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scalar {
    String,
    Int,
    Float,
    Boolean,
    Bigint,
    Numeric,
    Float8,
    Timestamptz,
    Timestamp,
    Date,
    Jsonb,
    Json,
    Smallint,
    /// A Postgres enum type, exposed by Hasura as an opaque scalar named
    /// after the pg type (e.g. `accounttype`).
    PgEnum,
    /// Fallback for pg types we don't specially handle; exposed under the
    /// pg type name like Hasura does.
    Other,
}

impl Scalar {
    pub fn from_pg_type(pg_type: &str, is_enum: bool) -> Scalar {
        if is_enum {
            return Scalar::PgEnum;
        }
        match pg_type {
            "text" | "varchar" | "bpchar" | "name" | "citext" => Scalar::String,
            "int4" => Scalar::Int,
            "int2" => Scalar::Smallint,
            "int8" => Scalar::Bigint,
            "float4" => Scalar::Float,
            "float8" => Scalar::Float8,
            "numeric" => Scalar::Numeric,
            "bool" => Scalar::Boolean,
            "timestamptz" => Scalar::Timestamptz,
            "timestamp" => Scalar::Timestamp,
            "date" => Scalar::Date,
            "jsonb" => Scalar::Jsonb,
            "json" => Scalar::Json,
            _ => Scalar::Other,
        }
    }

    /// The GraphQL type name for this scalar on a column of `pg_type`.
    pub fn gql_name(&self, pg_type: &str) -> String {
        match self {
            Scalar::String => "String".to_string(),
            Scalar::Int => "Int".to_string(),
            Scalar::Float => "Float".to_string(),
            Scalar::Boolean => "Boolean".to_string(),
            Scalar::Bigint => "bigint".to_string(),
            Scalar::Numeric => "numeric".to_string(),
            Scalar::Float8 => "float8".to_string(),
            Scalar::Timestamptz => "timestamptz".to_string(),
            Scalar::Timestamp => "timestamp".to_string(),
            Scalar::Date => "date".to_string(),
            Scalar::Jsonb => "jsonb".to_string(),
            Scalar::Json => "json".to_string(),
            Scalar::Smallint => "smallint".to_string(),
            Scalar::PgEnum | Scalar::Other => pg_type.to_string(),
        }
    }

    /// Whether Hasura's STRINGIFY_NUMERIC_TYPES turns bare column values of
    /// this scalar into JSON strings.
    pub fn stringified(&self) -> bool {
        matches!(self, Scalar::Bigint | Scalar::Numeric | Scalar::Float8)
    }

    /// Whether min/max/sum/avg-style numeric aggregates exist for it.
    pub fn is_numeric(&self) -> bool {
        matches!(
            self,
            Scalar::Int
                | Scalar::Smallint
                | Scalar::Float
                | Scalar::Bigint
                | Scalar::Numeric
                | Scalar::Float8
        )
    }
}

#[derive(Clone)]
pub struct Column {
    /// GraphQL field name (Hasura custom column name when renamed).
    pub api_name: String,
    /// Actual database column name.
    pub db_name: String,
    pub pg_type: String,
    /// Namespace owning `pg_type`; kept separate because GraphQL exposes
    /// the bare type name while SQL casts must qualify custom types.
    pub pg_type_schema: String,
    pub scalar: Scalar,
    pub is_array: bool,
    pub nullable: bool,
    pub description: Option<String>,
}

pub struct ObjectRelationship {
    pub name: String,
    /// db column on this table joined to remote "id"
    pub local_db_column: String,
    pub remote_table: String,
}

pub struct ArrayRelationship {
    pub name: String,
    pub remote_table: String,
    /// db column on the remote table joined to this table's "id"
    pub remote_db_column: String,
}

pub struct Table {
    pub name: String,
    pub kind: RelationKind,
    pub description: Option<String>,
    pub columns: Vec<Column>,
    pub primary_key: Vec<String>,
    pub object_relationships: Vec<ObjectRelationship>,
    pub array_relationships: Vec<ArrayRelationship>,
    /// Tracked-with-select-permission tables are visible to the public
    /// role; effect-cache tables are tracked without permissions and are
    /// admin-only.
    pub admin_only: bool,
    /// allow_aggregations for the public role.
    pub public_aggregations: bool,
}

impl Table {
    pub fn column_by_api_name(&self, name: &str) -> Option<&Column> {
        self.columns.iter().find(|c| c.api_name == name)
    }
}

/// Resolves a GraphQL field name to its db column, trying the original name
/// first and then Table.res's `column_name_format` snake_case rewrite --
/// column_name_format can rename either scalar fields or the `_id` suffix
/// entity-ref columns, so a renamed column may appear under either form.
/// `suffix` (e.g. "_id" for entity-reference columns) is appended after the
/// snake-casing, matching how Table.res derives the column name.
fn resolve_db_column<'a>(
    field_name: &str,
    suffix: &str,
    columns: impl Iterator<Item = &'a super::pg_catalog::Column> + Clone,
) -> Option<String> {
    [
        format!("{field_name}{suffix}"),
        format!("{}{suffix}", to_snake_case(field_name)),
    ]
    .into_iter()
    .find(|db| columns.clone().any(|c| &c.name == db))
}

pub struct ServerModel {
    /// Exposed tables in Hasura's root-field ordering (sorted by name).
    pub tables: Vec<Table>,
    pub pg_schema: String,
    pub response_limit: Option<u32>,
}

impl ServerModel {
    pub fn table(&self, name: &str) -> Option<&Table> {
        self.tables
            .binary_search_by(|t| t.name.as_str().cmp(name))
            .ok()
            .map(|i| &self.tables[i])
    }

    pub fn build(
        project: ProjectSchema,
        catalog: Catalog,
        env: &ServeEnv,
    ) -> anyhow::Result<ServerModel> {
        let mut tables: Vec<Table> = Vec::new();

        let internal_exposed = ["raw_events", "_meta", "chain_metadata"];
        for name in internal_exposed {
            if let Some(rel) = catalog.relations.get(name) {
                tables.push(Table {
                    name: rel.name.clone(),
                    kind: rel.kind,
                    description: None,
                    columns: rel
                        .columns
                        .iter()
                        .map(|c| Column {
                            api_name: c.name.clone(),
                            db_name: c.name.clone(),
                            pg_type: c.pg_type.clone(),
                            pg_type_schema: c.pg_type_schema.clone(),
                            scalar: Scalar::from_pg_type(&c.pg_type, c.is_enum),
                            is_array: c.is_array,
                            nullable: c.nullable,
                            description: None,
                        })
                        .collect(),
                    primary_key: rel.primary_key.clone(),
                    object_relationships: vec![],
                    array_relationships: vec![],
                    admin_only: false,
                    public_aggregations: env.aggregate_entities.contains(&name.to_string()),
                });
            }
        }

        let mut skipped_entities: Vec<&str> = Vec::new();
        for entity in &project.entities {
            let Some(rel) = catalog.relations.get(&entity.name) else {
                // Entity present in schema.graphql but not migrated into the
                // DB — Hasura tracking would have failed for it; skip.
                skipped_entities.push(&entity.name);
                continue;
            };

            // Fields that are entity references (object relationships) are
            // stored as `<field>_id` columns; their GraphQL column name is
            // also `<field>_id` (Table.res getApiFieldName), while the db
            // column may additionally be snake_cased. Hasura never applies
            // the relationship field's own description to this underlying
            // fk column (Hasura.res's makeColumnConfigs only sets comments
            // for plain Table.Field entries, never entity-reference
            // fields) — pinned by the `gravatar_id` case in
            // introspection-descriptions, so this stays `None` here.
            let mut api_by_db: HashMap<String, (String, Option<String>)> = HashMap::new();
            for rel_def in &entity.object_relationships {
                let api = format!("{}_id", rel_def.field_name);
                if let Some(db) = resolve_db_column(&rel_def.field_name, "_id", rel.columns.iter())
                {
                    api_by_db.insert(db, (api, None));
                }
            }
            // Every db-backed field maps to a column named either exactly
            // like the field (`column_name_format: original`) or its
            // snake_case (`column_name_format: snake_case`); the api name is
            // always the original field name, matching Table.res's
            // getApiFieldName / Hasura.res's custom_name renames.
            for field in &entity.scalar_fields {
                if let Some(db) = resolve_db_column(&field.name, "", rel.columns.iter()) {
                    api_by_db
                        .entry(db)
                        .or_insert((field.name.clone(), field.description.clone()));
                }
            }

            let columns = rel
                .columns
                .iter()
                .map(|c| {
                    let (api_name, description) = api_by_db
                        .get(&c.name)
                        .cloned()
                        .unwrap_or((c.name.clone(), None));
                    Column {
                        api_name,
                        db_name: c.name.clone(),
                        pg_type: c.pg_type.clone(),
                        pg_type_schema: c.pg_type_schema.clone(),
                        scalar: Scalar::from_pg_type(&c.pg_type, c.is_enum),
                        is_array: c.is_array,
                        nullable: c.nullable,
                        description,
                    }
                })
                .collect::<Vec<_>>();

            let object_relationships = entity
                .object_relationships
                .iter()
                .filter_map(|r| {
                    let db_col = columns
                        .iter()
                        .find(|c| c.api_name == format!("{}_id", r.field_name))?
                        .db_name
                        .clone();
                    if !catalog.relations.contains_key(&r.remote_entity) {
                        return None;
                    }
                    Some(ObjectRelationship {
                        name: r.field_name.clone(),
                        local_db_column: db_col,
                        remote_table: r.remote_entity.clone(),
                    })
                })
                .collect();

            let array_relationships = entity
                .array_relationships
                .iter()
                .filter_map(|r| {
                    let remote_entity = project
                        .entities
                        .iter()
                        .find(|e| e.name == r.remote_entity)?;
                    let remote_rel = catalog.relations.get(&r.remote_entity)?;
                    // Resolve the remote field to its db column, mirroring
                    // Schema.getDerivedFromPgFieldName: entity-ref fields
                    // get the _id suffix, scalar (ID/String) fields don't.
                    let is_entity_ref = remote_entity
                        .object_relationships
                        .iter()
                        .any(|or| or.field_name == r.remote_field);
                    let suffix = if is_entity_ref { "_id" } else { "" };
                    let remote_db_column =
                        resolve_db_column(&r.remote_field, suffix, remote_rel.columns.iter())?;
                    Some(ArrayRelationship {
                        name: r.field_name.clone(),
                        remote_table: r.remote_entity.clone(),
                        remote_db_column,
                    })
                })
                .collect();

            tables.push(Table {
                name: entity.name.clone(),
                kind: rel.kind,
                description: entity.description.clone(),
                columns,
                primary_key: rel.primary_key.clone(),
                object_relationships,
                array_relationships,
                admin_only: false,
                public_aggregations: env.aggregate_entities.contains(&entity.name),
            });
        }

        // Effect-cache tables are tracked by the indexer without select
        // permissions: visible to admin only.
        for (name, rel) in &catalog.relations {
            if name.starts_with("envio_effect_") {
                tables.push(Table {
                    name: rel.name.clone(),
                    kind: rel.kind,
                    description: None,
                    columns: rel
                        .columns
                        .iter()
                        .map(|c| Column {
                            api_name: c.name.clone(),
                            db_name: c.name.clone(),
                            pg_type: c.pg_type.clone(),
                            pg_type_schema: c.pg_type_schema.clone(),
                            scalar: Scalar::from_pg_type(&c.pg_type, c.is_enum),
                            is_array: c.is_array,
                            nullable: c.nullable,
                            description: None,
                        })
                        .collect(),
                    primary_key: rel.primary_key.clone(),
                    object_relationships: vec![],
                    array_relationships: vec![],
                    admin_only: true,
                    public_aggregations: false,
                });
            }
        }

        if tables.is_empty() {
            return Err(anyhow!(
                "No tables to serve — has the database been migrated? (run the indexer or `envio local db-migrate setup`)"
            ));
        }

        if !skipped_entities.is_empty() {
            tracing::warn!(
                "Skipping entities from schema.graphql with no table in the database: {} — run migrations to expose them",
                skipped_entities.join(", ")
            );
        }

        tables.sort_by(|a, b| a.name.cmp(&b.name));

        {
            let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
            for t in &tables {
                if !seen.insert(&t.name) {
                    return Err(anyhow!(
                        "Table name collision: entity \"{}\" in schema.graphql conflicts with an internal indexer table of the same name. Rename the entity.",
                        t.name
                    ));
                }
            }
        }

        let model = ServerModel {
            tables,
            pg_schema: env.pg_schema.clone(),
            response_limit: env.response_limit,
        };

        // The admin registry contains every type any role can see; a clean
        // admin build guarantees both roles are collision-free.
        super::gql::schema_build::check_type_collisions(&model)?;

        Ok(model)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::env_config::{PgSslMode, ServeEnv};
    use crate::serve::pg_catalog::{self, Catalog, Relation, RelationKind};
    use crate::serve::project_schema::ProjectSchema;

    fn test_env() -> ServeEnv {
        ServeEnv {
            pg_host: "localhost".to_string(),
            pg_port: 5432,
            pg_user: "postgres".to_string(),
            pg_password: "testing".to_string(),
            pg_database: "envio-dev".to_string(),
            pg_schema: "public".to_string(),
            pg_ssl: PgSslMode::Disable,
            admin_secret: "testing".to_string(),
            cors: crate::serve::env_config::CorsConfig::AllowAll,
            use_prepared_statements: true,
            response_limit: None,
            aggregate_entities: vec![],
            query_timeout_ms: None,
            pool_wait_timeout_ms: None,
            connect_timeout_ms: None,
            pool_max_size: 2,
            startup_retry_budget_ms: 0,
            healthz_timeout_ms: 1_000,
            ws_ping_interval_ms: 15_000,
            ws_connection_init_timeout_ms: 3_000,
            ws_max_connections: 1_000,
            ws_max_operations_per_connection: 50,
            ws_max_operations: 1_000,
            ws_max_concurrent_polls: 1,
            ws_poll_interval_ms: 1_000,
            ws_max_message_bytes: 1024 * 1024,
        }
    }

    fn relation(name: &str, columns: &[&str]) -> Relation {
        Relation {
            name: name.to_string(),
            kind: RelationKind::Table,
            columns: columns
                .iter()
                .map(|c| pg_catalog::Column {
                    name: c.to_string(),
                    pg_type: "text".to_string(),
                    pg_type_schema: "pg_catalog".to_string(),
                    is_array: false,
                    nullable: false,
                    is_enum: false,
                })
                .collect(),
            primary_key: vec!["id".to_string()],
        }
    }

    fn catalog(relations: Vec<Relation>) -> Catalog {
        Catalog {
            relations: relations.into_iter().map(|r| (r.name.clone(), r)).collect(),
        }
    }

    const SCHEMA: &str = r#"
type User {
  id: ID!
  "user balance"
  tokenBalance: BigInt!
  bestGravatar: Gravatar
  tokens: [Token!]! @derivedFrom(field: "tokenOwner")
}
type Gravatar {
  id: ID!
}
type Token {
  id: ID!
  tokenOwner: User!
}
"#;

    fn build(schema: &str, catalog: Catalog) -> anyhow::Result<ServerModel> {
        ServerModel::build(ProjectSchema::parse(schema).unwrap(), catalog, &test_env())
    }

    fn build_err(schema: &str, catalog: Catalog) -> String {
        match build(schema, catalog) {
            Err(e) => e.to_string(),
            Ok(_) => panic!("expected build to fail"),
        }
    }

    fn user_shape(model: &ServerModel) -> Vec<(String, String, Option<String>)> {
        model
            .table("User")
            .unwrap()
            .columns
            .iter()
            .map(|c| (c.api_name.clone(), c.db_name.clone(), c.description.clone()))
            .collect()
    }

    #[test]
    fn snake_case_format_exposes_original_field_names() {
        let model = build(
            SCHEMA,
            catalog(vec![
                relation("User", &["id", "token_balance", "best_gravatar_id"]),
                relation("Gravatar", &["id"]),
                relation("Token", &["id", "token_owner_id"]),
            ]),
        )
        .unwrap();
        assert_eq!(
            (
                user_shape(&model),
                model
                    .table("User")
                    .unwrap()
                    .object_relationships
                    .iter()
                    .map(|r| (r.name.clone(), r.local_db_column.clone()))
                    .collect::<Vec<_>>(),
                model
                    .table("User")
                    .unwrap()
                    .array_relationships
                    .iter()
                    .map(|r| (r.name.clone(), r.remote_db_column.clone()))
                    .collect::<Vec<_>>(),
            ),
            (
                vec![
                    ("id".to_string(), "id".to_string(), None),
                    (
                        "tokenBalance".to_string(),
                        "token_balance".to_string(),
                        Some("user balance".to_string())
                    ),
                    (
                        "bestGravatar_id".to_string(),
                        "best_gravatar_id".to_string(),
                        None
                    ),
                ],
                vec![("bestGravatar".to_string(), "best_gravatar_id".to_string())],
                vec![("tokens".to_string(), "token_owner_id".to_string())],
            )
        );
    }

    #[test]
    fn original_format_keeps_db_names() {
        let model = build(
            SCHEMA,
            catalog(vec![
                relation("User", &["id", "tokenBalance", "bestGravatar_id"]),
                relation("Gravatar", &["id"]),
                relation("Token", &["id", "tokenOwner_id"]),
            ]),
        )
        .unwrap();
        assert_eq!(
            user_shape(&model),
            vec![
                ("id".to_string(), "id".to_string(), None),
                (
                    "tokenBalance".to_string(),
                    "tokenBalance".to_string(),
                    Some("user balance".to_string())
                ),
                (
                    "bestGravatar_id".to_string(),
                    "bestGravatar_id".to_string(),
                    None
                ),
            ]
        );
    }

    #[test]
    fn entity_named_like_internal_table_fails() {
        let err = build_err(
            "type raw_events { id: ID! }",
            catalog(vec![relation("raw_events", &["id"])]),
        );
        assert!(
            err.contains("Table name collision") && err.contains("raw_events"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn empty_database_explains_how_to_create_tables() {
        let err = build_err("type User { id: ID! }", catalog(vec![]));
        assert!(
            err.contains("No tables to serve"),
            "unexpected error: {err}"
        );
        assert!(
            err.contains("envio local db-migrate setup"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn entity_colliding_with_generated_type_fails() {
        let err = build_err(
            "type User { id: ID! }\ntype User_aggregate { id: ID! }",
            catalog(vec![
                relation("User", &["id"]),
                relation("User_aggregate", &["id"]),
            ]),
        );
        assert!(
            err.contains("type name collision") && err.contains("User_aggregate"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn entity_colliding_with_builtin_names_fails() {
        for name in ["Int", "order_by", "query_root"] {
            let err = build_err(
                &format!("type {name} {{ id: ID! }}"),
                catalog(vec![relation(name, &["id"])]),
            );
            assert!(
                err.contains("collision") && err.contains(name),
                "unexpected error for {name}: {err}"
            );
        }
    }

    #[test]
    fn collision_free_schema_builds() {
        let model = build(
            SCHEMA,
            catalog(vec![
                relation("User", &["id", "tokenBalance", "bestGravatar_id"]),
                relation("Gravatar", &["id"]),
                relation("Token", &["id", "tokenOwner_id"]),
                relation("raw_events", &["id"]),
            ]),
        )
        .unwrap();
        assert_eq!(
            model
                .tables
                .iter()
                .map(|t| t.name.as_str())
                .collect::<Vec<_>>(),
            vec!["Gravatar", "Token", "User", "raw_events"]
        );
    }
}
